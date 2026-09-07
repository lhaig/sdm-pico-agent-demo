#!/usr/bin/env python3
"""
Project Nightshift — deterministic data generator for the `shopfront` database.

Generates ~5,000 customers, ~50,000 orders and the payments that go with them,
then snapshots the whole lot into the `pristine` schema so scripts/reset.sh can
restore in about a second between rehearsals.

Design notes
------------
* **No third-party data libraries.** Everything is generated from wordlists in
  this file, so `pip install faker` is not a prerequisite on the demo box.
  The only runtime dependency is psycopg2 (already needed by orders-api).
* **Deterministic.** `random.Random(SEED)` with a fixed seed and a fixed
  "now" anchor. Run it on two machines, get byte-identical rows. That matters:
  the demo script quotes specific numbers on stage.
* **Fast.** Rows are streamed through `COPY ... FROM STDIN` in chunks, not
  INSERTed one at a time. 50k orders load in a couple of seconds even across
  the StrongDM proxy.

WHICH CONNECTION
----------------
Seeding CREATEs schemas, DROPs tables and COPYs — all writes. Cedar policy 10
forbids every write from a service account on a prod-tagged resource, so this
must NOT run down the agent's connection (`SHOPFRONT_URL`); it would be refused,
and refusing it is the control working.

Run it as YOURSELF: a second `sdm connect` under your own human account, which
is in the `sre-oncall` role and exempt. That is `SHOPFRONT_ADMIN_URL` in
scripts/.env — still StrongDM-brokered, still fully recorded, just a different
principal. See scripts/.env.example.

Usage
-----
    # through the StrongDM proxy, as the operator (the normal path)
    sdm connect pg-prod-shopfront-read 5433       # as YOU, not as the agent
    export SHOPFRONT_ADMIN_URL="postgresql://127.0.0.1:5433/shopfront"
    ./seed.py

    # or name the DSN explicitly
    ./seed.py --dsn "postgresql://127.0.0.1:5433/shopfront"

    # or with libpq environment variables (PGHOST/PGUSER/PGPASSWORD/...)
    ./seed.py

    # smaller dataset for a laptop smoke test
    ./seed.py --customers 200 --orders 2000

    # re-take the pristine snapshot without regenerating data
    ./seed.py --snapshot-only
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import random
import sys
from datetime import datetime, timedelta, timezone

try:
    import psycopg2
except ImportError:  # pragma: no cover - operator ergonomics
    sys.exit("psycopg2 is required:  pip install -r app/orders-api/requirements.txt")


# -----------------------------------------------------------------------------
# Determinism knobs. Change these and every downstream number in the demo
# script changes with them, so don't, unless you also re-run the script.
# -----------------------------------------------------------------------------
SEED = 1337
# Fixed "now" anchor so created_at values never drift between runs.
# Orders are spread over the 180 days ending at this instant.
NOW = datetime(2026, 8, 28, 9, 0, 0, tzinfo=timezone.utc)
WINDOW_DAYS = 180

DEFAULT_CUSTOMERS = 5_000
DEFAULT_ORDERS = 50_000
COPY_CHUNK = 10_000


# -----------------------------------------------------------------------------
# Wordlists — a small hand-rolled stand-in for faker.
# -----------------------------------------------------------------------------
FIRST_NAMES = [
    "Aoife", "Amara", "Ana", "Anders", "Arjun", "Beatriz", "Bilal", "Callum",
    "Camille", "Chidi", "Clara", "Dara", "Diego", "Elif", "Elena", "Emeka",
    "Fatima", "Felix", "Freya", "Gabriel", "Greta", "Hana", "Hugo", "Ines",
    "Isabel", "Ivan", "Jonas", "Julia", "Kai", "Karim", "Katya", "Kwame",
    "Lars", "Leila", "Liam", "Lucia", "Magnus", "Maja", "Marcus", "Mei",
    "Niamh", "Nikolai", "Nora", "Omar", "Priya", "Rafael", "Rania", "Rohan",
    "Rosa", "Sanne", "Sofia", "Tariq", "Thabo", "Tomas", "Yara", "Yuki",
]

LAST_NAMES = [
    "Abiodun", "Ahmed", "Almeida", "Andersen", "Bakker", "Bianchi", "Cheng",
    "Costa", "Dlamini", "Duarte", "Eriksen", "Ferreira", "Fischer", "Gallagher",
    "Garcia", "Haas", "Hoffmann", "Ibrahim", "Jansen", "Kaur", "Keller",
    "Kovacs", "Lindqvist", "Lopez", "Maguire", "Marino", "Mbeki", "Moreau",
    "Nakamura", "Nowak", "Okafor", "Olsen", "Petrov", "Popescu", "Rahman",
    "Reyes", "Rossi", "Santos", "Schmidt", "Silva", "Sorensen", "Tanaka",
    "Toure", "Vasquez", "Virtanen", "Walsh", "Weber", "Yilmaz", "Zhang",
]

EMAIL_DOMAINS = [
    "example.com", "mailinator-demo.net", "shopfront-test.io", "acme-demo.co",
    "northwind-demo.org", "contoso-demo.dev",
]

PRODUCT_LINES = [
    ("WID", "Widget", 1_299, 4_999),
    ("GDT", "Gadget", 2_499, 12_999),
    ("DVC", "Device", 8_999, 49_999),
    ("ACC", "Accessory", 499, 2_999),
    ("SVC", "Service Plan", 999, 19_999),
    ("BND", "Bundle", 5_999, 29_999),
]

# (status, weight). Deliberately no 'PENDING_RECONCILE' here — that value only
# ever arrives via poison.sql, which is what makes it a clean incident signal.
ORDER_STATUSES = [
    ("DELIVERED", 55),
    ("SHIPPED", 20),
    ("PENDING", 12),
    ("CANCELLED", 8),
    ("REFUNDED", 5),
]

TIERS = [("standard", 62), ("silver", 22), ("gold", 12), ("platinum", 4)]

CHANNELS = [("web", 60), ("ios", 18), ("android", 14), ("partner-api", 8)]
SHIP_METHODS = ["standard", "express", "same-day", "locker"]
COUNTRIES = ["GB", "IE", "DE", "NL", "FR", "ES", "PT", "SE", "US", "CA", "ZA"]
PROCESSORS = ["stripe", "adyen", "braintree"]


def weighted(rng: random.Random, pairs: list[tuple[str, int]]) -> str:
    """Pick one value from a list of (value, weight) tuples."""
    total = sum(w for _, w in pairs)
    roll = rng.randint(1, total)
    upto = 0
    for value, weight in pairs:
        upto += weight
        if roll <= upto:
            return value
    return pairs[-1][0]


# -----------------------------------------------------------------------------
# Row generators
# -----------------------------------------------------------------------------
def gen_customers(rng: random.Random, count: int):
    """Yield customer tuples. Emails are unique by construction (id suffix)."""
    for cid in range(1, count + 1):
        first = rng.choice(FIRST_NAMES)
        last = rng.choice(LAST_NAMES)
        name = f"{first} {last}"
        # id suffix guarantees uniqueness against customers_email_uidx
        email = f"{first.lower()}.{last.lower()}{cid}@{rng.choice(EMAIL_DOMAINS)}"
        # Reserved test range: +1-555-01xx numbers are never routable.
        phone = f"+1-555-{rng.randint(100, 199):03d}-{rng.randint(0, 9999):04d}"
        # Customers exist before their orders; spread them over 2x the window.
        created = NOW - timedelta(
            days=rng.randint(WINDOW_DAYS, WINDOW_DAYS * 2),
            seconds=rng.randint(0, 86_399),
        )
        yield (cid, name, email, phone, created.isoformat(), weighted(rng, TIERS))


def gen_orders(rng: random.Random, count: int, customer_count: int):
    """Yield (order_tuple, payment_tuple_or_None)."""
    payment_id = 0
    for oid in range(1, count + 1):
        # Power-ish skew: a minority of customers place most of the orders,
        # which makes "top customers by revenue" a believable analyst question.
        if rng.random() < 0.35:
            customer_id = rng.randint(1, max(1, customer_count // 10))
        else:
            customer_id = rng.randint(1, customer_count)

        prefix, _label, lo, hi = rng.choice(PRODUCT_LINES)
        sku = f"{prefix}-{rng.randint(1000, 9999)}"
        qty = rng.choices([1, 2, 3, 4, 5], weights=[62, 20, 10, 5, 3])[0]
        unit_price = rng.randint(lo, hi)
        amount_cents = unit_price * qty
        status = weighted(rng, ORDER_STATUSES)
        created = NOW - timedelta(
            days=rng.randint(0, WINDOW_DAYS - 1),
            seconds=rng.randint(0, 86_399),
        )

        # The well-formed payload shape. orders-api contracts on this:
        #   payload["items"] is a LIST of dicts each having sku/qty/unit_price_cents.
        # poison.sql breaks exactly that contract.
        payload = {
            "schema": 2,
            "channel": weighted(rng, CHANNELS),
            "items": [
                {"sku": sku, "qty": qty, "unit_price_cents": unit_price}
            ],
            "shipping": {
                "method": rng.choice(SHIP_METHODS),
                "country": rng.choice(COUNTRIES),
            },
            "promo": None,
        }
        # ~8% of orders are multi-line, so the API's aggregation does real work.
        if rng.random() < 0.08:
            extra_prefix, _l, elo, ehi = rng.choice(PRODUCT_LINES)
            extra_price = rng.randint(elo, ehi)
            extra_qty = rng.choice([1, 1, 2])
            payload["items"].append({
                "sku": f"{extra_prefix}-{rng.randint(1000, 9999)}",
                "qty": extra_qty,
                "unit_price_cents": extra_price,
            })
            amount_cents += extra_price * extra_qty

        order = (
            oid, customer_id, sku, qty, amount_cents, status,
            created.isoformat(), json.dumps(payload, separators=(",", ":")),
        )

        payment = None
        if status in ("DELIVERED", "SHIPPED", "REFUNDED"):
            payment_id += 1
            payment = (
                payment_id,
                oid,
                f"{rng.randint(0, 9999):04d}",
                f"{rng.choice(PROCESSORS)}_{oid:08d}{rng.randint(100, 999)}",
                amount_cents,
            )

        yield order, payment


# -----------------------------------------------------------------------------
# COPY plumbing
# -----------------------------------------------------------------------------
def copy_rows(cur, table: str, columns: list[str], rows) -> int:
    """Stream `rows` into `table` via COPY, in COPY_CHUNK-sized batches."""
    collist = ", ".join(columns)
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_MINIMAL)
    n = 0
    pending = 0

    def flush():
        nonlocal buf, writer, pending
        if not pending:
            return
        buf.seek(0)
        cur.copy_expert(
            f"COPY {table} ({collist}) FROM STDIN WITH (FORMAT csv)", buf
        )
        buf = io.StringIO()
        writer = csv.writer(buf, quoting=csv.QUOTE_MINIMAL)
        pending = 0

    for row in rows:
        writer.writerow(row)
        n += 1
        pending += 1
        if pending >= COPY_CHUNK:
            flush()
    flush()
    return n


def snapshot(cur) -> None:
    """
    Take (or retake) the pristine snapshot.

    This makes reset idempotent and total after any interrupted rehearsal. The
    database returns exactly to the seeded state, including explicit IDs, so
    foreign keys line up again.
    """
    cur.execute("CREATE SCHEMA IF NOT EXISTS pristine")
    for table in ("customers", "orders", "payments"):
        cur.execute(f"DROP TABLE IF EXISTS pristine.{table}")
        cur.execute(
            f"CREATE TABLE pristine.{table} AS TABLE public.{table}"
        )
        cur.execute(f"ANALYZE pristine.{table}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed the shopfront demo database.")
    ap.add_argument(
        "--dsn",
        default=os.environ.get("SHOPFRONT_ADMIN_URL", ""),
        help=(
            "Postgres DSN. Defaults to $SHOPFRONT_ADMIN_URL (the operator's "
            "human connection), then libpq PG* environment variables."
        ),
    )
    ap.add_argument("--customers", type=int, default=DEFAULT_CUSTOMERS)
    ap.add_argument("--orders", type=int, default=DEFAULT_ORDERS)
    ap.add_argument(
        "--truncate",
        action="store_true",
        default=True,
        help="Truncate the public tables before loading (default).",
    )
    ap.add_argument(
        "--no-truncate", dest="truncate", action="store_false",
        help="Append instead of replacing. Will collide on primary keys.",
    )
    ap.add_argument(
        "--no-snapshot", dest="snapshot", action="store_false", default=True,
        help="Skip the pristine snapshot (reset.sh will not work without it).",
    )
    ap.add_argument(
        "--snapshot-only", action="store_true",
        help="Retake the pristine snapshot from current public data and exit.",
    )
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn) if args.dsn else psycopg2.connect("")
    conn.autocommit = False
    cur = conn.cursor()

    if args.snapshot_only:
        print("Retaking pristine snapshot from current public data ...")
        snapshot(cur)
        conn.commit()
        print("  done.")
        return 0

    rng = random.Random(SEED)

    if args.truncate:
        print("Truncating public.orders / public.payments / public.customers ...")
        cur.execute(
            "TRUNCATE public.payments, public.orders, public.customers "
            "RESTART IDENTITY CASCADE"
        )

    print(f"Generating {args.customers:,} customers ...")
    n_cust = copy_rows(
        cur, "public.customers",
        ["id", "name", "email", "phone", "created_at", "tier"],
        gen_customers(rng, args.customers),
    )
    print(f"  loaded {n_cust:,}")

    print(f"Generating {args.orders:,} orders (+ payments) ...")
    orders_buf: list[tuple] = []
    payments_buf: list[tuple] = []
    for order, payment in gen_orders(rng, args.orders, args.customers):
        orders_buf.append(order)
        if payment:
            payments_buf.append(payment)

    n_ord = copy_rows(
        cur, "public.orders",
        ["id", "customer_id", "sku", "qty", "amount_cents", "status",
         "created_at", "payload"],
        orders_buf,
    )
    print(f"  loaded {n_ord:,} orders")

    n_pay = copy_rows(
        cur, "public.payments",
        ["id", "order_id", "last4", "processor_ref", "amount_cents"],
        payments_buf,
    )
    print(f"  loaded {n_pay:,} payments")

    print("ANALYZE ...")
    for table in ("customers", "orders", "payments"):
        cur.execute(f"ANALYZE public.{table}")

    if args.snapshot:
        print("Taking pristine snapshot (used by scripts/reset.sh) ...")
        snapshot(cur)

    conn.commit()

    # Summary the operator can eyeball against the demo script.
    cur.execute("SELECT status, count(*) FROM public.orders GROUP BY 1 ORDER BY 2 DESC")
    print("\nOrder status distribution:")
    for status, count in cur.fetchall():
        print(f"  {status:<18} {count:>8,}")

    cur.execute("SELECT count(*) FROM public.orders WHERE status = 'PENDING_RECONCILE'")
    poisoned = cur.fetchone()[0]
    print(f"\nPoisoned rows present: {poisoned}  (expected 0 on a fresh seed)")
    print("Seed complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
