-- =============================================================================
-- Project Nightshift — FAULT INJECTION.  This is "the incident".
-- =============================================================================
-- Applied by scripts/break-it.sh (full CloudWatch -> PagerDuty chain) or
-- directly by an operator. It CREATEs and UPDATEs, so it runs as YOU — the
-- agent's connection is read-only by Cedar policy 10 and would refuse it:
--
--     psql "$SHOPFRONT_ADMIN_URL" -v ON_ERROR_STOP=1 -f app/poison.sql
--
-- WHAT IT SIMULATES
-- -----------------
-- A half-finished reconciliation job from an upstream payments migration has
-- written 400 orders back with `status = 'PENDING_RECONCILE'` and a `payload`
-- whose `items` key no longer holds an array. orders-api dereferences
-- `payload["items"]` on every read and does arithmetic over it, so those rows
-- raise, the request 500s, and because the list endpoint sorts by
-- `created_at DESC` the poisoned rows sit on page one — the 5xx rate goes
-- vertical within a minute.
--
-- Two distinct malformed shapes, on purpose. The agent should notice there are
-- two, not one, and say so. It is a small tell that it actually looked.
--
--   Shape A (300 rows): payload.items is a STRING       -> TypeError in the API
--   Shape B (100 rows): payload.items is an array whose
--                       elements lack unit_price_cents  -> KeyError in the API
--
-- DETERMINISM
-- -----------
-- Rows are chosen by `ORDER BY id DESC`, not randomly, so the same 400 order
-- IDs are poisoned on every rehearsal and the numbers you quote on stage stay
-- true.
--
-- REVERSIBILITY
-- -------------
-- Original rows are copied to `public.poison_backup` first, so a light-touch
-- undo is possible without a full restore:
--
--     psql "$SHOPFRONT_ADMIN_URL" -f app/restore.sql      # full pristine restore
--     -- or, poison only:
--     UPDATE public.orders o SET status = b.status, payload = b.payload,
--            created_at = b.created_at
--       FROM public.poison_backup b WHERE b.id = o.id;
--
-- scripts/reset.sh uses the full pristine restore between rehearsals.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. public.poison_backup keeps the pre-poison state of every row we touch.
--
--    It is created by app/schema.sql, NOT here. app/restore.sql truncates it
--    unconditionally under ON_ERROR_STOP, so it has to exist from the moment
--    the database does — otherwise the first reset.sh after a clean seed aborts
--    and restores nothing. If this INSERT fails on a missing relation, your
--    database predates that change: re-run app/schema.sql (it is idempotent).
-- -----------------------------------------------------------------------------
-- 1. Choose the victims deterministically.
--    Newest 400 orders that are not already poisoned and not cancelled —
--    a reconciliation job would only ever have touched live orders.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE victims ON COMMIT DROP AS
SELECT id,
       row_number() OVER (ORDER BY id DESC) AS rn
FROM public.orders
WHERE status IN ('PENDING', 'SHIPPED', 'DELIVERED')
ORDER BY id DESC
LIMIT 400;

INSERT INTO public.poison_backup (id, status, payload, created_at)
SELECT o.id, o.status, o.payload, o.created_at
FROM public.orders o
JOIN victims v ON v.id = o.id
ON CONFLICT (id) DO NOTHING;   -- re-running poison must not clobber the backup

-- -----------------------------------------------------------------------------
-- 2. Shape A — payload.items becomes a string.
--    In the API:  for item in payload["items"]  iterates characters,
--                 then item["qty"] raises TypeError.
-- -----------------------------------------------------------------------------
UPDATE public.orders o
SET status     = 'PENDING_RECONCILE',
    payload    = jsonb_build_object(
                     'schema', 2,
                     'channel', 'partner-api',
                     -- the bug: a scalar where an array is required
                     'items', 'RECONCILE-BATCH-2026-08-28-A',
                     'shipping', o.payload -> 'shipping',
                     'reconcile_batch', 'RECONCILE-BATCH-2026-08-28',
                     'reconcile_source', 'payments-migration-v2'
                 ),
    -- float them to the top of the list endpoint so the 5xx rate spikes now
    created_at = now() - (v.rn * interval '3 seconds')
FROM victims v
WHERE v.id = o.id
  AND v.rn <= 300;

-- -----------------------------------------------------------------------------
-- 3. Shape B — payload.items stays an array but the elements lost their price.
--    In the API:  item["unit_price_cents"] raises KeyError.
-- -----------------------------------------------------------------------------
UPDATE public.orders o
SET status     = 'PENDING_RECONCILE',
    payload    = jsonb_build_object(
                     'schema', 2,
                     'channel', 'partner-api',
                     'items', jsonb_build_array(
                                  jsonb_build_object('sku', o.sku, 'qty', o.qty)
                              ),
                     'shipping', o.payload -> 'shipping',
                     'reconcile_batch', 'RECONCILE-BATCH-2026-08-28',
                     'reconcile_source', 'payments-migration-v2'
                 ),
    created_at = now() - (v.rn * interval '3 seconds')
FROM victims v
WHERE v.id = o.id
  AND v.rn > 300;

COMMIT;

-- -----------------------------------------------------------------------------
-- 4. Confirm. This output is what break-it.sh echoes to the operator.
-- -----------------------------------------------------------------------------
SELECT
    'poisoned'                                      AS what,
    count(*)                                        AS rows,
    count(*) FILTER (WHERE jsonb_typeof(payload -> 'items') = 'string') AS shape_a_string_items,
    count(*) FILTER (WHERE jsonb_typeof(payload -> 'items') = 'array')  AS shape_b_missing_price,
    min(id)                                         AS min_order_id,
    max(id)                                         AS max_order_id
FROM public.orders
WHERE status = 'PENDING_RECONCILE';

\echo ''
\echo 'Fault injected. orders-api should begin returning 500 on /orders within seconds.'
\echo 'Verify with:   curl -s -o /dev/null -w "%{http_code}\n" http://<app-01>:8080/orders'
\echo ''
