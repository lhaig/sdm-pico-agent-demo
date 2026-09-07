#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — stand up the Nightshift agent VM from nothing.
# =============================================================================
# Ubuntu 24.04. Safe to run as EC2 user-data (runs as root) or by hand with
# sudo. Idempotent: re-running upgrades config and restarts services without
# duplicating anything.
#
#   sudo NIGHTSHIFT_REPO_URL=https://github.com/your-org/SDMChallenge.git \
#        SDM_ADMIN_TOKEN=... \
#        OPENAI_API_KEY=sk-... \
#        ./agent/bootstrap.sh
#
# WHAT IT INSTALLS
#   1. base packages (curl, unzip, jq, postgresql-client, python3)
#   2. picoclaw v0.3.1 from the GitHub release tarball
#   3. the StrongDM CLI
#   4. the agent config, workspace, wrapper scripts and .security.yml
#   5. `sdm login` as the nightshift-agent service account
#   6. `sdm connect` for the standing read resource and two MCP resources
#   7. MCP server registration with picoclaw
#   8. systemd units: nightshift-sdm, picoclaw-gateway, nightshift-shim
#
# WHAT IT DELIBERATELY DOES NOT INSTALL
#   A database password. An SSH private key. A Grafana token. A GitHub PAT.
#   None of those belong on this host and none of them are needed. That is the
#   claim the whole demo rests on — keep it true.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
AGENT_USER="${AGENT_USER:-ubuntu}"
AGENT_HOME="/home/${AGENT_USER}"
PICOCLAW_HOME="${AGENT_HOME}/.picoclaw"
WORKSPACE="/opt/nightshift/workspace"
SHIM_DIR="/opt/nightshift"
LOG_DIR="/var/log/nightshift"
ENV_FILE="/etc/nightshift.env"

PICOCLAW_VERSION="${PICOCLAW_VERSION:-v0.3.1}"

# The URL is DERIVED from the version, deliberately.
#
# This used to default to `.../releases/latest/download/...`, which meant
# PICOCLAW_VERSION was printed in the log and then completely ignored — the box
# always got whatever was newest. PicoClaw is pre-1.0 and its config schema has
# already moved (v0→v1→v2→v3); an unannounced bump between your rehearsal and
# your demo is exactly the kind of thing that eats a morning.
#
# Set PICOCLAW_URL explicitly only if you need to override the asset name.
PICOCLAW_URL="${PICOCLAW_URL:-https://github.com/sipeed/picoclaw/releases/download/${PICOCLAW_VERSION}/picoclaw_Linux_x86_64.tar.gz}"
SDM_CLI_URL="${SDM_CLI_URL:-https://app.strongdm.com/releases/cli/linux}"

# StrongDM resources to make reachable on loopback. Names must match the
# sdm_resource names in terraform/.
PG_READ_RESOURCE="${PG_READ_RESOURCE:-pg-prod-shopfront-read}"
PG_REMEDIATION_RESOURCE="${PG_REMEDIATION_RESOURCE:-pg-prod-shopfront-remediation}"
PG_READ_PORT="${PG_READ_PORT:-5432}"
PG_REMEDIATION_PORT="${PG_REMEDIATION_PORT:-5434}"
SDM_APP_DOMAIN="${SDM_APP_DOMAIN:-app.eu.strongdm.com}"
GRAFANA_MCP_RESOURCE="${GRAFANA_MCP_RESOURCE:-grafana-mcp}"
GITHUB_MCP_RESOURCE="${GITHUB_MCP_RESOURCE:-github-mcp}"
GRAFANA_MCP_PORT="${GRAFANA_MCP_PORT:-10001}"
GITHUB_MCP_PORT="${GITHUB_MCP_PORT:-10002}"

NIGHTSHIFT_REPO_URL="${NIGHTSHIFT_REPO_URL:-}"
CHECKOUT_DIR="${CHECKOUT_DIR:-/opt/SDMChallenge}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[0;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\n\033[0;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo $0)"

