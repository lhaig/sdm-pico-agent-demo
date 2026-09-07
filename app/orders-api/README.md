# `orders-api`

The service that breaks. FastAPI + psycopg2, reading `shopfront` on RDS,
deployed to `app-01` and `app-02` from user-data — venv, pinned requirements,
the systemd unit in this directory, uvicorn on `:8080`. There is no ALB; see
`terraform/templates/app-server.sh.tftpl`.

## Endpoints

| Method | Path | Behaviour |
|---|---|---|
| GET | `/health` | Liveness + DB reachability. **Stays 200 during the incident.** |
| GET | `/orders?limit&offset&status` | Newest-first list. 500s when a poisoned row is on the page. |
| GET | `/orders/{id}` | Single order. 500s if that order is poisoned. |
| GET | `/customers/{id}` | Customer record — `email`/`phone` are masked in flight for the agent by Cedar policy 20. The app is unmodified. |
| GET | `/metrics` | Prometheus exposition (`text/plain; version=0.0.4`). `http_requests_5xx_total`, `http_5xx_ratio`, `orders_malformed_payload_total`. |
| GET | `/debug/last-errors?limit` | Last 25 tracebacks, newest first. The agent's first triage stop. |

### Why `/health` must stay green

If health went red, the process would be taken out of service — by systemd here,
by a load balancer in a real deployment — traffic would stop, and the 5xx rate
would fall to zero. The Grafana alert rule would never fire and nothing would
page. So `/health` checks `SELECT 1` and nothing else. It never touches an order
payload.

This is also true of real systems and worth one sentence on stage: the service
is *up*, it is *healthy* by its own liveness definition, and it is failing every
business request. That gap is why on-call exists.

## Deploy

```bash
sudo useradd --system --home-dir /opt/orders-api --shell /usr/sbin/nologin orders || true
sudo install -d -o orders -g orders /opt/orders-api
sudo cp -r app/orders-api/* /opt/orders-api/
sudo python3 -m venv /opt/orders-api/venv
sudo /opt/orders-api/venv/bin/pip install -r /opt/orders-api/requirements.txt

sudo cp app/orders-api/orders-api.env.example /etc/orders-api.env
sudo chown root:orders /etc/orders-api.env && sudo chmod 0640 /etc/orders-api.env
sudo "${EDITOR:-vi}" /etc/orders-api.env        # real RDS endpoint + password

sudo cp app/orders-api/orders-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now orders-api
```

Verify:

```bash
curl -fsS localhost:8080/health | jq .
curl -fsS localhost:8080/metrics | grep 5xx
journalctl -u orders-api -n 50 --no-pager
```

## How the metrics get out

`orders-api` **does not push anything anywhere.** It exposes numbers on loopback
and something else collects them:

```
orders-api :8080/metrics
      │  scraped every 15s on 127.0.0.1
      ▼
prometheus --agent            (same host, own systemd unit, own `prometheus` user)
      │  remote_write, basic auth
      ▼
Grafana Cloud hosted metrics
      │
      ▼
alert rule  nightshift-orders-api-5xx   (terraform/96-grafana.tf)
```

This replaced a CloudWatch publisher that scraped the same counter and
republished it as a custom `Http5xxCount` metric for an alarm to watch. **The
counter did not change** — what disappeared is the alarm, the SNS topic, the
Lambda and PagerDuty (§4.1).

Two things worth knowing:

- **The app process holds no observability credential.** Pushing from inside
  `orders-api` would put a Grafana Cloud token in the process the demo exists to
  break, and a failing service should not also be the thing responsible for
  reporting that it is failing. The `remote_write` password lives in
  `/etc/prometheus-agent/remote-write-password`, mode `0600`, owned by
  `prometheus` — not readable by `ubuntu`, which is the identity the agent SSHes
  in as.
- **`prometheus.yml` is safe to read over `sdm ssh`.** It references the password
  by `password_file` rather than inlining it, so the config shows the endpoint
  and the account and no secret.

Debugging, in the order things actually go wrong:

```bash
systemctl status prometheus-agent
journalctl -u prometheus-agent -n 30 --no-pager   # remote_write 401s show here
curl -fsS localhost:8080/metrics | grep 5xx       # is there anything to send?
```

A `401` from `remote_write` is nearly always one of two things: the basic-auth
username must be the **numeric Prometheus instance ID** (not an email address),
or the Cloud Access Policy token is missing the **`metrics:write`** scope.

## Configuration

All environment, read from `/etc/orders-api.env`:

| Variable | Default | Notes |
|---|---|---|
| `SHOPFRONT_URL` | — | Full DSN. Wins over the `PG*` variables. |
| `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` / `PGPASSWORD` | libpq defaults | Used if `SHOPFRONT_URL` is unset. |
| `ORDERS_API_HOST` | `0.0.0.0` | |
| `ORDERS_API_PORT` | `8080` | `local.app_listen_port` in `terraform/20-compute.tf` is the source of truth; user-data writes it here and into the unit's `--port`, and the app security group opens the same number. |
| `ORDERS_API_POOL_MIN` / `_MAX` | `1` / `8` | psycopg2 `SimpleConnectionPool`. |

> **The credential on these hosts is deliberate.** `app-01`/`app-02` are the
> application's own servers and hold the application's own database password.
> The claim Project Nightshift makes is about the **agent VM** — that host has
> no `PGPASSWORD`, no SSH key, and no MCP token anywhere on disk. Do not let
> this file blur that distinction; if someone in the room asks, the answer is
> "yes, the app has a credential, it is the app's own; the agent does not, and
> the agent is the thing we do not trust."

## What the agent sees

The agent has no network or StrongDM grant to the application hosts. It reads
the Grafana incident and investigates the deterministic data condition through
`pg-prod-shopfront-read`. Application endpoints remain operator-only.

## Notes

- `enrich_order()` has no defensive error handling **on purpose**. See
  `../README.md` for the exact shapes `poison.sql` injects.
- `/metrics` is hand-rolled rather than `prometheus_client`, deliberately. Six
  counters, one process, one worker — the library's registry and multiprocess
  mode would buy nothing here and would add a second, subtler reason to care
  about worker count. Reach for it the moment this needs histograms or more than
  one worker.
- Metrics and the error ring buffer are in-process, which is why the unit runs
  **one uvicorn worker**, and under Prometheus that matters *more* than it did
  under the old CloudWatch publisher, not less.

  `http_requests_5xx_total` is a **counter**, and `rate()` assumes counters only
  increase — a decrease is read as a process restart, so the drop is discarded
  and the calculation restarts from the new value. Two workers answering
  alternate scrapes look exactly like a process restarting every 15 seconds, so
  the rate is computed from noise: sometimes zero while the service is failing,
  sometimes a spike while it is healthy. The Grafana rule then either never fires
  or fires and will not clear, and either way the Act 2 recovery beat is a claim
  you cannot make on stage. One worker keeps the counter monotonic. Raise it only
  after moving the counter somewhere shared.
- `/debug/last-errors` is unauthenticated. That is fine for a disposable demo
  environment inside a private subnet; it would not be fine anywhere else.
