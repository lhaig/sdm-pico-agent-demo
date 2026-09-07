#!/usr/bin/env bash
# Inject the deterministic 400-row Shopfront fault used by the live demo.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ "${1:-}" == "" || "${1:-}" == "--no-wait" ]] || die "usage: $0 [--no-wait]"
need_admin_db

ALREADY="$(psql_admin_q "SELECT count(*) FROM public.orders WHERE status='PENDING_RECONCILE'" | tr -d '[:space:]')"
[[ "$ALREADY" == "0" ]] || die "$ALREADY rows are already poisoned; reset first"
psql_admin_q "SELECT 1 FROM information_schema.tables WHERE table_schema='pristine' AND table_name='orders'" | grep -q 1 \
    || die "pristine snapshot missing; run app/seed.py"

say "Injecting deterministic fault"
psql_admin_file "${REPO_DIR}/app/poison.sql" >/dev/null
POISONED="$(psql_admin_q "SELECT count(*) FROM public.orders WHERE status='PENDING_RECONCILE'" | tr -d '[:space:]')"
[[ "$POISONED" == "400" ]] || die "expected 400 poisoned rows, found $POISONED"
ok "exactly 400 rows poisoned"
