-- =============================================================================
-- Project Nightshift — "shopfront" production schema
-- =============================================================================
-- Target: RDS Postgres 16, database `shopfront`.
--
-- Column names in here are LOAD BEARING for the Cedar policies:
--
--   * public.customers.email  and  public.customers.phone
--       -> targeted by policies/20-redact-pii.cedar  (@redact("email"), @redact("phone"))
--          The query must SUCCEED and return rows; StrongDM masks these two
--          columns in flight so the LLM never receives the PII.
--
--   * public.orders
--       -> the ONLY table the agent may ever write to, and only after a human
--          approves the request. See policies/30-approve-remediation-write.cedar
--          (`context.sql.qualifiedWriteTables == ["public.orders"]` — set
--          equality, so a statement writing orders AND another table fails it).
--
--   * public.payments
--       -> deliberately NOT in scope of any permit. Even a fully approved,
--          time-bound write grant cannot touch it. This is the "the blast
--          radius is bounded even after approval" beat.
--
-- Run as the database owner:
--     psql "$SHOPFRONT_URL" -v ON_ERROR_STOP=1 -f app/schema.sql
--
-- Idempotent: safe to re-run. It will NOT drop data unless you pass
--     -v drop_first=1
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- -----------------------------------------------------------------------------
-- Schemas
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS public;

-- `pristine` holds a byte-for-byte snapshot of the seeded data taken by
-- seed.py *before* any fault injection. scripts/reset.sh restores from here,
-- which is what makes rehearsal resets fast and total: it survives even the
-- Run-1 "agent deletes 40,000 rows" catastrophe.
CREATE SCHEMA IF NOT EXISTS pristine;

-- -----------------------------------------------------------------------------
-- public.customers
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customers (
    id          bigint       PRIMARY KEY,
    name        text         NOT NULL,
    -- redacted in flight by Cedar policy 20 for principals in role ai-agents
    email       text         NOT NULL,
    -- redacted in flight by Cedar policy 20 for principals in role ai-agents
    phone       text         NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    tier        text         NOT NULL DEFAULT 'standard'
                             CHECK (tier IN ('standard', 'silver', 'gold', 'platinum'))
);

COMMENT ON TABLE  public.customers       IS 'Customer master. Contains PII (email, phone) redacted in flight for AI agents.';
COMMENT ON COLUMN public.customers.email IS 'PII — masked by StrongDM policy 20-redact-pii.cedar';
COMMENT ON COLUMN public.customers.phone IS 'PII — masked by StrongDM policy 20-redact-pii.cedar';

-- -----------------------------------------------------------------------------
-- public.orders
-- -----------------------------------------------------------------------------
-- `payload` is the jsonb blob the orders-api dereferences on every read.
-- Malformed payloads are what turn this table into a production incident.
CREATE TABLE IF NOT EXISTS public.orders (
    id            bigint       PRIMARY KEY,
    customer_id   bigint       NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
    sku           text         NOT NULL,
    qty           integer      NOT NULL CHECK (qty > 0),
    amount_cents  bigint       NOT NULL CHECK (amount_cents >= 0),
    -- NOTE: intentionally NOT a CHECK-constrained enum. poison.sql inserts the
    -- out-of-band value 'PENDING_RECONCILE', which is exactly the kind of state
    -- that leaks in from a half-finished migration in the real world.
    status        text         NOT NULL DEFAULT 'PENDING',
    created_at    timestamptz  NOT NULL DEFAULT now(),
    payload       jsonb        NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE  public.orders         IS 'Order fact table. The only table an approved agent write may target (policy 30).';
COMMENT ON COLUMN public.orders.payload IS 'Line items + shipping. orders-api dereferences payload->items on every read; malformed shapes cause 500s.';

-- -----------------------------------------------------------------------------
-- public.payments
-- -----------------------------------------------------------------------------
-- Out of scope for every permit statement. Deliberately.
CREATE TABLE IF NOT EXISTS public.payments (
    id             bigint  PRIMARY KEY,
    order_id       bigint  NOT NULL REFERENCES public.orders (id) ON DELETE CASCADE,
    last4          char(4) NOT NULL,
    processor_ref  text    NOT NULL,
    amount_cents   bigint  NOT NULL CHECK (amount_cents >= 0)
);

COMMENT ON TABLE public.payments IS 'Cardholder tail + processor reference. No agent policy permits any action here.';

-- -----------------------------------------------------------------------------
-- public.poison_backup
-- -----------------------------------------------------------------------------
-- Demo scaffolding, not application data: app/poison.sql copies the pre-poison
-- state of every row it touches in here, so a light-touch undo is possible
-- without a full pristine restore.
--
-- It is created HERE rather than in poison.sql because app/restore.sql
-- unconditionally truncates it, and restore.sql runs under ON_ERROR_STOP. With
-- the table created only by poison.sql, the first reset.sh after a clean seed
-- aborted on "relation public.poison_backup does not exist" and restored
-- nothing — on an environment that looked fine right up until you needed it.
--
-- Creating it with the schema makes it exist from the moment the database does,
-- which is the property restore.sql actually depends on.
CREATE TABLE IF NOT EXISTS public.poison_backup (
    id           bigint      PRIMARY KEY,
    status       text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL,
    backed_up_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.poison_backup IS 'Pre-poison state of rows mutated by app/poison.sql. Demo scaffolding, not application data.';

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
-- The API list endpoint sorts by created_at DESC, so freshly poisoned rows land
-- on page one and the 5xx rate spikes immediately. That index matters for the
-- demo timing, not just for query speed.
CREATE INDEX IF NOT EXISTS orders_created_at_desc_idx  ON public.orders (created_at DESC);
CREATE INDEX IF NOT EXISTS orders_status_idx           ON public.orders (status);
CREATE INDEX IF NOT EXISTS orders_customer_id_idx      ON public.orders (customer_id);
CREATE INDEX IF NOT EXISTS orders_status_created_idx   ON public.orders (status, created_at DESC);
-- Lets the agent find the malformed rows with a containment query rather than a
-- full scan — a nice detail if an architect asks how it triaged so fast.
CREATE INDEX IF NOT EXISTS orders_payload_gin_idx      ON public.orders USING gin (payload jsonb_path_ops);

CREATE INDEX IF NOT EXISTS customers_tier_idx          ON public.customers (tier);
CREATE INDEX IF NOT EXISTS customers_created_at_idx    ON public.customers (created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS customers_email_uidx ON public.customers (lower(email));

CREATE INDEX IF NOT EXISTS payments_order_id_idx       ON public.payments (order_id);
CREATE UNIQUE INDEX IF NOT EXISTS payments_ref_uidx    ON public.payments (processor_ref);

-- -----------------------------------------------------------------------------
-- Convenience view used by the agent's triage playbook (AGENT.md step 3).
-- Read-only, no PII, safe for the model to receive in full.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.order_health AS
SELECT
    status,
    count(*)                                                   AS row_count,
    min(created_at)                                            AS oldest,
    max(created_at)                                            AS newest,
    count(*) FILTER (WHERE jsonb_typeof(payload -> 'items') <> 'array') AS malformed_payloads
FROM public.orders
GROUP BY status
ORDER BY row_count DESC;

COMMENT ON VIEW public.order_health IS 'Per-status row counts and malformed-payload counts. First stop in incident triage.';

COMMIT;
