#!/usr/bin/env bash
# Exercise the canonical remediation statement through standing read access.
set -euo pipefail

[[ $# -eq 0 ]] || {
    printf 'Usage: db-probe-standing-denial.sh\n' >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/db-query.sh" \
    "UPDATE public.orders AS o SET status = b.status, payload = b.payload, created_at = b.created_at FROM public.poison_backup AS b WHERE b.id = o.id AND o.status = 'PENDING_RECONCILE' AND o.payload->>'reconcile_batch' = 'RECONCILE-BATCH-2026-08-28'"
