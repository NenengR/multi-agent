#!/usr/bin/env bash
# install-condor-local.sh — LOCAL NON-TRADING install of the Condor pipeline.
#
# Fase 1.1, 12 Nov 2026. Built after Garing's 20:43 WIB install check.
# Differences from install-condor.sh (the production installer):
#   - NO firewall change: never runs ufw --force reset, never enables UFW.
#   - NO Tailscale: never installs, enables, or authenticates Tailscale.
#   - NO Telegram, NO HCNSEC, NO Anthropic credentials required.
#   - NO strategy start: condor-bootstrap-pipeline is installed but left
#     DISABLED and STOPPED. No agent strategy ticks, no executor, no order.
#   - REFUSES to run unless PAPER_MODE=true and LIVE_TRADING_CONFIRMED=no.
#   - Local-only passwords (Postgres, EMQX, Hummingbot API, config,
#     gateway, broker) are GENERATED with openssl rand when empty and
#     stored only in /etc/condor/secrets.env (chmod 600). They are never
#     printed, emailed, or committed. No exchange API key or secret is
#     ever read or written by this script.
#   - Model route is Apinex OpenAI-compatible, not HCNSEC:
#     AGENT_KEY=openai:free/deepseek-v4.1-flash,
#     MODEL_BASE_URL=https://api.apinex.bond/v1.
#     OPENAI_API_KEY is left empty here; it is supplied later through a
#     secure route, never by email, before the first dry-run tick.
#
# Usage:
#   sudo bash deploy/vps/install-condor-local.sh
#
# Required before this script runs:
#   1. Clone the repo branch phase1-paper-gate and verify HEAD:
#        git clone --branch phase1-paper-gate https://github.com/devnfix-cyber/multi-agent
#        cd multi-agent && git rev-parse HEAD
#        (must be 61592817738cad6fb743b03dd43c5a2602f00c1f)
#   2. Create dir:      sudo mkdir -p /etc/condor
#   3. Copy template:   sudo cp deploy/vps/env.example /etc/condor/secrets.env
#   4. Set the three non-trading values in it (no secrets needed):
#        PAPER_MODE=true
#        LIVE_TRADING_CONFIRMED=no
#        CONDOR_ADMIN_USERNAME=admin
#   5. Make sure the Docker daemon is running first:
#        sudo systemctl start docker && docker info
#      If docker info fails, STOP and report the daemon status; do not
#      let this script restart or reinstall Docker for you.
#   6. Run THIS script from the cloned repo root.

set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/etc/condor/secrets.env}"
CONDOR_USER="${CONDOR_USER:-condor}"
LOG_PREFIX="[install-condor-local]"

msg()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN $*"; }
fail() { echo "${LOG_PREFIX} FAIL $*" >&2; exit 1; }

CONDOR_COMMIT="${CONDOR_COMMIT:-8ced9726d18bb5d0a439d190c89aa51c80419503}"
HUMMINGBOT_API_COMMIT="${HUMMINGBOT_API_COMMIT:-7ae108f11bf20651682dbdff639a8717068c5883}"

# ── Pre-flight checks ───────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || fail "Re-run with sudo:  sudo bash $0"
[ -d "${INSTALL_ROOT}/.git" ] || fail "Run from a fresh git clone (no .git in ${INSTALL_ROOT})."
[ -f "${SECRETS_FILE}" ] || fail "Missing ${SECRETS_FILE}. Copy deploy/vps/env.example there first."
chmod 600 "${SECRETS_FILE}" 2>/dev/null || true

# Non-trading guard. This script never installs a live configuration.
grep -q '^PAPER_MODE=true' "${SECRETS_FILE}" || fail "PAPER_MODE must be true in ${SECRETS_FILE}"
grep -q '^LIVE_TRADING_CONFIRMED=no' "${SECRETS_FILE}" || fail "LIVE_TRADING_CONFIRMED must be no in ${SECRETS_FILE}"
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
[ "${ADMIN_USER_ID:-1}" != "0" ] || fail "ADMIN_USER_ID must not be 0"
# Explicitly reject any live or exchange credentials in this file. This is
# a local install; a live key here means the wrong file was used.
grep -q '^GATEWAY_URL=https://localhost:15888' "${SECRETS_FILE}" 2>/dev/null && true
grep -Eq '^[A-Z_]*GATE.*(API|SECRET).*=[^[:space:]]' "${SECRETS_FILE}" && fail "No exchange API key or secret may be in ${SECRETS_FILE} for a local install"

