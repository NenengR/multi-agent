#!/usr/bin/env bash
# install-condor.sh — provisions a fresh Ubuntu 22.04 VPS for the Condor
# multi-agent trading pipeline.
#
# Designed target:  6 vCPU / 12 GB RAM / 200 GB SSD, Ubuntu 22.04 LTS.
# Idempotent: running twice won't duplicate state; safe to re-run after partial failure.
#
# Usage:
#   sudo bash deploy/vps/install-condor.sh
#
# Required before this script runs:
#   1. Clone the repo:  cd ~ && git clone https://github.com/NenengR/condor.git
#   2. Create dir:      sudo mkdir -p /etc/condor
#   3. Copy template:   sudo cp deploy/vps/env.example /etc/condor/secrets.env
#   4. Edit secrets:    sudo nano /etc/condor/secrets.env   (fill all key fields)
#   5. Run THIS script from the cloned repo root.

set -euo pipefail

# ── Paths & helpers ──────────────────────────────────────────────────────
# INSTALL_ROOT is the directory of THIS script (the freshly-cloned condor repo).
# I.e. the install script must live at <repo>/deploy/vps/install-condor.sh.
INSTALL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/etc/condor/secrets.env}"
CONDOR_USER="${CONDOR_USER:-condor}"
LOG_PREFIX="[install-condor]"

