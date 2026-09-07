#!/usr/bin/env python3
"""
orders-api — the production service that breaks.

Runs on app-01 and app-02, deployed from user-data into a venv and served by
uvicorn on :8080 (terraform/templates/app-server.sh.tftpl). Deliberately small:
its only job in this demo is to be a believable production service that starts
returning 500s the moment poisoned rows appear in `public.orders`, so a Grafana
alert rule fires and Nightshift gets paged.

HOW THE METRICS GET OUT — AND WHY THE APP DOES NOT DO IT ITSELF
---------------------------------------------------------------
There is no ALB and there is no push. `/metrics` below is a plain Prometheus
exposition endpoint on loopback, and a `prometheus --agent` process on the same
host scrapes it every 15s and remote_writes to Grafana Cloud
(terraform/templates/app-server.sh.tftpl). The alert rule in
terraform/96-grafana.tf evaluates PromQL over the result.

This replaced a CloudWatch publisher that scraped the same counter and
republished it as a custom `Http5xxCount` metric for an alarm to watch (§4.1).
The counter did not change. What disappeared is everything that used to stand
between it and the thing that alerts on it — and, more usefully for the demo,
the fault is now detected by the same product the agent reads its incident from
over MCP.

THIS PROCESS HOLDS NO OBSERVABILITY CREDENTIAL, DELIBERATELY. Pushing from here
would put a Grafana Cloud token inside the process the demo exists to break, and
a failing service should not also be the thing responsible for reporting that it
is failing. It exposes numbers; something else collects them.

Endpoints
---------
  GET /health          liveness + DB reachability. Stays 200 during the incident
                       ON PURPOSE — if the process were taken out of service the
                       5xx rate would fall to zero and the alert would never
                       see anything.
  GET /orders          list, newest first. 500s on malformed payloads.
  GET /orders/{id}     single order. 500s if that order is poisoned.
  GET /customers/{id}  used by the agent's "which customers are affected" step.
  GET /metrics         Prometheus exposition. `http_requests_5xx_total` is what
                       the Grafana alert rule's PromQL selects on;
                       `orders_malformed_payload_total` is the number that makes
                       the cause obvious. Both get quoted back in the agent's
                       Slack triage summary.
  GET /debug/last-errors  the last N tracebacks, in-memory. This is what the
                       agent reads over SSH-free HTTP when it triages, and it
                       is the honest reason a real engineer would have built it.

The failure is a genuine unhandled exception in `enrich_order`, not a fake
`raise HTTPException(500)`. That matters: the traceback the agent finds in the
journal is real, and it points at the real cause.

Config (environment)
--------------------
  PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD   standard libpq vars, or
  SHOPFRONT_URL                                a full DSN (wins if set)
  ORDERS_API_HOST      default 0.0.0.0
  ORDERS_API_PORT      default 8080
  ORDERS_API_POOL_MIN  default 1
  ORDERS_API_POOL_MAX  default 8
"""

from __future__ import annotations

import collections
import os
import threading
import time
import traceback
from typing import Any

import psycopg2
import psycopg2.extras
from psycopg2 import pool as pgpool

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DSN = os.environ.get("SHOPFRONT_URL", "")
HOST = os.environ.get("ORDERS_API_HOST", "0.0.0.0")
PORT = int(os.environ.get("ORDERS_API_PORT", "8080"))
POOL_MIN = int(os.environ.get("ORDERS_API_POOL_MIN", "1"))
POOL_MAX = int(os.environ.get("ORDERS_API_POOL_MAX", "8"))

APP_VERSION = "1.4.2"          # surfaced on /health and in the 500 body
START_TIME = time.time()

app = FastAPI(
    title="orders-api",
    version=APP_VERSION,
    description="Shopfront order service. Project Nightshift demo target.",
)

# -----------------------------------------------------------------------------
# Connection pool
# -----------------------------------------------------------------------------
_pool: pgpool.SimpleConnectionPool | None = None
_pool_lock = threading.Lock()