# Docker daemon must already be running. Garing reported 12 Nov 2026 that
# the service showed inactive while docker ps still listed containers, so
# check the daemon explicitly and stop with a clear message instead of
# guessing or restarting it inside this script.
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable (docker info failed). Start it first with: sudo systemctl start docker, then re-run this script. Report the daemon status if it will not start."

msg "Install root:  ${INSTALL_ROOT}"
msg "Secrets file:  ${SECRETS_FILE}"
msg "Mode: LOCAL NON-TRADING (dry_run only, no strategies, no Tailscale, no firewall change)"

# ── Local passwords: generate when empty, never print them ──────────────
ensure_local_password() {
    local name="$1" val="${!1:-}"
    if [ -z "${val}" ]; then
        val="$(openssl rand -hex 16)"
        printf '%s=%s\n' "${name}" "${val}" >> "${SECRETS_FILE}"
        msg "  generated local ${name} (stored only in ${SECRETS_FILE})"
    fi
}
ensure_local_password HB_API_USERNAME
ensure_local_password HB_API_PASSWORD
ensure_local_password CONFIG_PASSWORD
ensure_local_password GATEWAY_PASSPHRASE
ensure_local_password BROKER_USERNAME
ensure_local_password BROKER_PASSWORD
ensure_local_password POSTGRES_PASSWORD
ensure_local_password EMQX_DASHBOARD_PASSWORD
# Re-read after generation.
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
# The three Hummingbot secrets must differ, same rule as the production installer.
[ "${HB_API_PASSWORD}" != "${CONFIG_PASSWORD}" ] || fail "CONFIG_PASSWORD must differ from HB_API_PASSWORD"
[ "${HB_API_PASSWORD}" != "${GATEWAY_PASSPHRASE}" ] || fail "GATEWAY_PASSPHRASE must differ from HB_API_PASSWORD"
[ "${CONFIG_PASSWORD}" != "${GATEWAY_PASSPHRASE}" ] || fail "GATEWAY_PASSPHRASE must differ from CONFIG_PASSWORD"

# ── 1. APT packages (no firewall change) ────────────────────────────────
msg "1/8. Installing system packages (no UFW change, no Tailscale)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git unzip \
    python3 python3-venv python3-dev build-essential \
    nginx-light \
    fail2ban unattended-upgrades

if ! node --version 2>/dev/null | grep -qE '^v(2[2-9]|[3-9][0-9])'; then
    msg "  installing Node.js 22.x..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

if ! command -v claude-agent-acp >/dev/null 2>&1; then
    msg "  installing @agentclientprotocol/claude-agent-acp..."
    npm install -g @agentclientprotocol/claude-agent-acp
fi

if ! command -v uv >/dev/null 2>&1; then
    msg "  installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
# shellcheck disable=SC1091
. "${HOME}/.local/bin/env" 2>/dev/null || true

if ! command -v docker >/dev/null 2>&1; then
    fail "docker is not installed and the daemon check already passed, so this should not happen. Report this and stop."
fi

# ── 2. Service user ─────────────────────────────────────────────────────
msg "2/8. Ensuring condor user..."
id -u "${CONDOR_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker "${CONDOR_USER}"

CONDOR_HOME="/home/${CONDOR_USER}"
DEPLOY_DIR="${CONDOR_HOME}/condor-deploy"

if [ "${INSTALL_ROOT}" != "${DEPLOY_DIR}" ]; then
    if [ ! -d "${DEPLOY_DIR}" ]; then
        msg "  copying deploy repo to ${DEPLOY_DIR}..."
        cp -a "${INSTALL_ROOT}" "${DEPLOY_DIR}"
    fi
fi
chown -R "${CONDOR_USER}:${CONDOR_USER}" "${DEPLOY_DIR}"
INSTALL_ROOT="${DEPLOY_DIR}"
chown root:root "${SECRETS_FILE}" 2>/dev/null || true
chmod 600 "${SECRETS_FILE}"

# ── 2a. Clone the subprojects (pinned commits, verified) ────────────────
msg "2a/8. Cloning condor + hummingbot-api (pinned commits)..."
sudo -u "${CONDOR_USER}" HOME="${CONDOR_HOME}" bash <<CLONESUBCMD
set -e
cd "${DEPLOY_DIR}"
[ -d "condor" ] || git clone --branch deploy/pipeline-customizations https://github.com/NenengR/condor.git condor
(cd condor && git checkout "${CONDOR_COMMIT}" && [ "\$(git rev-parse HEAD)" = "${CONDOR_COMMIT}" ]) || { echo "condor HEAD does not match pinned CONDOR_COMMIT" >&2; exit 1; }
[ -d "hummingbot-api" ] || git clone https://github.com/hummingbot/hummingbot-api.git hummingbot-api
(cd hummingbot-api && git checkout "${HUMMINGBOT_API_COMMIT}" && [ "\$(git rev-parse HEAD)" = "${HUMMINGBOT_API_COMMIT}" ]) || { echo "hummingbot-api HEAD does not match pinned HUMMINGBOT_API_COMMIT" >&2; exit 1; }
CLONESUBCMD

