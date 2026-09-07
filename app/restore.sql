-- =============================================================================
-- Project Nightshift — full restore from the pristine snapshot.
-- =============================================================================
-- Called by scripts/reset.sh between rehearsals. It TRUNCATEs and INSERTs, so
-- it runs as YOU (SHOPFRONT_ADMIN_URL — your own account, in sre-oncall). The
-- agent's connection is read-only by Cedar policy 10 and would refuse it, which
-- is the control working rather than something to route around:
--
--     psql "$SHOPFRONT_ADMIN_URL" -v ON_ERROR_STOP=1 -f app/restore.sql
--
-- A full restore is deterministic after a completed or interrupted rehearsal
-- and takes about a second for this dataset.
--
-- The snapshot is created by app/seed.py. If `pristine` is missing, re-run:
--     ./app/seed.py --snapshot-only     (snapshot current data), or
--     ./app/seed.py                     (regenerate everything)
--
-- Idempotent: run it as many times as you like.
-- =============================================================================

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'pristine' AND table_name = 'orders'
    ) THEN
        RAISE EXCEPTION
            'pristine snapshot missing — run: ./app/seed.py  (or --snapshot-only)';
    END IF;
END
$$;

BEGIN;

-- Order matters: payments -> orders -> customers on the way down (FKs),
-- customers -> orders -> payments on the way back up.
TRUNCATE public.payments, public.orders, private.customer_pii RESTART IDENTITY CASCADE;

INSERT INTO private.customer_pii SELECT * FROM pristine.customers;
INSERT INTO public.orders        SELECT * FROM pristine.orders;
INSERT INTO public.payments      SELECT * FROM pristine.payments;

-- Poison bookkeeping is demo scaffolding; clear it so the next run starts clean.
-- The table is created by app/schema.sql, so it exists whether or not
-- app/poison.sql has ever run. It used to be created only by poison.sql, and
-- this line aborted the whole restore under ON_ERROR_STOP on the first reset
-- after a clean seed.
TRUNCATE TABLE public.poison_backup;

COMMIT;

ANALYZE private.customer_pii;
ANALYZE public.orders;
ANALYZE public.payments;

SELECT
    (SELECT count(*) FROM public.customers) AS customers,
    (SELECT count(*) FROM public.orders)    AS orders,
    (SELECT count(*) FROM public.payments)  AS payments,
    (SELECT count(*) FROM public.orders
      WHERE status = 'PENDING_RECONCILE')   AS poisoned_rows_remaining;