# -----------------------------------------------------------------------------
# 0. Locate the repository
# -----------------------------------------------------------------------------
say "Locating repository"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${REPO_DIR}/agent/config.json" ]]; then
    [[ -n "$NIGHTSHIFT_REPO_URL" ]] || \
        die "not running from a checkout and NIGHTSHIFT_REPO_URL is unset"
    apt-get update -qq && apt-get install -y -qq git
    rm -rf "$CHECKOUT_DIR"
    git clone --depth 1 "$NIGHTSHIFT_REPO_URL" "$CHECKOUT_DIR"
    REPO_DIR="$CHECKOUT_DIR"
fi
ok "repo at ${REPO_DIR}"

# -----------------------------------------------------------------------------
# 1. Base packages
# -----------------------------------------------------------------------------
say "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl ca-certificates unzip tar jq \
    postgresql-client-16 \
    python3 python3-venv \
    || apt-get install -y -qq curl ca-certificates unzip tar jq postgresql-client python3 python3-venv
ok "packages installed"

install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$LOG_DIR"
ok "log directory ${LOG_DIR}"

# -----------------------------------------------------------------------------
# 2. PicoClaw
# -----------------------------------------------------------------------------
say "Installing PicoClaw (${PICOCLAW_VERSION})"
# There is NO curl|sh installer for PicoClaw. Anything that tells you otherwise
# is wrong (and would be blocked by picoclaw's own exec deny-patterns, which is
# a pleasing detail). Tarball, extract, install.
if command -v picoclaw >/dev/null 2>&1 && [[ "${FORCE_PICOCLAW:-0}" != "1" ]]; then
    ok "already present: $(picoclaw --version 2>/dev/null || echo 'version unknown')"
else
    TMP="$(mktemp -d)"
    curl -fsSL "$PICOCLAW_URL" -o "${TMP}/picoclaw.tar.gz" \
        || die "could not download picoclaw from ${PICOCLAW_URL}"
    tar -xzf "${TMP}/picoclaw.tar.gz" -C "$TMP"
    BIN="$(find "$TMP" -type f -name picoclaw | head -1)"
    [[ -n "$BIN" ]] || die "no picoclaw binary inside the tarball"
    install -m 0755 "$BIN" /usr/local/bin/picoclaw
    rm -rf "$TMP"
    ok "installed $(picoclaw --version 2>/dev/null || echo 'to /usr/local/bin/picoclaw')"
fi

# -----------------------------------------------------------------------------
# 3. StrongDM CLI
# -----------------------------------------------------------------------------
say "Installing StrongDM CLI"
if command -v sdm >/dev/null 2>&1 && [[ "${FORCE_SDM:-0}" != "1" ]]; then
    ok "already present: $(sdm version 2>/dev/null | head -1 || echo 'version unknown')"
else
    TMP="$(mktemp -d)"
    ( cd "$TMP" && curl -fsSL -J -O "$SDM_CLI_URL" ) \
        || die "could not download the sdm CLI from ${SDM_CLI_URL}"
    ZIP="$(find "$TMP" -maxdepth 1 -name '*.zip' | head -1)"
    [[ -n "$ZIP" ]] || die "no zip downloaded from ${SDM_CLI_URL}"
    unzip -oq "$ZIP" -d "$TMP"
    BIN="$(find "$TMP" -type f -name sdm | head -1)"
    [[ -n "$BIN" ]] || die "no sdm binary inside ${ZIP}"
    install -m 0755 "$BIN" /usr/local/bin/sdm
    rm -rf "$TMP"
    ok "installed $(sdm version 2>/dev/null | head -1 || echo 'to /usr/local/bin/sdm')"
fi

