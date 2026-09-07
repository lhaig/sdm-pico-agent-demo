-- Provision non-owner database identities and their exact privilege boundaries.
-- Passwords are read from the environment by psql and never appear in argv.
\set ON_ERROR_STOP on
\getenv read_password TF_VAR_db_read_password
\getenv remediation_password TF_VAR_db_remediation_password
\getenv app_password TF_VAR_db_app_password

BEGIN;

SELECT 'CREATE ROLE shopfront_read LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shopfront_read')
\gexec
SELECT 'CREATE ROLE shopfront_remediation LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shopfront_remediation')
\gexec
SELECT 'CREATE ROLE orders_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'orders_api')
\gexec

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM pg_roles
         WHERE rolname IN ('shopfront_read', 'shopfront_remediation', 'orders_api')
           AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolbypassrls)
    ) THEN
        RAISE EXCEPTION 'refusing to configure a privileged application or agent role';
    END IF;
END
$$;

SELECT format('ALTER ROLE shopfront_read PASSWORD %L', :'read_password')
\gexec
SELECT format('ALTER ROLE shopfront_remediation PASSWORD %L', :'remediation_password')
\gexec
SELECT format('ALTER ROLE orders_api PASSWORD %L', :'app_password')
\gexec

REVOKE CONNECT, TEMPORARY ON DATABASE shopfront FROM PUBLIC;
GRANT CONNECT ON DATABASE shopfront TO shopfront_read, shopfront_remediation, orders_api;

REVOKE ALL ON SCHEMA public, private, pristine FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public, private, pristine FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO shopfront_read, shopfront_remediation, orders_api;
GRANT USAGE ON SCHEMA private TO orders_api;

GRANT SELECT ON public.customers, public.orders, public.order_health TO shopfront_read;

GRANT SELECT (id, status, payload) ON public.orders TO shopfront_remediation;
GRANT UPDATE (status, payload, created_at) ON public.orders TO shopfront_remediation;
GRANT SELECT (id, status, payload, created_at) ON public.poison_backup TO shopfront_remediation;

GRANT SELECT ON public.orders, private.customer_pii TO orders_api;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA pristine REVOKE ALL ON TABLES FROM PUBLIC;

COMMIT;