def get_pool() -> pgpool.SimpleConnectionPool:
    """Lazily build the pool so the process starts even if the DB is briefly down."""
    global _pool
    with _pool_lock:
        if _pool is None:
            _pool = pgpool.SimpleConnectionPool(POOL_MIN, POOL_MAX, DSN or "")
        return _pool


class conn_cursor:
    """Context manager: borrow a pooled connection, yield a dict cursor."""

    def __enter__(self):
        self.pool = get_pool()
        self.conn = self.pool.getconn()
        self.conn.autocommit = True
        self.cur = self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        return self.cur

    def __exit__(self, exc_type, exc, tb):
        try:
            self.cur.close()
        finally:
            self.pool.putconn(self.conn)
        return False


# -----------------------------------------------------------------------------
# Metrics + error ring buffer (in-memory; single process, good enough here)
# -----------------------------------------------------------------------------
METRICS: dict[str, int] = collections.defaultdict(int)
LAST_ERRORS: collections.deque = collections.deque(maxlen=25)
_metrics_lock = threading.Lock()


def bump(name: str, n: int = 1) -> None:
    with _metrics_lock:
        METRICS[name] += n


def record_error(path: str, exc: BaseException) -> None:
    """Keep the traceback so /debug/last-errors can hand it to the on-call agent."""
    with _metrics_lock:
        LAST_ERRORS.appendleft(
            {
                "ts": time.time(),
                "path": path,
                "type": type(exc).__name__,
                "message": str(exc),
                "traceback": traceback.format_exc().splitlines()[-8:],
            }
        )


@app.middleware("http")
async def count_requests(request: Request, call_next):
    """
    Count every request by status class.

    These counters are the entire signal path: /metrics exposes them, the local
    Prometheus agent scrapes and remote_writes them, and the Grafana rule
    evaluates `rate(http_requests_5xx_total[2m])` over the result.

    They live in plain process memory, which is why the systemd unit runs
    `--workers 1` and why raising that breaks the demo — see the long note in
    orders-api.service.
    """
    bump("http_requests_total")
    try:
        response = await call_next(request)
    except Exception:
        # Should not happen — the route handlers convert to JSONResponse — but
        # if it does, it is still a 5xx and must be counted.
        bump("http_requests_5xx_total")
        raise
    if response.status_code >= 500:
        bump("http_requests_5xx_total")
    elif response.status_code >= 400:
        bump("http_requests_4xx_total")
    else:
        bump("http_requests_2xx_total")
    return response


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    """
    Turn any unhandled exception into a 500 with a stable body.

    Real, ugly and honest — the message names the exception type so that a
    competent on-call (human or agent) has a thread to pull immediately.
    """
    record_error(request.url.path, exc)
    bump("orders_malformed_payload_total")
    return JSONResponse(
        status_code=500,
        content={
            "error": "internal_server_error",
            "detail": f"{type(exc).__name__}: {exc}",
            "hint": "order payload failed enrichment",
            "service": "orders-api",
            "version": APP_VERSION,
        },
    )


# -----------------------------------------------------------------------------
# The business logic that breaks
# -----------------------------------------------------------------------------
def enrich_order(row: dict[str, Any]) -> dict[str, Any]:
    """
    Expand an order row into the API response shape.

    The contract with the database is that `payload["items"]` is a list of
    dicts, each with `sku`, `qty` and `unit_price_cents`.

    poison.sql violates that contract two different ways:
      * items is a string  -> iterating yields characters, item["qty"] TypeErrors
      * items lacks unit_price_cents -> KeyError

    There is deliberately NO defensive try/except here. That is the bug. A real
    service written under deadline looks exactly like this, and the resulting
    500 is what makes the incident real rather than staged.
    """
    payload = row.get("payload") or {}
    items = payload["items"]

    lines = []
    computed_total = 0
    for item in items:
        qty = item["qty"]
        unit = item["unit_price_cents"]
        line_total = qty * unit
        computed_total += line_total
        lines.append(
            {
                "sku": item["sku"],
                "qty": qty,
                "unit_price_cents": unit,
                "line_total_cents": line_total,
            }
        )

    return {
        "id": row["id"],
        "customer_id": row["customer_id"],
        "sku": row["sku"],
        "qty": row["qty"],
        "status": row["status"],
        "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
        "amount_cents": row["amount_cents"],
        "computed_total_cents": computed_total,
        "totals_match": computed_total == row["amount_cents"],
        "channel": payload.get("channel"),
        "shipping": payload.get("shipping"),
        "lines": lines,
    }


# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------
@app.get("/health")
def health():
    """
    Liveness. Checks the DB is reachable but does NOT touch order payloads,
    so it keeps returning 200 throughout the incident. That is deliberate: if
    health went red, systemd (or, in a real deployment, a load balancer) would
    take the process out of service, the 5xx rate would fall to zero, and the
    Grafana alert rule would never fire.

    It is also a nice detail for the agent to notice and say out loud — "health
    is green and every business request is failing" is exactly the shape of a
    real incident, and not itself a finding.
    """
    try:
        with conn_cursor() as cur:
            cur.execute("SELECT 1 AS ok")
            cur.fetchone()
        db_ok = True
    except Exception as exc:  # noqa: BLE001 - health must never raise
        record_error("/health", exc)
        db_ok = False

    body = {
        "status": "ok" if db_ok else "degraded",
        "service": "orders-api",
        "version": APP_VERSION,
        "uptime_seconds": round(time.time() - START_TIME, 1),
        "database": "reachable" if db_ok else "unreachable",
    }
    return JSONResponse(status_code=200 if db_ok else 503, content=body)


@app.get("/orders")
def list_orders(
    limit: int = Query(25, ge=1, le=200),
    offset: int = Query(0, ge=0),
    status: str | None = Query(None, description="Filter by order status"),
):
    """
    List orders, newest first.

    Newest-first + poisoned rows carrying a fresh created_at means the very
    first page of the very first request after fault injection raises. The 5xx
    rate is immediate, not eventual.
    """
    sql = [
        "SELECT id, customer_id, sku, qty, amount_cents, status, created_at, payload",
        "FROM public.orders",
    ]
    params: list[Any] = []
    if status:
        sql.append("WHERE status = %s")
        params.append(status)
    sql.append("ORDER BY created_at DESC, id DESC LIMIT %s OFFSET %s")
    params.extend([limit, offset])

    with conn_cursor() as cur:
        cur.execute(" ".join(sql), params)
        rows = cur.fetchall()

    # No try/except: a poisoned row anywhere on this page 500s the request.
    return {
        "count": len(rows),
        "limit": limit,
        "offset": offset,
        "orders": [enrich_order(dict(r)) for r in rows],
    }


@app.get("/orders/{order_id}")
def get_order(order_id: int):
    with conn_cursor() as cur:
        cur.execute(
            "SELECT id, customer_id, sku, qty, amount_cents, status, created_at, payload "
            "FROM public.orders WHERE id = %s",
            (order_id,),
        )
        row = cur.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail=f"order {order_id} not found")

    return enrich_order(dict(row))


@app.get("/customers/{customer_id}")
def get_customer(customer_id: int):
    """
    Customer lookup.

    Note for the demo narration: when the AGENT reads customers through
    StrongDM, `email` and `phone` come back masked by policy 20 even though
    this code selects them plainly. The application is unchanged; the masking
    happens in flight. Nothing here had to be modified to protect the PII.
    """
    with conn_cursor() as cur:
        cur.execute(
            "SELECT id, name, email, phone, tier, created_at "
            "FROM public.customers WHERE id = %s",
            (customer_id,),
        )
        row = cur.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail=f"customer {customer_id} not found")

    row = dict(row)
    row["created_at"] = row["created_at"].isoformat()
    return row