# -----------------------------------------------------------------------------
# 4. Agent config + workspace
# -----------------------------------------------------------------------------
say "Placing agent configuration"
install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_USER" "$PICOCLAW_HOME"
install -d -m 0755 -o root -g root "$WORKSPACE"
install -d -m 0755 -o root -g root "${WORKSPACE}/bin"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${WORKSPACE}/memory"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${WORKSPACE}/sessions"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${WORKSPACE}/state"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${WORKSPACE}/cron"

install -m 0644 -o "$AGENT_USER" -g "$AGENT_USER" \
    "${REPO_DIR}/agent/config.json" "${PICOCLAW_HOME}/config.json"

# AGENT.md, HEARTBEAT.md and MEMORY.md hot-reload on mtime, so copying them
# over a running gateway is safe and takes effect on the next turn.
install -m 0644 -o root -g root \
    "${REPO_DIR}/agent/workspace/AGENT.md"     "${WORKSPACE}/AGENT.md"
if [[ -n "${GITHUB_REPO:-}" ]]; then
    sed -i "s|your-org/shopfront-platform|${GITHUB_REPO}|g" "${WORKSPACE}/AGENT.md"
fi
install -m 0644 -o root -g root \
    "${REPO_DIR}/agent/workspace/HEARTBEAT.md" "${WORKSPACE}/HEARTBEAT.md"

for script in db-query.sh sdm-request-access.sh; do
    install -m 0755 -o root -g root \
        "${REPO_DIR}/agent/workspace/bin/${script}" "${WORKSPACE}/bin/${script}"
done

[[ -f "${WORKSPACE}/memory/MEMORY.md" ]] || \
    install -m 0644 -o "$AGENT_USER" -g "$AGENT_USER" /dev/null "${WORKSPACE}/memory/MEMORY.md"

ok "workspace at ${WORKSPACE}"

# --- .security.yml (model key) -----------------------------------------------
# .security.yml is PicoClaw's documented credential companion file and the
# resolution order is: environment variable > this file > config.json.
#
# The model key goes here because from schema v2 onwards PicoClaw ignores a
# singular `api_key` in config.json.
SECURITY_FILE="${PICOCLAW_HOME}/.security.yml"
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    cat > "$SECURITY_FILE" <<EOF
# Written by bootstrap.sh. Mode 0600.
#
# The OpenAI key is the model credential on this host. There is no target
# database password, Grafana token, or GitHub PAT here.
model_list:
  nightshift:
    api_keys:
      - "${OPENAI_API_KEY}"
EOF

elif [[ ! -f "$SECURITY_FILE" ]]; then
    install -m 0600 -o "$AGENT_USER" -g "$AGENT_USER" \
        "${REPO_DIR}/agent/.security.yml.example" "$SECURITY_FILE"
    warn "no OPENAI_API_KEY given — ${SECURITY_FILE} still has the placeholder"
fi
chown "$AGENT_USER":"$AGENT_USER" "$SECURITY_FILE"
chmod 0600 "$SECURITY_FILE"
ok ".security.yml mode $(stat -c '%a' "$SECURITY_FILE")"

# --- environment file for the units ------------------------------------------
# The shim bearer token and PicoClaw's runtime knobs.
SHIM_TOKEN="${NIGHTSHIFT_SHIM_TOKEN:-}"
if [[ -z "$SHIM_TOKEN" ]]; then
    if [[ -f "$ENV_FILE" ]] && grep -q '^NIGHTSHIFT_SHIM_TOKEN=' "$ENV_FILE"; then
        SHIM_TOKEN="$(grep '^NIGHTSHIFT_SHIM_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')"
    else
        SHIM_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
fi

cat > "$ENV_FILE" <<EOF
# /etc/nightshift.env — written by agent/bootstrap.sh
# Consumed by picoclaw-gateway.service and nightshift-shim.service.

PICOCLAW_HOME=${PICOCLAW_HOME}
PICOCLAW_CONFIG=${PICOCLAW_HOME}/config.json
PICOCLAW_LOG_LEVEL=${PICOCLAW_LOG_LEVEL:-info}
PICOCLAW_HEARTBEAT_ENABLED=${PICOCLAW_HEARTBEAT_ENABLED:-true}

