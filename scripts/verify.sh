#!/usr/bin/env bash
# Strict preflight for the fully live Nightshift demo.
set -uo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PASS=0
FAIL=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { bad "$*"; FAIL=$((FAIL + 1)); }

printf '\n%s================ NIGHTSHIFT PREFLIGHT ================%s\n' "$C_CYAN" "$C_RESET"

say "Operator and agent"
for bin in psql curl jq nc ssh; do
    if have "$bin"; then pass "$bin present"; else fail "$bin missing"; fi
done
if [[ -n "$AGENT_SSH_RESOURCE" && -f "$SDM_SSH_CONFIG" ]]; then
    pass "operator is targeting $AGENT_SSH_RESOURCE through StrongDM SSH"
else
    fail "StrongDM SSH configuration missing; run ./scripts/live-demo.sh operator-tunnel"
fi
if agent_exec "command -v sdm >/dev/null && command -v picoclaw >/dev/null"; then
    pass "sdm and picoclaw present on agent VM"
else
    fail "sdm or picoclaw missing on agent VM"
fi

STATUS="$(agent_exec "sdm status" 2>&1)"
if printf '%s' "$STATUS" | grep -q "$PG_READ_RESOURCE"; then
    pass "standing read resource connected"
else
    fail "$PG_READ_RESOURCE is not connected on the agent VM"
fi
if printf '%s' "$STATUS" | grep -q "$PG_REMEDIATION_RESOURCE"; then
    fail "remediation resource is already connected; revoke the old grant before presenting"
else
    pass "remediation resource is absent before approval"
fi
ACCESS_REQUESTS="$(agent_exec "sdm access requests" 2>&1 || true)"
if printf '%s' "$ACCESS_REQUESTS" | grep -q 'AccountID.*ResourceID.*Status'; then
    pass "agent can inspect its access-request state"
else
    fail "access-request listing is blocked; verify baseline control-plane permits"
fi

say "Immutable agent boundary"
if agent_exec "test ! -w '${AGENT_WORKSPACE}/bin'"; then
    pass "workspace/bin is not writable by the agent"
else
    fail "workspace/bin is writable by the agent"
fi
for f in db-query.sh sdm-request-access.sh; do
    OWNER="$(agent_exec "stat -c '%U:%G' '${AGENT_WORKSPACE}/bin/${f}'" 2>/dev/null)"
    if [[ "$OWNER" == "root:root" ]]; then pass "$f is root-owned"; else fail "$f owner is $OWNER, expected root:root"; fi
done
if agent_exec "test ! -e '${AGENT_WORKSPACE}/bin/remote-cmd.sh'"; then
    pass "general SSH wrapper is absent"
else
    fail "remote-cmd.sh still exists on the agent VM; rerun bootstrap"
fi
if agent_exec "grep -Fq '$GITHUB_REPO' '${AGENT_WORKSPACE}/AGENT.md'"; then
    pass "agent instructions target $GITHUB_REPO"
else
    fail "agent instructions do not match GITHUB_REPO; rerun bootstrap"
fi

say "Database controls"
if READ_ONE="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh --json 'SELECT 1 AS ok'" 2>&1)"; then
    if [[ "$READ_ONE" == *'"ok":1'* ]]; then pass "standing read query succeeds"; else fail "unexpected read result: $READ_ONE"; fi
else
    fail "standing read query failed: $READ_ONE"
fi

DB_IDENTITY="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh --json 'SELECT current_user AS username'" 2>&1 || true)"
if [[ "$DB_IDENTITY" == *'"username":"shopfront_read"'* ]]; then
    pass "standing resource injects the non-owner shopfront_read identity"
else
    fail "standing resource uses the wrong database identity: $DB_IDENTITY"
fi

if MASKED="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh 'SELECT email FROM public.customers ORDER BY id LIMIT 1'" 2>&1)"; then
    if [[ -n "$MASKED" && "$MASKED" != *@* ]]; then pass "customer email is redacted before reaching the model"; else fail "customer email was not redacted: $MASKED"; fi
else
    fail "customer email probe failed: $MASKED"
fi