msg()   { echo "${LOG_PREFIX} $*"; }
warn()  { echo "${LOG_PREFIX} ⚠ $*"; }
fail()  { echo "${LOG_PREFIX} ✗ $*" >&2; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || fail "Re-run with sudo:  sudo bash $0"
[ -d "${INSTALL_ROOT}/.git" ] || [ -d "${INSTALL_ROOT}/.git_bak" ] || [ -d "${INSTALL_ROOT}/install-condor.sh" ] || \
    fail "Run from a fresh git clone (no .git in ${INSTALL_ROOT})."
[ -f "${SECRETS_FILE}" ] || fail "Missing ${SECRETS_FILE}. Copy deploy/vps/env.example there first."

# Sanity checks: secrets file must have at least one real key
grep -q '^TELEGRAM_TOKEN=[^[:space:]]' "${SECRETS_FILE}" || fail "TELEGRAM_TOKEN is empty in secrets file"
grep -q '^ANTHROPIC_API_KEY=[^[:space:]]' "${SECRETS_FILE}" || fail "ANTHROPIC_API_KEY is empty"
grep -q '^HB_API_PASSWORD=[^[:space:]]' "${SECRETS_FILE}"  || fail "HB_API_PASSWORD is empty"

msg "Install root:  ${INSTALL_ROOT}"
msg "Secrets file:  ${SECRETS_FILE}"

# ── 1. APT packages ──────────────────────────────────────────────────────
msg "1/9. Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git unzip \
    python3 python3-venv python3-dev build-essential \
    nodejs npm nginx-light \
    ufw fail2ban unattended-upgrades

# uv (Python all-in-one toolchain)
if ! command -v uv >/dev/null 2>&1; then
    msg "  installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
# shellcheck disable=SC1091
. "${HOME}/.local/bin/env" 2>/dev/null || true

# Docker CE (we use it for postgres + emqx)
if ! command -v docker >/dev/null 2>&1; then
    msg "  installing docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
fi

# ── 2. Service user ─────────────────────────────────────────────────────
msg "2/9. Ensuring condor user..."
id -u "${CONDOR_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker "${CONDOR_USER}"

CONDOR_HOME="/home/${CONDOR_USER}"
DEPLOY_DIR="${CONDOR_HOME}/condor"

# Copy the deploy repo into the condor user's home if not already there
if [ "${INSTALL_ROOT}" != "${DEPLOY_DIR}" ]; then
    if [ ! -d "${DEPLOY_DIR}" ]; then
        msg "  copying deploy repo to ${DEPLOY_DIR}..."
        cp -a "${INSTALL_ROOT}" "${DEPLOY_DIR}"
    fi
fi

# Make ownership of deploy dir condor-readable
chown -R "${CONDOR_USER}:${CONDOR_USER}" "${DEPLOY_DIR}"

# From here on, everything should reference DEPLOY_DIR (the condor user's copy)
INSTALL_ROOT="${DEPLOY_DIR}"

# Jump into ${SECRETS_FILE} — only root can read
chown root:root "${SECRETS_FILE}" 2>/dev/null || true
chmod 600 "${SECRETS_FILE}"

# ── 2a. Clone the subprojects (no submodules in this repo) ──────────────
msg "2a/9. Cloning condor + hummingbot-api..."
sudo -u "${CONDOR_USER}" HOME="${CONDOR_HOME}" bash <<CLONESUBCMD
set -e
cd "${DEPLOY_DIR}"
[ -d "condor" ]    || git clone --depth 50 --branch deploy/pipeline-customizations https://github.com/NenengR/condor.git condor
[ -d "hummingbot-api" ] || git clone --depth 50 https://github.com/hummingbot/hummingbot-api.git hummingbot-api
CLONESUBCMD

# ── 3. Tailscale ─────────────────────────────────────────────────────────
msg "3/9. Tailscale mesh..."
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --hostname="${TAILSCALE_HOSTNAME:-condor-prod-1}" --accept-routes
fi

# ── 4. Bind condor/hummingbot-api to localhost only ──────────────────────
msg "4/9. UFW rules (Tailscale only)..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0   # so device-mesh traffic reaches us
ufw allow OpenSSH
ufw --force enable

# ── 5. Postgres + EMQX broker via docker compose ─────────────────────────
msg "5/9. Postgres + EMQX broker..."
mkdir -p /opt/condor/data/postgres /opt/condor/data/broker
COMPOSE_DIR=/opt/condor/compose
mkdir -p "${COMPOSE_DIR}"
cat >"${COMPOSE_DIR}/docker-compose.yml" <<'EOFCOMPOSE'
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: hummingbot_api
      POSTGRES_USER: hbot
      POSTGRES_PASSWORD: hummingbot-api
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
      EMQX_DASHBOARD__DEFAULT_PASSWORD: changeme123
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

# hummingbot-api is a sibling docker container that we own and start via
# the systemd ExecStartPost so we can include its health in the unit graph.

# ── 6. Build Python venv + frontend ─────────────────────────────────────
msg "6/9. Python venv + frontend build..."
cd "${INSTALL_ROOT}/condor"

# Install condor venv
sudo -u "${CONDOR_USER}" HOME="/home/${CONDOR_USER}" \
    bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh && . $HOME/.local/bin/env && uv sync'
sudo -u "${CONDOR_USER}" HOME="/home/${CONDOR_USER}" \
    bash -c '. $HOME/.local/bin/env && uv pip install -e ../hummingbot-api'

# Build frontend
sudo -u "${CONDOR_USER}" bash <<'EOF'
cd "$1/condor/frontend"
npm install --omit=dev
npm run build
EOF
sudo rm -rf "${INSTALL_ROOT}/condor/frontend/node_modules"

# ── 7. Generate hummingbot-api/.env (real one, not committed) ──────────
msg "7/9. hummingbot-api .env + docker compose..."
. "${SECRETS_FILE}"

HB_ENV="${INSTALL_ROOT}/hummingbot-api/.env"
cat >"${HB_ENV}" <<EOF
USERNAME=${HB_API_USERNAME}
PASSWORD=${HB_API_PASSWORD}
CONFIG_PASSWORD=${HB_API_PASSWORD}
DEBUG_MODE=false
BROKER_HOST=localhost
BROKER_PORT=1883
BROKER_USERNAME=\${BROKER_USERNAME}
BROKER_PASSWORD=\${BROKER_PASSWORD}
DATABASE_URL=postgresql+asyncpg://hbot:hummingbot-api@localhost:5432/hummingbot_api
GATEWAY_URL=http://localhost:15888
GATEWAY_PASSPHRASE=\${HB_API_PASSWORD}
BOTS_PATH=${INSTALL_ROOT}/hummingbot-api
TAILSCALE_ENABLED=true
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME}-hbot
EOF
chown "${CONDOR_USER}:${CONDOR_USER}" "${HB_ENV}"
chmod 600 "${HB_ENV}"

