#!/usr/bin/env bash
# =============================================================================
# trigger-agent.sh — THE FAST PATH. This is the one you use on stage.
# =============================================================================
# Opens a REAL Grafana IRM incident, then posts a canned payload straight to the
# agent's loopback-only task shim. This is the designed live dispatcher: it
# creates a real incident without exposing a public remote-execution webhook.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT OPENS A REAL INCIDENT, AND WHY THAT IS NOT OPTIONAL
# ---------------------------------------------------------------------------
# §6 is explicit: "trigger-agent.sh skips WAITING for Grafana, not Grafana
# itself." Act 3 is the agent calling get_incident over MCP and reading what it
# finds. If the incident does not exist, that tool call returns nothing, in
# front of the customer, and the moment is gone.
#
# So: create the incident first, then hand its real ID to the agent in the
# payload. --no-incident exists for rehearsing the shim alone; do not use it on
# stage.
#
# Usage:
#   ./scripts/trigger-agent.sh                       # open an incident + page
#   ./scripts/trigger-agent.sh --wait                # ...and follow the job
#   ./scripts/trigger-agent.sh --incident-id abc123  # reuse an EXISTING one
#   ./scripts/trigger-agent.sh --no-incident         # shim only. NOT for stage.
#   ./scripts/trigger-agent.sh --ask "Which customer tier generated the most revenue last month?"
#   ./scripts/trigger-agent.sh --dry-run             # print the payload, send nothing
#
# The --ask form drives the opening beat: Nightshift as a day-job data analyst,
# answering a business question against production. Ask it something about
# customers and the answer comes back with email and phone redacted — Moment 2,
# before anything has even gone wrong.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INCIDENT_ID="${INCIDENT_ID:-}"
CREATE_INCIDENT=1
WAIT=0
DRY_RUN=0
ASK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --incident-id) INCIDENT_ID="${2:?}"; CREATE_INCIDENT=0; shift 2 ;;
        --no-incident) CREATE_INCIDENT=0;    shift ;;
        --ask)         ASK="${2:?}";         shift 2 ;;
        --wait)        WAIT=1;               shift ;;
        --dry-run)     DRY_RUN=1;            shift ;;
        -h|--help)     sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown argument '$1'" ;;
    esac
done

# The --ask form is the data-analyst beat and has nothing to do with incidents.
[[ -n "$ASK" ]] && CREATE_INCIDENT=0

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -----------------------------------------------------------------------------
# 1. Open the IRM incident — the thing the agent will read over MCP.
# -----------------------------------------------------------------------------
if [[ $CREATE_INCIDENT -eq 1 && $DRY_RUN -eq 0 ]]; then
    say "Opening a Grafana IRM incident"

    if ! grafana_ready; then
        # A hard failure, not a warning. Paging the agent to investigate an
        # incident that does not exist is worse than not paging it — the tool
        # call comes back empty on stage and you have to explain why.
        die "GRAFANA_URL / GRAFANA_SA_TOKEN are not set in scripts/.env.

     This script must open a REAL incident so that the agent's get_incident
     call in Act 3 returns something (§6). Set them, or — if you are only
     rehearsing the shim — pass --no-incident and accept that Act 3 is dead."
    fi
    have jq || die "jq is required to open an IRM incident — install jq"

    # Severity: Grafana's set is pending | minor | major | critical.
    # "major" rather than "critical" on purpose: critical is what you want to be
    # able to escalate TO if a customer asks what happens next, and starting at
    # the top leaves nowhere to go.
    INCIDENT_ID="$(irm_open_incident \
        "malformed Shopfront order batch detected" \
        "major" \
        "Opened by the authenticated Nightshift live-demo dispatcher after deterministic fault injection." \
        || true)"

    if [[ -z "$INCIDENT_ID" ]]; then
        die "could not open an IRM incident.

     Three things to check, in order:
       1. GRAFANA_SA_TOKEN is a SERVICE ACCOUNT token (glsa_...) created inside
          the stack. A Cloud Access Policy token authenticates against
          grafana.com and 401s here (§4.5).
       2. The free tier allows 3 ACTIVE IRM USERS PER MONTH and enforces it.
          You + the agent = 2. If a colleague has been clicking around in the
          stack, you have lost incident creation until next month.
       3. The IRM RPC path may have moved. See the block comment above
          irm_rpc() in scripts/common.sh for the thirty-second check."
    fi

    ok "incident ${INCIDENT_ID} open"
    info "$(irm_incident_url "$INCIDENT_ID")"
fi

