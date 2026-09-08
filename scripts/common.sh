#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for the Nightshift operator scripts.
# =============================================================================
# Sourced, never executed:
#     source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Loads scripts/.env, provides output helpers, Grafana REST + IRM helpers, an
# MCP JSON-RPC helper, and a way to run a command on the agent VM whether you
# are sitting on it or not.
#
# The PagerDuty helper that used to live here is gone. So is the CloudWatch
# alarm name. Grafana Alerting replaced the whole chain (§4.1) — see
# grafana_api / irm_* below.
# =============================================================================

# Guard against double-sourcing.
[[ -n "${_NIGHTSHIFT_COMMON_LOADED:-}" ]] && return 0
_NIGHTSHIFT_COMMON_LOADED=1

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
export SCRIPTS_DIR REPO_DIR

# Terraform uses admin API credentials, while SSH and local connections must
# use the operator's authenticated desktop session. Never let one shadow the
# other in child processes.
SDM_USER_ENV=(env -u SDM_API_ACCESS_KEY -u SDM_API_SECRET_KEY -u SDM_API_HOST)

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_CYAN=$'\033[1;36m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_DIM=""
fi

say()  { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { printf '  %s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  { printf '\n%sFATAL: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
load_env() {
    local env_file="${NIGHTSHIFT_ENV_FILE:-${SCRIPTS_DIR}/.env}"
    if [[ -f "$env_file" ]]; then
        # THE ENVIRONMENT WINS OVER THE FILE.
        #
        # secrets.sh runs these scripts under `op run`, which injects the real
        # credentials as environment variables. Sourcing .env afterwards would
        # overwrite them with whatever placeholder the file still carries —
        # GRAFANA_SA_TOKEN=glsa_REPLACE_ME being the obvious way to lose an
        # afternoon. So snapshot anything already set, source, then put the
        # snapshot back.
        local -a preserved
        preserved=()
        local key
        while IFS= read -r key; do
            [[ -n "${!key:-}" ]] && preserved+=("${key}=${!key}")
        done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$env_file")

        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a

        local kv
        for kv in ${preserved[@]+"${preserved[@]}"}; do
            export "${kv?}"
        done
    fi

    # Defaults for everything the scripts touch, so a missing .env produces a
    # useful error at the point of use rather than an unbound-variable crash.

    # -------------------------------------------------------------------------
    # TWO database connections, and they are not interchangeable.
    # -------------------------------------------------------------------------
    # SHOPFRONT_URL — the AGENT's identity (`nightshift-agent`, a service
    # account). Cedar policy 10 forbids every write from a service account on a
    # prod-tagged resource, so this connection can read and nothing else. That
    # is the point of it: verify.sh's redaction check has to run as the agent or
    # it proves nothing, because policy 20 only masks email/phone for the
    # ai-agents role. Do not use it for setup or teardown; it will be refused,
    # and correctly.
    : "${SHOPFRONT_URL:=postgresql://nightshift-agent@127.0.0.1:5432/shopfront}"
    : "${SHOPFRONT_REMEDIATION_URL:=postgresql://nightshift-agent@127.0.0.1:5434/shopfront}"

    # SHOPFRONT_ADMIN_URL — YOUR identity. A SEPARATE `sdm connect` under your
    # own human account, which is in the sre-oncall role and therefore exempt
    # from policy 10:
    #
    #     sdm connect pg-prod-shopfront-admin 5433
    #
    # Everything that mutates the environment goes through this: reset.sh
    # (TRUNCATE + INSERT), break-it.sh (CREATE TABLE + UPDATE) and app/seed.py
    # (CREATE SCHEMA, DROP TABLE, COPY). Note this is still StrongDM-brokered
    # and still fully recorded — it is a different principal, not a bypass.
    : "${SHOPFRONT_ADMIN_URL:=postgresql://127.0.0.1:5433/shopfront}"
    : "${NIGHTSHIFT_SHIM_URL:=http://127.0.0.1:18791}"
    : "${NIGHTSHIFT_SHIM_TOKEN:=}"
    : "${NIGHTSHIFT_SESSION:=oncall}"
    : "${PICOCLAW_GATEWAY_URL:=http://127.0.0.1:18790}"

    : "${PG_READ_RESOURCE:=pg-prod-shopfront-read}"
    : "${PG_REMEDIATION_RESOURCE:=pg-prod-shopfront-remediation}"
    : "${PG_ADMIN_RESOURCE:=pg-prod-shopfront-admin}"
    : "${PG_REMEDIATION_PORT:=5434}"
    # `sdm connect grafana-mcp` -> 10001, `sdm connect github-mcp` -> 10002.
    # These used to be PAGERDUTY_MCP_PORT/GITHUB_MCP_PORT; the Grafana MCP
    # server replaced PagerDuty's (§4.4) and it is self-hosted on mcp-host.
    : "${GRAFANA_MCP_PORT:=13001}"
    : "${GITHUB_MCP_PORT:=13002}"

    # -------------------------------------------------------------------------
    # GRAFANA CLOUD — the incident chain AND the object the agent reads (§6).
    # -------------------------------------------------------------------------
    # GRAFANA_URL      the stack, with scheme. NOT grafana.com.
    # GRAFANA_SA_TOKEN a service account token (glsa_…) created INSIDE the
    #                  stack. NOT a Cloud Access Policy token — that one
    #                  authenticates against grafana.com and will 401 here.
    #                  The scripts need it for the alerting API and for IRM.
    # GRAFANA_STACK_SLUG  the hostname label, used only for printing links.
    : "${GRAFANA_URL:=}"
    : "${GRAFANA_SA_TOKEN:=}"
    : "${GRAFANA_STACK_SLUG:=}"

    # Must equal local.alert_rule_name in terraform/96-grafana.tf, which is
    # "${var.project}-orders-api-5xx". break-it.sh polls for this rule to go
    # firing and verify.sh checks it exists; get it wrong and both report a
    # broken chain that is not broken.
    : "${GRAFANA_ALERT_RULE:=nightshift-orders-api-5xx}"

    # Must equal terraform var.alert_5xx_rate_threshold. trigger-agent.sh quotes
    # it in the canned payload and the agent reads the number back out loud, so
    # a mismatch between the two is audible.
    : "${ALERT_5XX_RATE_THRESHOLD:=0.05}"

    # -------------------------------------------------------------------------
    # mcp-host — the self-hosted MCP server, private subnet, behind the relay.
    # -------------------------------------------------------------------------
    # Used only for printing useful diagnostics. NOTHING IN THESE SCRIPTS TALKS
    # TO IT DIRECTLY, and nothing can: it has no route from anywhere except the
    # StrongDM relay's security group (§4.4). verify.sh reaches the MCP server
    # the same way the agent does, through the loopback port `sdm connect`
    # opens — which is exactly what makes that check meaningful.
    : "${MCP_HOST:=10.20.10.21}"
    : "${MCP_PORT:=8000}"

    : "${AWS_REGION:=eu-west-1}"

    # Act 3: the repository the agent files its postmortem issue against, and
    # where the open PR it will be refused permission to merge lives. Must match
    # terraform var.github_repo and AGENT.md section 2. GITHUB_TOKEN is a
    # read-only PAT used ONLY by verify.sh's pre-flight check — it never goes
    # near the agent VM.
    : "${GITHUB_REPO:=}"
    : "${GITHUB_TOKEN:=}"

    : "${AGENT_SSH_RESOURCE:=agent-vm}"
    : "${SDM_SSH_CONFIG:=${SCRIPTS_DIR}/.sdm-ssh-config}"
    : "${SDM_KNOWN_HOSTS:=${SCRIPTS_DIR}/.sdm-known-hosts}"
    : "${AGENT_HOME:=/home/ubuntu}"
    : "${PICOCLAW_HOME:=${AGENT_HOME}/.picoclaw}"
    : "${AGENT_WORKSPACE:=/opt/nightshift/workspace}"
}

need() {
    local var="$1" why="$2"
    [[ -n "${!var:-}" ]] || die "${var} is not set — ${why}  (see scripts/.env.example)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# Agent VM access
# -----------------------------------------------------------------------------
# Agent-side commands use StrongDM's generated OpenSSH configuration. The
# operator never holds an EC2 private key and the VM has no public SSH ingress.
agent_exec() {
    [[ -f "$SDM_SSH_CONFIG" ]] || die "StrongDM SSH config missing; run ./scripts/live-demo.sh operator-tunnel"
    "${SDM_USER_ENV[@]}" ssh -F "$SDM_SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$SDM_KNOWN_HOSTS" \
        "$AGENT_SSH_RESOURCE" "$@"
}

# -----------------------------------------------------------------------------
# Postgres — read as the AGENT, write as YOURSELF
# -----------------------------------------------------------------------------
# psql_q / psql_file      -> SHOPFRONT_URL       (agent identity, READS ONLY)
# psql_admin_q / _file    -> SHOPFRONT_ADMIN_URL (your identity, writes allowed)
#
# Sending a TRUNCATE down the agent's connection gets you a policy refusal, not
# a reset. That refusal is the demo working; it is not something to work around.

psql_q() {
    # One-shot scalar/table query as the agent. Reads only — see load_env.
    psql "$SHOPFRONT_URL" --no-psqlrc --tuples-only --no-align \
         --set=ON_ERROR_STOP=1 --command "$1" 2>&1
}

psql_file() {
    psql "$SHOPFRONT_URL" --no-psqlrc --set=ON_ERROR_STOP=1 --file "$1"
}

psql_admin_q() {
    psql "$SHOPFRONT_ADMIN_URL" --no-psqlrc --tuples-only --no-align \
         --set=ON_ERROR_STOP=1 --command "$1" 2>&1
}

psql_admin_file() {
    psql "$SHOPFRONT_ADMIN_URL" --no-psqlrc --set=ON_ERROR_STOP=1 --file "$1"
}

admin_db_up() {
    # Is the operator's own connection actually open? Cheap, and it turns "the
    # restore silently did nothing" into one clear sentence.
    psql "$SHOPFRONT_ADMIN_URL" --no-psqlrc --tuples-only --no-align \
         --command 'SELECT 1' >/dev/null 2>&1
}

need_admin_db() {
    admin_db_up && return 0
    die "cannot reach the database as YOU at ${SHOPFRONT_ADMIN_URL%%\?*}

     This operation writes, and the agent's connection (SHOPFRONT_URL) is
     read-only by Cedar policy 10 — a service account may not write to a
     prod-tagged resource. Open a second connection under your own human
     account, which is in sre-oncall and exempt:

         sdm connect ${PG_ADMIN_RESOURCE} 5433

     then set SHOPFRONT_ADMIN_URL in scripts/.env to match."
}

port_open() {
    if have nc; then
        nc -z -w 2 "$1" "$2" >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1
    fi
}

# =============================================================================
# GRAFANA
# =============================================================================
# Everything that used to be a PagerDuty REST call is one of these now. The
# credential is a SERVICE ACCOUNT token (glsa_…) created inside the stack — the
# same kind mcp-grafana holds, and NOT the Cloud Access Policy token that
# remote_write and the grafana_cloud_* data sources use. Mixing those two up
# produces a 401 that names neither (§4.5).

grafana_ready() { [[ -n "$GRAFANA_URL" && -n "$GRAFANA_SA_TOKEN" ]]; }

grafana_api() {
    # grafana_api GET  /api/health                      -> prints JSON
    # grafana_api POST /api/some/path '<json body>'
    #
    # Returns 9 (not 1) when unconfigured, so callers can tell "you did not set
    # this up" apart from "the API said no".
    local method="$1" path="$2" body="${3:-}"
    grafana_ready || return 9

    local args=(
        -sS --fail-with-body -X "$method"
        -H "Authorization: Bearer ${GRAFANA_SA_TOKEN}"
        -H "Accept: application/json"
        -H "Content-Type: application/json"
        --max-time 15
    )
    [[ -n "$body" ]] && args+=( -d "$body" )

    curl "${args[@]}" "${GRAFANA_URL%/}${path}"
}

grafana_alert_rule_state() {
    # grafana_alert_rule_state <rule name> -> "firing" | "pending" | "inactive"
    #                                         "" if the rule is not found
    #
    # This is the Grafana-managed ruler's Prometheus-compatible state endpoint —
    # the same view the Alerting UI shows. It is the CloudWatch
    # `describe-alarms --query MetricAlarms[0].StateValue` of this build.
    local rule="$1"
    have jq || return 9

    grafana_api GET "/api/prometheus/grafana/api/v1/rules" 2>/dev/null \
        | jq -r --arg n "$rule" \
            '[.data.groups[]?.rules[]? | select(.name == $n) | .state] | first // ""' \
            2>/dev/null
}

grafana_alert_rule_exists() {
    # Provisioning API — the authoritative list of Grafana-managed rules,
    # including ones that have never evaluated. `title`, not `name`, here.
    local rule="$1"
    have jq || return 9

    grafana_api GET "/api/v1/provisioning/alert-rules" 2>/dev/null \
        | jq -e --arg n "$rule" 'map(select(.title == $n)) | length > 0' >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# GRAFANA IRM (Incident)
# -----------------------------------------------------------------------------
# ###########################################################################
# #  VERIFY THESE ENDPOINTS AGAINST YOUR OWN STACK BEFORE YOU PRESENT.      #
# #                                                                         #
# #  Grafana IRM's incident API is an RPC-style surface exposed by the      #
# #  incident app plugin, not a REST resource tree:                         #
# #                                                                         #
# #    POST <stack>/api/plugins/grafana-irm-app/resources/api/v1/           #
# #         IncidentsService.CreateIncident                                 #
# #         IncidentsService.QueryIncidentPreviews                          #
# #         IncidentsService.UpdateStatus                                   #
# #         ActivityService.AddActivity                                     #
# #                                                                         #
# #  The method names and the response field the ID lives in are the parts  #
# #  most likely to have moved. `irm_rpc` prints whatever comes back, so    #
# #  the thirty-second check is:                                            #
# #                                                                         #
# #    source scripts/common.sh                                             #
# #    irm_rpc IncidentsService.QueryIncidentPreviews \                     #
# #      '{"query":{"queryString":"status:active","limit":5}}' | jq .       #
# #                                                                         #
# #  If that returns incidents, everything below works. If it 404s, open    #
# #  the network tab in the Incidents UI and read the real path off it.     #
# ###########################################################################
#
# WHY THIS MATTERS AT ALL — §6 IS EXPLICIT ABOUT IT:
# trigger-agent.sh skips WAITING for Grafana, not Grafana itself. It opens a
# REAL IRM incident so that when the agent calls `get_incident` over MCP in
# Act 3, there is something to get. Shortcut that too and Act 3 has nothing to
# read, in front of the customer, with the tool call visibly returning empty.

IRM_BASE="/api/plugins/grafana-irm-app/resources/api/v1"

irm_rpc() {
    # irm_rpc <Service.Method> '<json body>'
    local body="${2:-}"
    [[ -n "$body" ]] || body='{}'
    grafana_api POST "${IRM_BASE}/$1" "$body"
}

irm_open_incident() {
    # irm_open_incident <title> <severity> <summary>  -> prints the incidentID
    #
    # severity: "pending" | "minor" | "major" | "critical" — Grafana's set.
    local title="$1" severity="${2:-minor}" summary="${3:-}"
    have jq || { warn "jq not installed — cannot open an IRM incident"; return 9; }

    local body
    body="$(jq -nc \
        --arg t "$title" --arg s "$severity" --arg d "$summary" \
        '{title:$t, severity:$s, status:"active", isDrill:false, description:$d}')"

    local resp
    resp="$(irm_rpc IncidentsService.CreateIncident "$body")" || return 1

    # The ID has lived at .incident.incidentID; tolerate a couple of shapes
    # rather than failing the whole run on a field rename.
    printf '%s' "$resp" \
        | jq -r '.incident.incidentID // .incidentID // .incident.id // empty' 2>/dev/null
}

irm_list_open_incidents() {
    # Prints one incidentID per line. Empty output = nothing open.
    have jq || return 9

    irm_rpc IncidentsService.QueryIncidentPreviews \
        '{"query":{"queryString":"status:active","orderDirection":"DESC","limit":25}}' 2>/dev/null \
        | jq -r '(.incidentPreviews // .incidents // [])[]? | (.incidentID // .id) // empty' 2>/dev/null
}

irm_close_incident() {
    # irm_close_incident <incidentID> [summary]
    local id="$1"
    have jq || return 9

    local body
    body="$(jq -nc --arg id "$id" '{incidentID:$id, status:"resolved"}')"

    irm_rpc IncidentsService.UpdateStatus "$body" >/dev/null 2>&1
}

irm_incident_url() {
    # A clickable link for the operator. Cosmetic only.
    [[ -n "$GRAFANA_URL" ]] || return 0
    printf '%s/a/grafana-irm-app/incidents/%s' "${GRAFANA_URL%/}" "$1"
}

# -----------------------------------------------------------------------------
# MCP over the StrongDM loopback port
# -----------------------------------------------------------------------------
# NOTE WHAT IS NOT IN THIS FUNCTION: a bearer token.
#
# The caller bearer for mcp-grafana is held by StrongDM's MCP Gateway and
# injected on the way through. We dial 127.0.0.1:10001 with no credential at
# all, exactly as the agent does, and the tools come back. That IS the demo
# (§4.4) — and it is why verify.sh checks the MCP server through this port
# rather than by SSHing to mcp-host and curling it locally, which would prove
# only that a container is running.
#
# `Accept: application/json, text/event-stream` is REQUIRED by the
# streamable-http transport. Omit it and you get a 406 that reads like an auth
# failure.
mcp_rpc() {
    # mcp_rpc <loopback port> <jsonrpc method> [params-json]
    local port="$1" method="$2" params="${3:-}"
    [[ -n "$params" ]] || params='{}'

    curl -sS --max-time 10 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
        "http://127.0.0.1:${port}/mcp"
}

# -----------------------------------------------------------------------------
# Task shim
# -----------------------------------------------------------------------------
shim_post() {
    # shim_post <path> <json-body>
    need NIGHTSHIFT_SHIM_TOKEN "the task shim requires a bearer token"
    curl -sS -X POST \
        -H "Authorization: Bearer ${NIGHTSHIFT_SHIM_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "${NIGHTSHIFT_SHIM_URL}$1"
}

shim_get() {
    curl -sS -H "Authorization: Bearer ${NIGHTSHIFT_SHIM_TOKEN}" \
        "${NIGHTSHIFT_SHIM_URL}$1"
}

# Pretty-print JSON if jq is available, otherwise pass it through untouched.
prettyjson() { if have jq; then jq .; else cat; fi; }

audit_record_count() {
    # audit_record_count <json-or-ndjson> <needle-1> <needle-2> <decision-regex>
    printf '%s\n' "$1" | jq -se \
        --arg first "$2" --arg second "$3" --arg decision "$4" '
        def records:
          .[] |
          if type == "array" then .[]
          elif (.queries? | type) == "array" then .queries[]
          elif (.activities? | type) == "array" then .activities[]
          else .
          end;
        [records |
          select(
            (tostring | contains("nightshift-agent")) and
            (tostring | contains($first)) and
            (tostring | contains($second)) and
            (tostring | test($decision; "i"))
          )
        ] | length
        '
}

audit_has_record() {
    [[ "$(audit_record_count "$@")" -gt 0 ]]
}

load_env