# task-shim
NIGHTSHIFT_SHIM_TOKEN=${SHIM_TOKEN}
NIGHTSHIFT_SHIM_HOST=${NIGHTSHIFT_SHIM_HOST:-127.0.0.1}
NIGHTSHIFT_SHIM_PORT=${NIGHTSHIFT_SHIM_PORT:-18791}
NIGHTSHIFT_SESSION=${NIGHTSHIFT_SESSION:-oncall}
NIGHTSHIFT_LOG_DIR=${LOG_DIR}
PG_REMEDIATION_RESOURCE=${PG_REMEDIATION_RESOURCE}
PG_REMEDIATION_PORT=${PG_REMEDIATION_PORT}
EOF
chmod 0640 "$ENV_FILE"
chown root:"$AGENT_USER" "$ENV_FILE"
ok "${ENV_FILE} written (shim token ${SHIM_TOKEN:0:8}...)"

# --- the shim ----------------------------------------------------------------
install -d -m 0755 "$SHIM_DIR"
install -m 0755 "${REPO_DIR}/agent/shim/task-shim.py" "${SHIM_DIR}/task-shim.py"
ok "task-shim at ${SHIM_DIR}/task-shim.py"

# -----------------------------------------------------------------------------
# 5. PicoClaw onboarding
# -----------------------------------------------------------------------------
say "PicoClaw onboarding"
# `picoclaw onboard` initialises ~/.picoclaw. We have already written a complete
# config.json, so this is belt and braces — and it is interactive, hence
# </dev/null and the tolerant exit handling.
if [[ ! -f "${PICOCLAW_HOME}/.onboarded" ]]; then
    sudo -u "$AGENT_USER" env HOME="$AGENT_HOME" PICOCLAW_HOME="$PICOCLAW_HOME" \
        picoclaw onboard </dev/null >/dev/null 2>&1 || \
        warn "picoclaw onboard returned non-zero — expected if it wanted a TTY; config.json is already in place"
    sudo -u "$AGENT_USER" touch "${PICOCLAW_HOME}/.onboarded"
fi
# onboard may rewrite config.json — put ours back, unconditionally.
install -m 0644 -o "$AGENT_USER" -g "$AGENT_USER" \
    "${REPO_DIR}/agent/config.json" "${PICOCLAW_HOME}/config.json"
ok "config.json in place"

# -----------------------------------------------------------------------------
# 6. StrongDM login + connections (systemd oneshot, so it survives reboot)
# -----------------------------------------------------------------------------
say "Writing systemd units"

# --- nightshift-sdm.service ---------------------------------------------------
# Logs the service account in and opens the loopback listeners. Everything else
# depends on this: without it there is no 127.0.0.1:5432 and no MCP ports.
cat > /usr/local/bin/nightshift-sdm-up <<EOF
#!/usr/bin/env bash
# Log in as the nightshift-agent service account and open the proxied ports.
# Written by agent/bootstrap.sh.
set -euo pipefail

: "\${SDM_ADMIN_TOKEN:?SDM_ADMIN_TOKEN (service account token) is not set — put it in /etc/nightshift-sdm.env}"

# Non-interactive login for a service account. If your CLI build wants a
# different flag, this is the one line to change.
sdm login || { echo "sdm login failed"; exit 1; }

sdm connect ${PG_READ_RESOURCE} ${PG_READ_PORT}
sdm connect ${GRAFANA_MCP_RESOURCE} ${GRAFANA_MCP_PORT}
sdm connect ${GITHUB_MCP_RESOURCE} ${GITHUB_MCP_PORT}

sdm status
EOF
chmod 0755 /usr/local/bin/nightshift-sdm-up