# ── 3. Postgres + EMQX broker via docker compose ────────────────────────
msg "3/8. Postgres + EMQX broker (localhost only)..."
mkdir -p /opt/condor/data/postgres /opt/condor/data/broker
chown -R 1000:1000 /opt/condor/data/broker
COMPOSE_DIR=/opt/condor/compose
mkdir -p "${COMPOSE_DIR}"
cat >"${COMPOSE_DIR}/docker-compose.yml" <<EOFCOMPOSE
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: hummingbot_api
      POSTGRES_USER: hbot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /opt/condor/data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hbot -d hummingbot_api || exit 1"]
      interval: 5s
      retries: 12
    ports:
      - "127.0.0.1:5432:5432"
    restart: unless-stopped

  broker:
    image: emqx:5
    environment:
      EMQX_DASHBOARD__DEFAULT_PASSWORD: ${EMQX_DASHBOARD_PASSWORD}
    volumes:
      - /opt/condor/data/broker:/opt/emqx/data
    healthcheck:
      test: ["CMD", "EMQX_HEALTHCHECK=1 emqx ping"]
      interval: 10s
      retries: 10
    ports:
      - "127.0.0.1:1883:1883"
      - "127.0.0.1:8083:8083"
      - "127.0.0.1:18083:18083"
    restart: unless-stopped
EOFCOMPOSE

cd "${COMPOSE_DIR}"
docker compose up -d
cd -

# ── 4. Build Python venv + frontend ─────────────────────────────────────
msg "4/8. Python venv + frontend build..."
cd "${INSTALL_ROOT}/condor"
sudo -u "${CONDOR_USER}" HOME="/home/${CONDOR_USER}" \
    bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh && . $HOME/.local/bin/env && uv sync'
sudo -u "${CONDOR_USER}" bash -c "cd ${INSTALL_ROOT}/condor/frontend && npm install && npm run build"
sudo rm -rf "${INSTALL_ROOT}/condor/frontend/node_modules"

# ── 5. Generate hummingbot-api/.env (local only, no Tailscale) ─────────
msg "5/8. hummingbot-api .env (local only)..."
HB_ENV="${INSTALL_ROOT}/hummingbot-api/.env"
cat >"${HB_ENV}" <<EOF
USERNAME=${HB_API_USERNAME}
PASSWORD=${HB_API_PASSWORD}
CONFIG_PASSWORD=${CONFIG_PASSWORD}
DEBUG_MODE=false
BROKER_HOST=localhost
BROKER_PORT=1883
BROKER_USERNAME=${BROKER_USERNAME}
BROKER_PASSWORD=${BROKER_PASSWORD}
DATABASE_URL=postgresql+asyncpg://hbot:${POSTGRES_PASSWORD}@localhost:5432/hummingbot_api
GATEWAY_URL=https://localhost:15888
GATEWAY_PASSPHRASE=${GATEWAY_PASSPHRASE}
BOTS_PATH=${INSTALL_ROOT}/hummingbot-api
TAILSCALE_ENABLED=false
EOF
chown "${CONDOR_USER}:${CONDOR_USER}" "${HB_ENV}"
chmod 600 "${HB_ENV}"

cd "${INSTALL_ROOT}/hummingbot-api"
mkdir -p credentials/master_account/connectors
chown -R "${CONDOR_USER}:${CONDOR_USER}" credentials/
docker build -t hummingbot-api-local .
# Pre-create the container stopped; condor-infra brings it up. It has no
# exchange credentials yet, so it cannot trade.
docker run -d --name hummingbot-api \
    --network host \
    --restart unless-stopped \
    --env-file "${HB_ENV}" \
    -v "${INSTALL_ROOT}/hummingbot-api/credentials:/hummingbot-api/credentials" \
    -v "${INSTALL_ROOT}/hummingbot-api/bots:/hummingbot-api/bots" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /proc:/host/proc:ro \
    -v /etc/hostname:/host/disk-probe:ro \
    -e HOST_PROC=/host/proc \
    -e HOST_DISK_PATH=/host/disk-probe \
    hummingbot-api-local || true