# A stable-looking fallback so --no-incident and --dry-run still produce a
# coherent payload. It is NOT a real incident and get_incident will not find it.
#
# It is INC-4471 and not something PagerDuty-shaped on purpose: this is the same
# ID used in the worked justification example in agent/workspace/AGENT.md and in
# docs/02-demo-script.md. If you change it, change it in all three, or the
# agent's justification will cite an incident it was never handed.
: "${INCIDENT_ID:=INC-4471}"

# -----------------------------------------------------------------------------
# 2. Build the payload
# -----------------------------------------------------------------------------
if [[ -n "$ASK" ]]; then
    ENDPOINT="/task"
    PAYLOAD="$(cat <<EOF
{
  "message": $(printf '%s' "$ASK" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "session": "${NIGHTSHIFT_SESSION}"
}
EOF
)"
else
    ENDPOINT="/incident"
    # -------------------------------------------------------------------------
    # THIS TEXT IS READ BACK OUT LOUD BY THE AGENT. Every noun in it has to be
    # a thing that exists in this build.
    #
    # The payload states only facts established by the deterministic fault
    # injection. It does not pretend the optional Grafana alert rule fired.
    # -------------------------------------------------------------------------
    PAYLOAD="$(cat <<EOF
{
  "incident_id": "${INCIDENT_ID}",
   "title": "malformed Shopfront order batch detected",
  "service": "orders-api",
  "urgency": "high",
  "status": "active",
  "created_at": "${NOW}",
  "html_url": "$(irm_incident_url "$INCIDENT_ID")",
  "session": "${NIGHTSHIFT_SESSION}",
   "details": "The demo dispatcher detected the deterministic reconciliation batch in a malformed state. Expected scope: exactly 400 rows in public.orders with status PENDING_RECONCILE. Grafana IRM incident: ${INCIDENT_ID}. First observed: ${NOW}."
}
EOF
)"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    say "Payload that would be POSTed to ${NIGHTSHIFT_SHIM_URL}${ENDPOINT}"
    printf '%s\n' "$PAYLOAD" | prettyjson
    info "(--dry-run does not open an IRM incident either)"
    exit 0
fi

# -----------------------------------------------------------------------------
# 3. Pre-flight: is the shim actually up? Failing here is much better than
#    failing in front of the room with a silent curl error.
# -----------------------------------------------------------------------------
if ! curl -fsS --max-time 5 "${NIGHTSHIFT_SHIM_URL}/health" >/dev/null 2>&1; then
    die "task shim not responding at ${NIGHTSHIFT_SHIM_URL}
     systemctl status nightshift-shim   /   journalctl -u nightshift-shim -n 50
     (incident ${INCIDENT_ID} is now open — ./scripts/reset.sh will close it)"
fi

# -----------------------------------------------------------------------------
# 4. Fire
# -----------------------------------------------------------------------------
if [[ -n "$ASK" ]]; then
    say "Asking Nightshift a question"
    info "$ASK"
else
    say "Paging Nightshift — ${INCIDENT_ID}"
    info "malformed Shopfront order batch detected"
fi

RESPONSE="$(shim_post "$ENDPOINT" "$PAYLOAD")" || die "POST failed: $RESPONSE"
printf '%s\n' "$RESPONSE" | prettyjson

if have jq; then
    JOB_ID="$(printf '%s' "$RESPONSE" | jq -r '.job_id // empty')"
else
    JOB_ID="$(printf '%s' "$RESPONSE" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
fi
[[ -n "$JOB_ID" ]] || die "no job_id in the response — check the shim logs"

ok "job ${JOB_ID} accepted"
info "the completed job output contains the agent's triage summary."
info "follow the raw run:  journalctl -u nightshift-shim -f"
# Not `[[ ... ]] && info ...` — under `set -e` a false test there is a non-zero
# exit status on a bare command, and the script would end here silently.
if [[ $CREATE_INCIDENT -eq 1 ]]; then
    info "the agent should call get_incident on ${INCIDENT_ID} and get a real answer"
fi

# -----------------------------------------------------------------------------
# Optional: follow the job to completion.
# -----------------------------------------------------------------------------
if [[ $WAIT -eq 1 ]]; then
    say "Following job ${JOB_ID}"
    for _ in $(seq 1 190); do
        sleep 5
        BODY="$(shim_get "/jobs/${JOB_ID}" || true)"
        if have jq; then
            STATE="$(printf '%s' "$BODY" | jq -r '.state // "unknown"')"
        else
            STATE="$(printf '%s' "$BODY" | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')"
        fi
        printf '  %s...\r' "$STATE"
        if [[ "$STATE" != "running" ]]; then
            printf '\n'
            printf '%s\n' "$BODY" | prettyjson
            [[ "$STATE" == "finished" ]] || die "agent job ended in state: $STATE"
            exit 0
        fi
    done
    die "agent job did not finish within the 16-minute driver timeout"
fi