# Install hummingbot-api (uv pip) — needed because config + bots live in submodule
sudo -u "${CONDOR_USER}" HOME="/home/${CONDOR_USER}" \
    bash -c '. $HOME/.local/bin/env && cd $1/hummingbot-api && uv sync' "${INSTALL_ROOT}"

# Build & run hummingbot-api docker image (managed by condor-infra.service ExecStartPost)
cd "${INSTALL_ROOT}/hummingbot-api"
docker build -t hummingbot-api-local .
# pre-create the container stopped; systemd brings it up
docker run -d --name hummingbot-api \
    --network host \
    --restart unless-stopped \
    --env-file "${HB_ENV}" \
    hummingbot-api-local || true

# ── 8. condor config.yml (real, not committed) ─────────────────────────
msg "8/9. condor config.yml + .env..."
CONDOR_CFG="${INSTALL_ROOT}/condor/config.yml"
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
admin_id: ${ADMIN_USER_ID}
users:
  '${ADMIN_USER_ID}':
    user_id: ${ADMIN_USER_ID}
    role: admin
    created_at: $(date +%s)
    notes: Provisioned by install-condor.sh
server_access:
  local:
    owner_id: ${ADMIN_USER_ID}
    created_at: null
    shared_with: {}
chat_defaults:
  '${ADMIN_USER_ID}': local
web_jwt_secret: ${JWT_SECRET}
version: 1
EOF
fi
chown "${CONDOR_USER}:${CONDOR_USER}" "${CONDOR_CFG}"
chmod 600 "${CONDOR_CFG}"

# Symlink real .env into repo (so condor subproject still reads it)
. "${SECRETS_FILE}"
{
    echo "TELEGRAM_TOKEN=${TELEGRAM_TOKEN}"
    echo "ADMIN_USER_ID=${ADMIN_USER_ID}"
    echo "USE_TAILSCALE=true"
    echo "DEPLOY_HUMMINGBOT_API=true"
    echo "WEB_PORT=${WEB_PORT:-8088}"
    echo "WEB_URL=${WEB_URL:-http://localhost:8088}"
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
    echo "ANTHROPIC_MODEL=${ANTHROPIC_MODEL}"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
    echo "ANTHROPIC_API_KEY_AGENTROUTER=${ANTHROPIC_API_KEY}"
    echo "ANTHROPIC_BASE_URL_AGENTROUTER=${ANTHROPIC_BASE_URL}"
    echo "ANTHROPIC_MODEL_AGENTROUTER=${ANTHROPIC_MODEL}"
    for i in 1 2 3 4 5; do
        key=$(eval echo "$"ANTHROPIC_API_KEY_AGENTROUTER_${i})
        note=$(eval echo "$"ANTHROPIC_API_KEY_AGENTROUTER_${i}_NOTE)
        if [ -n "${key}" ]; then
            echo "ANTHROPIC_API_KEY_AGENTROUTER_${i}=${key}"
            echo "ANTHROPIC_API_KEY_AGENTROUTER_${i}_NOTE=${note}"
        fi
    done
} > "${INSTALL_ROOT}/condor/.env"
chown "${CONDOR_USER}:${CONDOR_USER}" "${INSTALL_ROOT}/condor/.env"
chmod 600 "${INSTALL_ROOT}/condor/.env"

# ── 9. systemd units ────────────────────────────────────────────────────
msg "9/9. systemd service units..."

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
systemctl enable --now condor-infra condor-main condor-bootstrap-pipeline

# ── Final ───────────────────────────────────────────────────────────────
msg ""
msg "✓ install complete. Tailscale IP: $(tailscale ip -1 2>/dev/null || echo '?')"
msg "  condor dashboard:  http://127.0.0.1:8088  (Tailscale only)"
msg "  hummingbot-api:    http://127.0.0.1:8000  (Tailscale only)"
msg ""
msg "  systemctl status condor-infra condor-main condor-bootstrap-pipeline"
msg "  curl -H \"Authorization: Bearer <JWT>\" http://127.0.0.1:${WEB_PORT:-8088}/api/v1/pipeline/health | jq ."