if ALIASED="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh 'SELECT email AS contact, phone AS mobile FROM public.customers ORDER BY id LIMIT 1'" 2>&1)"; then
    if [[ "$ALIASED" == *"[REDACTED]"* && "$ALIASED" != *@* && "$ALIASED" != *+1-555-* ]]; then pass "aliased email and phone remain redacted"; else fail "PII redaction is bypassable through aliases: $ALIASED"; fi
else
    fail "aliased PII probe failed: $ALIASED"
fi

if DERIVED="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh \"SELECT email || ':' || phone AS combined FROM public.customers ORDER BY id LIMIT 1\"" 2>&1)"; then
    if [[ "$DERIVED" == *"[REDACTED]:[REDACTED]"* && "$DERIVED" != *@* && "$DERIVED" != *+1-555-* ]]; then pass "derived expressions cannot recover customer PII"; else fail "derived expression exposed customer PII: $DERIVED"; fi
else
    fail "derived PII probe failed: $DERIVED"
fi

for raw_table in private.customer_pii pristine.customers; do
    if RAW_PII="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh \"SELECT email FROM ${raw_table} LIMIT 1\"" 2>&1)"; then
        fail "standing identity can read raw PII from $raw_table"
    elif [[ "$RAW_PII" == *"permission denied"* ]]; then
        pass "standing identity cannot read $raw_table"
    else
        fail "unexpected $raw_table denial: $RAW_PII"
    fi
done

if PHONE="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh 'SELECT phone FROM public.customers ORDER BY id LIMIT 1'" 2>&1)"; then
    if [[ -n "$PHONE" && "$PHONE" != *+1-555-* ]]; then pass "customer phone is redacted"; else fail "customer phone was not redacted: $PHONE"; fi
else
    fail "customer phone probe failed: $PHONE"
fi

if CAPPED="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh 'SELECT id, email FROM public.customers ORDER BY id LIMIT 101'" 2>&1)"; then
    if [[ "$CAPPED" == *"(100 rows)"* ]]; then pass "customer result is capped at 100 rows"; else fail "customer row cap was not observed"; fi
else
    fail "customer row-cap probe failed: $CAPPED"
fi

DENIAL="$(agent_exec "cd '${AGENT_WORKSPACE}' && ./bin/db-query.sh \"UPDATE public.customers SET tier='standard' WHERE id=-1\"" 2>&1)"
DENIAL_RC=$?
if [[ $DENIAL_RC -eq 3 && "$DENIAL" == *"Autonomous agents cannot write through standing production access."* ]]; then
    pass "safe zero-row write probe is denied on standing access"
else
    fail "standing write probe did not return the policy denial: $DENIAL"
fi

if admin_db_up; then
    pass "human operator database connection is available on port 5433"
    ROLE_BOUNDARY="$(psql_admin_q "SELECT bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls) FROM pg_roles WHERE rolname IN ('shopfront_read', 'shopfront_remediation', 'orders_api')" | tr -d '[:space:]')"
    if [[ "$ROLE_BOUNDARY" == "t" ]]; then pass "application and agent database roles are non-administrative"; else fail "database role attributes are too broad"; fi
    RAW_GRANTS="$(psql_admin_q "SELECT has_table_privilege('shopfront_read', 'private.customer_pii', 'SELECT') OR has_table_privilege('shopfront_read', 'pristine.customers', 'SELECT') OR has_table_privilege('shopfront_remediation', 'private.customer_pii', 'SELECT') OR has_table_privilege('shopfront_remediation', 'public.payments', 'SELECT')" | tr -d '[:space:]')"
    if [[ "$RAW_GRANTS" == "f" ]]; then pass "agent database roles have no raw-PII or payment grants"; else fail "an agent database role has a forbidden grant"; fi
    REMEDIATION_GRANTS="$(psql_admin_q "SELECT has_column_privilege('shopfront_remediation', 'public.orders', 'status', 'UPDATE') AND has_column_privilege('shopfront_remediation', 'public.orders', 'payload', 'UPDATE') AND has_column_privilege('shopfront_remediation', 'public.orders', 'created_at', 'UPDATE') AND NOT has_column_privilege('shopfront_remediation', 'public.orders', 'amount_cents', 'UPDATE')" | tr -d '[:space:]')"
    if [[ "$REMEDIATION_GRANTS" == "t" ]]; then pass "remediation identity is limited to the justified order columns"; else fail "remediation column grants do not match the canonical update"; fi
    POISON="$(psql_admin_q "SELECT count(*) FROM public.orders WHERE status='PENDING_RECONCILE'" | tr -d '[:space:]')"
    if [[ "$POISON" == "0" ]]; then pass "database is clean"; else fail "$POISON poisoned rows remain"; fi
