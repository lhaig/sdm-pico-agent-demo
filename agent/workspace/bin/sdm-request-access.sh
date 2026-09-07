#!/usr/bin/env bash
# Request and connect the time-bound remediation resource.
set -euo pipefail

RESOURCE="${PG_REMEDIATION_RESOURCE:-pg-prod-shopfront-remediation}"
PORT="${PG_REMEDIATION_PORT:-5434}"
DURATION="15m"
INCIDENT_ID=""
REASON=""
MODE="request"

usage() {
    cat >&2 <<'EOF'
Usage:
  sdm-request-access.sh --incident-id ID --reason TEXT [--duration 15m]
  sdm-request-access.sh --status
  sdm-request-access.sh --connect
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --incident-id) INCIDENT_ID="${2:?--incident-id needs a value}"; shift 2 ;;
        --reason) REASON="${2:?--reason needs a value}"; shift 2 ;;
        --duration) DURATION="${2:?--duration needs a value}"; shift 2 ;;
        --status) MODE="status"; shift ;;
        --connect) MODE="connect"; shift ;;
        -h|--help) usage ;;
        *) echo "sdm-request-access.sh: unknown argument '$1'" >&2; usage ;;
    esac
done

case "$MODE" in
    status)
        sdm status
        exit 0
        ;;
    connect)
        echo "Connecting approved resource ${RESOURCE} on 127.0.0.1:${PORT}"
        sdm connect "$RESOURCE" "$PORT"
        exit 0
        ;;
esac

[[ -n "$INCIDENT_ID" && -n "$REASON" ]] || usage
[[ ${#REASON} -ge 80 ]] || { echo "reason must include the incident, exact SQL, predicate, row count, and rollback" >&2; exit 2; }
[[ "$REASON" == *"$INCIDENT_ID"* ]] || { echo "reason must contain the exact incident ID: $INCIDENT_ID" >&2; exit 2; }
[[ "$DURATION" == "15m" ]] || { echo "this workflow permits exactly 15m" >&2; exit 2; }

printf 'Requesting %s for %s\nReason: %s\n' "$RESOURCE" "$DURATION" "$REASON"
sdm access to "$RESOURCE" --reason "$REASON" --duration "$DURATION"

cat <<EOF
Request submitted. Wait for human approval in Slack. After approval, continue
the same Nightshift session and run:
  ./bin/sdm-request-access.sh --connect
  ./bin/db-query.sh --remediation "<the exact approved UPDATE>"
EOF