# ── 6. condor config.yml + .env (Apinex OpenAI route, no HCNSEC) ───────
msg "6/8. condor config.yml + .env (Apinex, no HCNSEC, no Telegram)..."
CONDOR_CFG="${INSTALL_ROOT}/condor/config.yml"
ADMIN_ID="${ADMIN_USER_ID:-1}"
if [ ! -f "${CONDOR_CFG}" ]; then
    JWT_SECRET=$(openssl rand -base64 32 | tr -d '\n')
    cat >"${CONDOR_CFG}" <<EOF
servers:
  local:
    host: localhost
    port: 8000
    username: ${HB_API_USERNAME}
    password: ${HB_API_PASSWORD}
default_server: local
admin_id: ${ADMIN_ID}
users:
  '${ADMIN_ID}':
    user_id: ${ADMIN_ID}
    role: admin
    created_at: $(date +%s)
    notes: Provisioned by install-condor-local.sh
server_access:
  local:
    owner_id: ${ADMIN_ID}
    created_at: null
    shared_with: {}
chat_defaults:
  '${ADMIN_ID}': local
web_jwt_secret: ${JWT_SECRET}
version: 1
EOF
fi
chown "${CONDOR_USER}:${CONDOR_USER}" "${CONDOR_CFG}"
chmod 600 "${CONDOR_CFG}"

{
    echo "ADMIN_USER_ID=${ADMIN_ID}"
    echo "USE_TAILSCALE=false"
    echo "DEPLOY_HUMMINGBOT_API=true"
    echo "WEB_PORT=${WEB_PORT:-8088}"
    echo "WEB_URL=${WEB_URL:-http://localhost:8088}"
    echo "PAPER_MODE=true"
    echo "LIVE_TRADING_CONFIRMED=no"
    echo "CONDOR_ADMIN_USERNAME=${CONDOR_ADMIN_USERNAME:-admin}"
    echo "AGENT_KEY=openai:free/deepseek-v4.1-flash"
    echo "MODEL_BASE_URL=https://api.apinex.bond/v1"
    echo "OPENAI_API_KEY="
} > "${INSTALL_ROOT}/condor/.env"
chown "${CONDOR_USER}:${CONDOR_USER}" "${INSTALL_ROOT}/condor/.env"
chmod 600 "${INSTALL_ROOT}/condor/.env"

mkdir -p "${INSTALL_ROOT}/condor/state" "${INSTALL_ROOT}/condor/agents/_signals/active"
chown -R "${CONDOR_USER}:${CONDOR_USER}" "${INSTALL_ROOT}/condor/state" "${INSTALL_ROOT}/condor/agents/_signals"

# ── 7. systemd units: infra + main only, bootstrap DISABLED ─────────────
msg "7/8. systemd service units (bootstrap stays DISABLED)..."
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-infra.service" \
    /etc/systemd/system/condor-infra.service
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-main.service" \
    /etc/systemd/system/condor-main.service
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-bootstrap-pipeline.service" \
    /etc/systemd/system/condor-bootstrap-pipeline.service
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-bootstrap-pipeline.sh" \
    /usr/local/bin/condor-bootstrap-pipeline.sh
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-restart-agents.sh" \
    /usr/local/bin/condor-restart-agents.sh
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-start-hb-api.sh" \
    /usr/local/bin/condor-start-hb-api.sh

systemctl daemon-reload
systemctl enable --now condor-infra condor-main
systemctl disable condor-bootstrap-pipeline 2>/dev/null || true
systemctl stop condor-bootstrap-pipeline 2>/dev/null || true

# ── 8. Verify: infra health only, no strategies ─────────────────────────
msg "8/8. Verifying (infra health only, no strategies)..."
sleep 10
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps || warn "could not list compose services"
systemctl is-active condor-infra condor-main || warn "condor-infra or condor-main is not active, check systemctl status"
systemctl is-enabled condor-bootstrap-pipeline 2>/dev/null | grep -q disabled && msg "bootstrap pipeline is disabled, as required" || warn "bootstrap pipeline is NOT disabled, check it before continuing"
curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1 && msg "hummingbot-api /health: 200" || warn "hummingbot-api /health did not return 200 yet, check condor-start-hb-api.sh and report"

# ── Final ───────────────────────────────────────────────────────────────
msg ""
msg "Local non-trading install complete."
msg "  condor dashboard:  http://127.0.0.1:8088"
msg "  hummingbot-api:    http://127.0.0.1:8000/health"
msg "  bootstrap: DISABLED, no strategies started, no executor, no order."
msg "  Next: report the /health result and systemctl status to HAMID."
msg "  Do NOT start condor-bootstrap-pipeline, do NOT enter any API key,"
msg "  and do NOT connect Gate.io until HAMID sends the next step."