if [[ ! -f /etc/nightshift-sdm.env ]]; then
    cat > /etc/nightshift-sdm.env <<EOF
# Service account token for the nightshift-agent StrongDM identity.
# This is an IDENTITY token, not a production credential: on its own it grants
# only what Cedar policy allows, every use is authorized per action, and it can
# be revoked centrally in one click (Moment 6).
SDM_ADMIN_TOKEN=${SDM_ADMIN_TOKEN:-REPLACE_WITH_SERVICE_ACCOUNT_TOKEN}
SDM_APP_DOMAIN=${SDM_APP_DOMAIN}
PG_REMEDIATION_RESOURCE=${PG_REMEDIATION_RESOURCE}
PG_REMEDIATION_PORT=${PG_REMEDIATION_PORT}
EOF
    chmod 0600 /etc/nightshift-sdm.env
    chown root:root /etc/nightshift-sdm.env
elif [[ -n "${SDM_ADMIN_TOKEN:-}" ]]; then
    sed -i "s|^SDM_ADMIN_TOKEN=.*|SDM_ADMIN_TOKEN=${SDM_ADMIN_TOKEN}|" /etc/nightshift-sdm.env
fi
sed -i '/^SDM_API_HOST=/d' /etc/nightshift-sdm.env
if grep -q '^SDM_APP_DOMAIN=' /etc/nightshift-sdm.env; then
    sed -i "s|^SDM_APP_DOMAIN=.*|SDM_APP_DOMAIN=${SDM_APP_DOMAIN}|" /etc/nightshift-sdm.env
else
    printf 'SDM_APP_DOMAIN=%s\n' "$SDM_APP_DOMAIN" >>/etc/nightshift-sdm.env
fi

cat > /etc/systemd/system/nightshift-sdm.service <<EOF
[Unit]
Description=StrongDM login + proxied connections for the Nightshift agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${AGENT_USER}
EnvironmentFile=/etc/nightshift-sdm.env
ExecStart=/usr/local/bin/nightshift-sdm-up
ExecStop=/usr/local/bin/sdm logout
TimeoutStartSec=120
Restart=no

[Install]
WantedBy=multi-user.target
EOF

# --- picoclaw-gateway.service -------------------------------------------------
cat > /etc/systemd/system/picoclaw-gateway.service <<EOF
[Unit]
Description=PicoClaw gateway (Nightshift agent)
Documentation=https://github.com/sipeed/picoclaw
After=network-online.target nightshift-sdm.service
Wants=network-online.target
Requires=nightshift-sdm.service

[Service]
Type=exec
User=${AGENT_USER}
Group=${AGENT_USER}
WorkingDirectory=${WORKSPACE}
Environment=HOME=${AGENT_HOME}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/local/bin/picoclaw gateway
Restart=always
RestartSec=5s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=${PICOCLAW_HOME} ${WORKSPACE}/memory ${WORKSPACE}/sessions ${WORKSPACE}/state ${WORKSPACE}/cron ${LOG_DIR}

StandardOutput=journal
StandardError=journal
SyslogIdentifier=picoclaw

[Install]
WantedBy=multi-user.target
EOF

# --- nightshift-shim.service --------------------------------------------------
cat > /etc/systemd/system/nightshift-shim.service <<EOF
[Unit]
Description=Nightshift task shim (incident webhook -> picoclaw agent)
After=network-online.target picoclaw-gateway.service
Wants=network-online.target

[Service]
Type=exec
User=${AGENT_USER}
Group=${AGENT_USER}
WorkingDirectory=${WORKSPACE}
Environment=HOME=${AGENT_HOME}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 ${SHIM_DIR}/task-shim.py
Restart=always
RestartSec=5s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=${PICOCLAW_HOME} ${WORKSPACE}/memory ${WORKSPACE}/sessions ${WORKSPACE}/state ${WORKSPACE}/cron ${LOG_DIR}

StandardOutput=journal
StandardError=journal
SyslogIdentifier=nightshift-shim

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ok "units written"

