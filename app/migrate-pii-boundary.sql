-- Move the deployed customer table behind an alias-safe privilege boundary.
-- Run once as the database owner before applying app/security.sql.
\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

DO $$
DECLARE
    public_kind "char";
BEGIN
    SELECT c.relkind
      INTO public_kind
      FROM pg_class AS c
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'customers';

    IF to_regclass('private.customer_pii') IS NULL AND public_kind = 'r' THEN
        ALTER TABLE public.customers SET SCHEMA private;
        ALTER TABLE private.customers RENAME TO customer_pii;
    END IF;

    IF to_regclass('private.customer_pii') IS NULL THEN
        RAISE EXCEPTION 'private.customer_pii is missing; refusing to create an empty customer view';
    END IF;
END
$$;

CREATE OR REPLACE VIEW public.customers
WITH (security_barrier = true) AS
SELECT
    id,
    name,
    '[REDACTED]'::text AS email,
    '[REDACTED]'::text AS phone,
    created_at,
    tier
FROM private.customer_pii;

COMMENT ON TABLE private.customer_pii IS 'Customer master. Raw PII is available only to the orders-api identity and database owner.';
COMMENT ON VIEW public.customers IS 'Agent-safe customer projection. Raw email and phone never cross the database privilege boundary.';

COMMIT;
