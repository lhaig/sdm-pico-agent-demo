# Shopfront Demo Application

This directory contains the disposable PostgreSQL schema, deterministic seed,
fault injection, restore logic, and the small orders API used by Nightshift.

```bash
sdm connect pg-prod-shopfront-admin 5433
export SHOPFRONT_ADMIN_URL='postgresql://127.0.0.1:5433/shopfront'
psql "$SHOPFRONT_ADMIN_URL" -v ON_ERROR_STOP=1 -f app/schema.sql
python3 app/seed.py
./scripts/secrets.sh exec -- psql "$SHOPFRONT_ADMIN_URL" -f app/security.sql
```

The operator's human connection is used for schema, seed, fault injection, and
reset. The agent's standing connection is read-only and must never be used as a
fallback for administrative work.

Raw customer PII lives in `private.customer_pii`. The standing database
identity can only read the fixed-mask `public.customers` view, so SQL aliases
and derived expressions cannot bypass StrongDM's result-column redaction.

`poison.sql` creates exactly 400 malformed orders. `restore.sql` restores the
pristine snapshot so every live run begins from the same state.
