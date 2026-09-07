#!/usr/bin/env bash
# Restore the fully live demo to a fail-closed starting state.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need_admin_db

REQUEST_ID=""
if [[ -f "${SCRIPTS_DIR}/.live-demo-state" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPTS_DIR}/.live-demo-state"
fi

say "Restoring database"
psql_admin_file "${REPO_DIR}/app/restore.sql" >/dev/null
POISON="$(psql_admin_q "SELECT count(*) FROM public.orders WHERE status='PENDING_RECONCILE'" | tr -d '[:space:]')"
[[ "$POISON" == "0" ]] || die "restore left $POISON poisoned rows"
ok "database restored"

say "Closing stale incidents"
if grafana_ready && have jq; then
    IDS="$(irm_list_open_incidents)" || die "could not inspect Grafana incident state"
    for id in $IDS; do
        irm_close_incident "$id" "Closed by reset before the next Nightshift run." \
            || die "could not close incident $id"
    done
    sleep 1
    REMAINING_INCIDENTS="$(irm_list_open_incidents)" || die "could not verify Grafana incident closure"
    [[ -z "$REMAINING_INCIDENTS" ]] || die "incidents remain open after reset: $REMAINING_INCIDENTS"
    ok "incident state clean"
else
    die "Grafana credentials and jq are required for a complete reset"
fi

say "Removing agent runtime state"
if [[ -n "$REQUEST_ID" ]]; then
    agent_exec "sdm access cancel '$REQUEST_ID' >/dev/null 2>&1 || sdm access revoke '$REQUEST_ID' >/dev/null 2>&1 || true"
fi
agent_exec "rm -f '${AGENT_WORKSPACE}/sessions/'*; : > '${AGENT_WORKSPACE}/memory/MEMORY.md'"
agent_exec "sdm disconnect '$PG_REMEDIATION_RESOURCE' >/dev/null 2>&1 || true"
STATUS="$(agent_exec "sdm status" 2>&1)"
printf '%s' "$STATUS" | grep -q "$PG_READ_RESOURCE" || die "agent no longer has its standing read resource; restore the ai-agents role"
if printf '%s' "$STATUS" | grep -q "$PG_REMEDIATION_RESOURCE"; then
    die "remediation resource is still connected; revoke the access request in StrongDM"
fi
REQUESTS="$(agent_exec "sdm access requests" 2>&1 || true)"
if printf '%s\n' "$REQUESTS" | awk \
    '$4 ~ /^(Pending|Approved|Granted|Active)$/ { found = 1 } END { exit !found }'; then
    printf '%s\n' "$REQUESTS" >&2
    die "an active remediation request remains; cancel or revoke it before presenting"
fi
ok "agent session cleared and remediation endpoint disconnected"

rm -f "${SCRIPTS_DIR}/.live-demo-state"
ok "reset complete"