else
    fail "open the human connection with: sdm connect $PG_READ_RESOURCE 5433"
fi

say "Live control surfaces"
for port in "$GRAFANA_MCP_PORT" "$GITHUB_MCP_PORT" 18791; do
    if port_open 127.0.0.1 "$port"; then pass "operator-forwarded port $port is open"; else fail "port $port closed; run ./scripts/live-demo.sh operator-tunnel"; fi
done

for name in grafana github; do
    if ! TOOLS="$(agent_exec "picoclaw mcp show '$name'" 2>&1)"; then
        fail "PicoClaw could not enumerate $name tools through StrongDM"
        continue
    fi
    if [[ "$name" == "grafana" ]]; then
        REQUIRED="get_incident add_activity_to_incident create_incident"
    else
        REQUIRED="list_pull_requests issue_write merge_pull_request"
    fi
    for required in $REQUIRED; do
        if printf '%s' "$TOOLS" | grep -q "$required"; then
            pass "$name exposes $required"
        else
            fail "$name tools/list did not expose $required"
        fi
    done
    if agent_exec "picoclaw mcp test '$name' >/dev/null"; then
        pass "PicoClaw reaches $name through its configured /mcp endpoint"
    else
        fail "PicoClaw MCP test failed for $name"
    fi
done

if curl -fsS --max-time 5 "${NIGHTSHIFT_SHIM_URL}/health" >/dev/null 2>&1; then pass "task shim is healthy"; else fail "task shim is unavailable"; fi
if shim_get /jobs >/dev/null 2>&1; then pass "task shim bearer is valid"; else fail "task shim bearer is invalid"; fi

if grafana_ready; then
    if ! grafana_api GET /api/health >/dev/null 2>&1; then
        fail "Grafana API authentication failed"
    elif OPEN="$(irm_list_open_incidents 2>/dev/null)"; then
        if [[ -z "$OPEN" ]]; then pass "no stale Grafana incident"; else fail "stale Grafana incidents: $OPEN"; fi
    else
        fail "could not inspect Grafana incident state"
    fi
else
    fail "GRAFANA_URL and GRAFANA_SA_TOKEN are required"
fi

POLICY_AUDIT="$(sdm audit policies --at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --json --extended 2>/dev/null || true)"
if [[ -z "$POLICY_AUDIT" ]]; then
    fail "cannot inspect the complete StrongDM policy set"
elif printf '%s' "$POLICY_AUDIT" | grep -Eqi 'global access'; then
    fail "Global Access is enabled; the MCP allowlist is not default-deny"
elif printf '%s' "$POLICY_AUDIT" | jq -se '
    [.. | strings | select(test("permit[[:space:]]*\\([[:space:]]*principal[[:space:]]*,[[:space:]]*action[[:space:]]*,[[:space:]]*resource[[:space:]]*\\)[[:space:]]*;"; "i"))] |
    length > 0
  ' >/dev/null 2>&1; then
    fail "an unmanaged unconditional broad permit exists in the policy set"
else
    pass "complete policy inventory contains no Global Access or unconditional broad permit"
fi

if [[ -n "$GITHUB_REPO" && -n "$GITHUB_TOKEN" ]]; then
    PRS="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${GITHUB_REPO}/pulls?state=open&per_page=5" 2>/dev/null || true)"
    NPR="$(printf '%s' "$PRS" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)"
    if [[ "$NPR" -gt 0 ]]; then pass "$GITHUB_REPO has an open PR"; else fail "$GITHUB_REPO needs an open PR"; fi
else
    fail "GITHUB_REPO and read-only GITHUB_TOKEN are required for preflight"
fi

printf '\n%s======================================================%s\n' "$C_CYAN" "$C_RESET"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
printf '%sREADY FOR THE FULLY LIVE DEMO%s\n' "$C_GREEN" "$C_RESET"