# Prometheus text exposition format 0.0.4. Declaring the version explicitly is
# what makes this a *proper* exposition endpoint rather than "some text that
# happens to parse" — a scraper is entitled to reject an unversioned body, and
# the failure would show up as an empty series in Grafana rather than as an
# error anywhere you would think to look.
PROMETHEUS_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"


@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    """
    Prometheus exposition.

    THIS ENDPOINT IS THE HEAD OF THE INCIDENT CHAIN (§6).
    `prometheus --agent` on this host scrapes it every 15s and remote_writes to
    Grafana Cloud; the alert rule in terraform/96-grafana.tf evaluates

        sum(rate(http_requests_5xx_total{job="orders-api"}[2m]))

    over the result. The `job` label is set by the scrape config, not here.

    Hand-rolled rather than `prometheus_client`, and that is a deliberate
    choice worth defending if anyone asks. The library's value is its
    registry, its multiprocess mode and its metric types — and this service has
    six counters, one process, and a systemd unit that pins it to one uvicorn
    worker precisely so the counters stay coherent. Adding the dependency would
    buy nothing here and would put a second, subtler reason to care about
    worker count into a build whose failure mode is already documented at
    length in orders-api.service. Reach for it the moment this needs
    histograms or more than one worker.

    It is also what a human (or the agent) curls first to confirm the blast
    radius, and `orders_malformed_payload_total` is the number that makes the
    cause obvious.
    """
    with _metrics_lock:
        snapshot = dict(METRICS)

    total = snapshot.get("http_requests_total", 0)
    errors = snapshot.get("http_requests_5xx_total", 0)
    rate = (errors / total) if total else 0.0

    lines = [
        "# HELP orders_api_up 1 if the process is serving.",
        "# TYPE orders_api_up gauge",
        "orders_api_up 1",
        "# HELP orders_api_uptime_seconds Seconds since process start.",
        "# TYPE orders_api_uptime_seconds gauge",
        f"orders_api_uptime_seconds {time.time() - START_TIME:.1f}",
        "# HELP http_requests_total Total HTTP requests handled.",
        "# TYPE http_requests_total counter",
        f"http_requests_total {total}",
        "# HELP http_requests_5xx_total Total responses with status >= 500.",
        "# TYPE http_requests_5xx_total counter",
        f"http_requests_5xx_total {errors}",
        "# HELP http_requests_4xx_total Total responses with status 400-499.",
        "# TYPE http_requests_4xx_total counter",
        f"http_requests_4xx_total {snapshot.get('http_requests_4xx_total', 0)}",
        "# HELP http_5xx_ratio Fraction of requests failing with 5xx.",
        "# TYPE http_5xx_ratio gauge",
        f"http_5xx_ratio {rate:.4f}",
        "# HELP orders_malformed_payload_total Order payloads that failed enrichment.",
        "# TYPE orders_malformed_payload_total counter",
        f"orders_malformed_payload_total {snapshot.get('orders_malformed_payload_total', 0)}",
    ]
    return PlainTextResponse(
        content="\n".join(lines) + "\n",
        media_type=PROMETHEUS_CONTENT_TYPE,
    )


@app.get("/debug/last-errors")
def last_errors(limit: int = Query(10, ge=1, le=25)):
    """
    Recent tracebacks, most recent first.

    The agent's triage playbook (agent/workspace/AGENT.md, step 2) fetches this
    to identify the failing code path before it ever opens a database session.
    Cheap, honest, and it keeps the demo moving.
    """
    with _metrics_lock:
        return {"count": min(limit, len(LAST_ERRORS)), "errors": list(LAST_ERRORS)[:limit]}


# -----------------------------------------------------------------------------
# Dev entrypoint. In the demo the service runs under the systemd unit, which
# invokes uvicorn directly (see orders-api.service).
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