# -----------------------------------------------------------------------------
# 7. Start StrongDM, then register the MCP servers
# -----------------------------------------------------------------------------
say "Starting StrongDM connections"
if grep -q 'REPLACE_WITH_SERVICE_ACCOUNT_TOKEN' /etc/nightshift-sdm.env; then
    warn "no service account token yet — edit /etc/nightshift-sdm.env then:"
    warn "  systemctl start nightshift-sdm"
else
    systemctl enable --now nightshift-sdm.service || warn "nightshift-sdm failed to start"
    sleep 3
    sudo -u "$AGENT_USER" env HOME="$AGENT_HOME" sdm status || true
fi

say "Registering MCP servers with PicoClaw"
# config.json already declares both servers. `picoclaw mcp add` is run only if
# the server is not already known, so this stays idempotent and matches the
# build plan's documented wiring.
register_mcp() {
    local name="$1" port="$2"
    if sudo -u "$AGENT_USER" env HOME="$AGENT_HOME" PICOCLAW_HOME="$PICOCLAW_HOME" \
        picoclaw mcp show "$name" >/dev/null 2>&1; then
        ok "mcp '${name}' already registered"
    else
        if sudo -u "$AGENT_USER" env HOME="$AGENT_HOME" PICOCLAW_HOME="$PICOCLAW_HOME" \
            picoclaw mcp add "$name" --transport http "http://127.0.0.1:${port}/mcp"; then
            ok "mcp '${name}' registered on 127.0.0.1:${port}"
        else
            warn "could not register mcp '${name}' — config.json declares it anyway"
        fi
    fi
}
# No Authorization header: the PAT is held by StrongDM and injected by the
# proxy. Nothing here knows the token. Worth showing on stage.
register_mcp "grafana" "$GRAFANA_MCP_PORT"
register_mcp "github"  "$GITHUB_MCP_PORT"

# The Cedar action IDs in policies/40-mcp-tool-limits.cedar are these servers'
# tool names matched EXACTLY, and Grafana's have churned (the alerting tools
# were consolidated). Enumerate and reconcile before you present:
#     picoclaw mcp show grafana
#     picoclaw mcp show github

# -----------------------------------------------------------------------------
# 8. Start the agent
# -----------------------------------------------------------------------------
say "Starting services"
systemctl enable --now picoclaw-gateway.service || warn "picoclaw-gateway failed to start"
systemctl enable --now nightshift-shim.service  || warn "nightshift-shim failed to start"
sleep 2

for unit in nightshift-sdm picoclaw-gateway nightshift-shim; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then ok "${unit}: ${state}"; else warn "${unit}: ${state}"; fi
done

# -----------------------------------------------------------------------------
# 9. Summary
# -----------------------------------------------------------------------------
cat <<EOF

=============================================================================
Nightshift agent VM ready.

  workspace       ${WORKSPACE}
  config          ${PICOCLAW_HOME}/config.json
  model key       ${PICOCLAW_HOME}/.security.yml  (mode 0600)
  env             ${ENV_FILE}
  logs            ${LOG_DIR}/  and  journalctl -u picoclaw-gateway -f

  shim token      ${SHIM_TOKEN}
                  ^ put this in scripts/.env as NIGHTSHIFT_SHIM_TOKEN

Next:
  1. ./scripts/verify.sh            pre-flight checklist
  2. ./scripts/trigger-agent.sh     fast path — fire a canned incident
  3. ./scripts/break-it.sh          full path — poison the data, wait for Grafana

Credentials NOT on this host, verify it yourself before you claim it on stage:
  grep -ri 'PGPASSWORD\|BEGIN.*PRIVATE KEY\|ghp_\|glsa_' ${AGENT_HOME} /etc \\
      --exclude-dir=.git 2>/dev/null | grep -v nightshift.env
  (expect: nothing)
=============================================================================
EOF
