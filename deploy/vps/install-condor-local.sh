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
#   - Model route is HCNSEC OpenAI-compatible, chosen by Pakle 13 Nov 2026:
#     AGENT_KEY=openai:MiniMax-M3.1-Flash,
#     MODEL_BASE_URL=https://api.hcnsec.cn/v1.
#     OPENAI_API_KEY is left empty here; it is supplied later through a
#     secure route, never by email, before the first dry-run tick.
#   - Loopback binds: after cloning, Condor main.py is patched from
#     host 0.0.0.0 to 127.0.0.1, and the Hummingbot API Dockerfile
#     ENTRYPOINT is patched from --host 0.0.0.0 to --host 127.0.0.1.
#     The script verifies both patches and checks with ss that no
#     service listens on 0.0.0.0 afterwards.
#
# Fase 1.3, 13 Nov 2026. Built after Garing's 03:51 WIB report of two
# blockers in Phase 1.2:
#   - Blocker 1, secrets file: the installer used to append eight local
#     passwords to /etc/condor/secrets.env, but Pakle only allows that
#     file to hold PAPER_MODE=true, LIVE_TRADING_CONFIRMED=no, and
#     CONDOR_ADMIN_USERNAME=admin. Fix: generated local passwords go to
#     a separate file /etc/condor/local-secrets.env (chmod 600) and the
#     script now FAILS if the canonical file holds anything else.
#   - Blocker 2, Telegram: Condor main.py always builds a Telegram
#     Application with TELEGRAM_TOKEN, so condor-main cannot start
#     without a real token. Fix: this local install does NOT run
#     main.py at all. It runs only the FastAPI web app
#     (condor.web.app:create_app) via a new unit condor-web.service,
#     bound to 127.0.0.1:8088. That is code-verified: create_app needs
#     no Telegram token, and condor/web/auth.py signs web JWTs from
#     WEB_JWT_SECRET or a random secret persisted in config.yml, never
#     from TELEGRAM_TOKEN. The Telegram bot is disabled in this mode;
#     the Condor API and infra are unaffected. Strategies are still
#     never started, bootstrap stays disabled.
#
# Fase 1.4, 13 Nov 2026. Built after Garing's 04:19 and 04:22 WIB audits:
#   - Compose file permissions: docker-compose.yml holds database
#     passwords and would be created mode 0644 under root umask 0022.
#     Fix: umask 077 at the top of this script, explicit chmod 600 on
#     the compose file, and a final audit that fails if any credential
#     file (local-secrets, compose, hummingbot-api .env, condor
#     config.yml, condor .env) is not mode 600.
#   - nginx-light: removed from the apt list. It is unused by Condor
#     and its install enables nginx.service with a default site on
#     0.0.0.0:80. Final checks now fail if nginx is enabled or active,
#     and the ss bind check also covers port 80.
#
# Fase 1.5, 13 Nov 2026. Built after Garing's 05:24 WIB install report:
#   - Hummingbot /health 404: the pinned hummingbot-api (commit
#     7ae108f, v1.0.1) has NO /health route. Verified from the pinned
#     source: main.py defines only GET /, returning status running.
#     The Fase 1 check in condor-start-hb-api.sh therefore always
#     failed, exited 1, and failed condor-infra, because that script
#     is condor-infra's ExecStartPost. Fix: check GET / expecting 200.
#     The installer's own /health probe and printed URL are fixed too.
#   - Installer honesty: step 8 only warned when condor-infra or
#     condor-web was not active, so an install could exit 0 with infra
#     down. Step 8 now FAILS the install in that case.
#   - Broker unhealthy: the EMQX healthcheck is unchanged (emqx ping),
#     but a 60s start_period is added, because EMQX first boot is slow
#     and the old 10 retries could mark it unhealthy before it finished
#     starting. The broker cause is not guessed; Garing is asked for
#     docker logs and emqx ctl status output in the Fase 1.5 email.
#     NOTE, corrected in Fase 1.6: the start_period line was NEVER
#     actually added in Fase 1.5, only mentioned in a comment. See the
#     Fase 1.6 section below for the real fix.
#
# Fase 1.6, 13 Nov 2026. Built after Garing's 05:44 WIB audit of f7630da:
#   - Broker healthcheck syntax: the test was ["CMD",
#     "EMQX_HEALTHCHECK=1 emqx ping"]. CMD runs the string as one
#     literal executable name, so Docker reported "executable file not
#     found in $PATH" and the broker stayed unhealthy, even though
#     Garing proved the broker itself is fine (emqx ctl status: node
#     started, emqx ping: pong). Fix: ["CMD-SHELL", ...], which runs
#     via /bin/sh -c so the env assignment is interpreted correctly.
#   - start_period: the real YAML property start_period: 60s is now
#     added to the broker healthcheck. Fase 1.5 only wrote a comment
#     about it and never added the line; that mistake is owned here.
#     This time the generated compose file is validated with a YAML
#     parse before push, so a comment-only fix cannot pass again.
#   - The GET / fix for hummingbot-api from Fase 1.5 is already in the
#     repo; it takes effect when Garing re-runs the installer, which
#     reinstalls condor-start-hb-api.sh. No change to it in Fase 1.6.
#
# Fase 1.7, 13 Nov 2026. Built after Garing's 05:56 WIB audit of f8ef5bb:
#   - Step 2b loopback patch is now idempotent. Fase 1.2 required the
#     0.0.0.0 pattern and failed on rerun against an already-patched
#     checkout (the exact error Garing hit). Now: patch 0.0.0.0 when
#     still public, accept 127.0.0.1 as already correct, fail only when
#     neither pattern is found. Same rule for both files (Condor main.py
#     and Hummingbot API Dockerfile). The rerun then continues to step 3
#     (Compose rewrite) and step 7 (reinstall of condor-start-hb-api.sh
#     with the GET / check), which is what Garing asked to be sure of.
#
# Fase 1.8, 13 Nov 2026. Built after Garing's 06:10 WIB preflight of 06c71c5:
#   - Stale deploy copy: the copy block only copied the repo into
#     DEPLOY_DIR when it did not exist yet. On rerun the old copy
#     (Fase 1.4, 1759fdb) stayed in place, INSTALL_ROOT was reassigned
#     to it, and step 7 installed stale units and scripts, including
#     the old /health-checking startup script. Fix: when DEPLOY_DIR
#     already exists, refresh ONLY deploy/ from the fresh clone
#     (cp -a deploy/.). The subproject checkouts with their local
#     loopback patches, and all generated configs, are left untouched.
#     The installer now also prints the commit its files came from.
#   - Proof of install: after installing condor-start-hb-api.sh,
#     step 7 greps the installed file and FAILS the install if it
#     still checks /health or does not check GET /. A claim of
#     "installed" is now verified, not assumed.
#
# Fase 1.9, 13 Nov 2026. Built after HAMID's ACP diagnosis (08:25-08:40 WIB,
# prompted by Pakle: "kadang problem dari pengaturan ACP nya, coba kamu cek
# apalagi sekarang pakai nya OPENAI bukan Claude Code"):
#   - Tick never used OpenAI: market_screener agent_key resolves to
#     claude-code:hcnsec from agents/market_screener/AGENT.md (strategy
#     frontmatter agent_key null, POST start only sends execution_mode).
#     No code in the Condor repo reads AGENT_KEY or MODEL_BASE_URL from
#     the environment (repo-wide grep: 0 matches), so every model change
#     in condor/.env (HCNSEC, then FortyTwo) changed nothing the tick
#     ran. The engine took the Claude ACP path; ACPClient.start() sends
#     the initialize + session/new handshake through send_request, which
#     waits on a future with NO timeout (the engine's 600s timeout only
#     wraps the prompt stream, not start()). The claude-agent-acp
#     subprocess gets no HCNSEC credentials either: resolve_acp maps
#     them from ANTHROPIC_API_KEY_HCNSEC and ANTHROPIC_BASE_URL_HCNSEC,
#     which this installer never sets. Result: the tick hangs forever,
#     RUNNING, tick_count=0, no error. Same on both providers.
#   - OpenAI path key is a dummy: _build_model passes a hardcoded
#     api_key="not-needed" for openai+base_url (lines 380 and 391 at the
#     pinned commit), never OPENAI_API_KEY from the environment, so a
#     routed tick would 401 against HCNSEC/FortyTwo/Apinex.
#   Fix, step 2c: patch ONLY the openai+custom-base_url branch in
#   condor/acp/pydantic_ai_client.py so it reads OPENAI_API_KEY from
#   the environment and raises a clear RuntimeError when it is empty.
#   The ollama/lmstudio branch keeps "not-needed" on purpose. The patch
#   is idempotent (skip when already patched, fail when the exact
#   unpatched block is not found) and the file is py_compile-checked.
#   The tick itself is then directed to the OpenAI path by passing
#   agent_key and model_base_url in the start POST config (the engine
#   reads config agent_key first), e.g. agent_key
#   openai:nvidia/nemotron-3.5-super-vl:free with model_base_url
#   https://api.fortytwo.network/v1 for the FortyTwo test. No change to
#   the Claude ACP path: it stays unused until a provider mapping for
#   it is deliberately set up.
#
# Usage:
#   sudo bash deploy/vps/install-condor-local.sh
#
# Required before this script runs:
#   1. Clone the repo branch phase1-paper-gate and pull the latest commit:
#        git clone --branch phase1-paper-gate https://github.com/devnfix-cyber/multi-agent
#        cd multi-agent && git pull origin phase1-paper-gate && git rev-parse HEAD
#      Record the HEAD you pulled and report it; do not trust a commit
#      hash printed in this header, it goes stale on every new commit.
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

# Fase 1.4: every file this script creates defaults to owner-only access.
# Garing found 13 Nov 2026 that docker-compose.yml would otherwise be
# created mode 0644 with database passwords inside, readable by all local
# users. umask 077 here, plus explicit chmod 600 on every file that holds
# a credential, closes that hole.
umask 077

INSTALL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/etc/condor/secrets.env}"
LOCAL_SECRETS_FILE="${LOCAL_SECRETS_FILE:-/etc/condor/local-secrets.env}"
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
# The canonical secrets file must hold exactly the three agreed values
# and nothing else. Generated local passwords live in LOCAL_SECRETS_FILE.
grep -q '^PAPER_MODE=true' "${SECRETS_FILE}" || fail "PAPER_MODE must be true in ${SECRETS_FILE}"
grep -q '^LIVE_TRADING_CONFIRMED=no' "${SECRETS_FILE}" || fail "LIVE_TRADING_CONFIRMED must be no in ${SECRETS_FILE}"
grep -q '^CONDOR_ADMIN_USERNAME=[^[:space:]]' "${SECRETS_FILE}" || fail "CONDOR_ADMIN_USERNAME must be set in ${SECRETS_FILE}"
CANONICAL_LINES="$(grep -vcE '^\s*(#|$)' "${SECRETS_FILE}")"
[ "${CANONICAL_LINES}" = "3" ] || fail "${SECRETS_FILE} must hold exactly 3 values (PAPER_MODE, LIVE_TRADING_CONFIRMED, CONDOR_ADMIN_USERNAME), but it holds ${CANONICAL_LINES}. Restore it to the three agreed values and re-run."
grep -qE '^(HB_API|CONFIG|GATEWAY|BROKER|POSTGRES|EMQX|TELEGRAM|ANTHROPIC|OPENAI|TAILSCALE)[A-Z_]*=' "${SECRETS_FILE}" && fail "${SECRETS_FILE} must not hold passwords or credentials, move them to ${LOCAL_SECRETS_FILE}" || true
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
[ -f "${LOCAL_SECRETS_FILE}" ] && . "${LOCAL_SECRETS_FILE}"
[ "${ADMIN_USER_ID:-1}" != "0" ] || fail "ADMIN_USER_ID must not be 0"
# Explicitly reject any live or exchange credentials in this file. This is
# a local install; a live key here means the wrong file was used.
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
# They go ONLY to LOCAL_SECRETS_FILE. The canonical file is never written.
touch "${LOCAL_SECRETS_FILE}"
chown root:root "${LOCAL_SECRETS_FILE}" 2>/dev/null || true
chmod 600 "${LOCAL_SECRETS_FILE}"
ensure_local_password() {
    local name="$1" val="${!1:-}"
    if [ -z "${val}" ]; then
        val="$(openssl rand -hex 16)"
        printf '%s=%s\n' "${name}" "${val}" >> "${LOCAL_SECRETS_FILE}"
        msg "  generated local ${name} (stored only in ${LOCAL_SECRETS_FILE})"
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
# Re-read after generation: canonical file first, then local passwords.
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
# shellcheck disable=SC1090
. "${LOCAL_SECRETS_FILE}"
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
    fail2ban unattended-upgrades
# No nginx-light: it is unused by Condor, and installing it enables
# nginx.service with a default site on 0.0.0.0:80. This install is
# local-only; Condor web already binds 127.0.0.1:8088.

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
    else
        # Fase 1.8: an existing DEPLOY_DIR was copied from an OLD commit
        # (Fase 1.4, 1759fdb) and the old copy was then used as the
        # install source, so step 7 installed stale units and scripts.
        # Refresh ONLY the installer's own files from the fresh clone.
        # The subproject checkouts (condor, hummingbot-api) with their
        # local loopback patches, and all generated configs, are left
        # untouched on purpose.
        msg "  refreshing installer files in existing ${DEPLOY_DIR} from ${INSTALL_ROOT}..."
        mkdir -p "${DEPLOY_DIR}/deploy"
        cp -a "${INSTALL_ROOT}/deploy/." "${DEPLOY_DIR}/deploy/"
        msg "  subproject checkouts and generated configs left untouched"
    fi
    msg "  installer files from commit $(git -C "${INSTALL_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
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

# ── 2b. Loopback binds: patch 0.0.0.0 to 127.0.0.1, then verify ─────────
msg "2b/8. Patching listeners to loopback (127.0.0.1)..."
# Condor main.py _run_dual runs Uvicorn on 0.0.0.0 (line 719 at pinned commit).
# Idempotent (Fase 1.7): a rerun meets an already-patched checkout, so
# patch 0.0.0.0 when still public, accept 127.0.0.1 as already correct,
# and fail only when neither pattern is found. Fase 1.2 required the
# 0.0.0.0 pattern and failed on rerun; that is the bug fixed here.
if grep -q 'host="0.0.0.0"' "${DEPLOY_DIR}/condor/main.py"; then
    sed -i 's/host="0.0.0.0"/host="127.0.0.1"/' "${DEPLOY_DIR}/condor/main.py"
    msg "  Condor main.py patched 0.0.0.0 to 127.0.0.1"
elif grep -q 'host="127.0.0.1"' "${DEPLOY_DIR}/condor/main.py"; then
    msg "  Condor main.py already binds 127.0.0.1, patch skipped"
else
    fail "Condor main.py contains neither 0.0.0.0 nor 127.0.0.1 bind, do not guess a different patch, report this"
fi
grep -q 'host="127.0.0.1"' "${DEPLOY_DIR}/condor/main.py" || fail "Condor main.py loopback patch did not apply"
grep -q 'host="0.0.0.0"' "${DEPLOY_DIR}/condor/main.py" && fail "Condor main.py still contains 0.0.0.0 after patch" || true
# Hummingbot API Dockerfile ENTRYPOINT runs Uvicorn on 0.0.0.0:8000.
# The line is JSON form: "--host", "0.0.0.0", so match the quoted address.
if grep -qF '"0.0.0.0"' "${DEPLOY_DIR}/hummingbot-api/Dockerfile"; then
    sed -i 's/"0.0.0.0"/"127.0.0.1"/' "${DEPLOY_DIR}/hummingbot-api/Dockerfile"
    msg "  Hummingbot API Dockerfile patched 0.0.0.0 to 127.0.0.1"
elif grep -qF '"127.0.0.1"' "${DEPLOY_DIR}/hummingbot-api/Dockerfile"; then
    msg "  Hummingbot API Dockerfile already binds 127.0.0.1, patch skipped"
else
    fail "Hummingbot API Dockerfile contains neither 0.0.0.0 nor 127.0.0.1 bind, do not guess a different patch, report this"
fi
grep -qF '"127.0.0.1"' "${DEPLOY_DIR}/hummingbot-api/Dockerfile" || fail "Hummingbot API Dockerfile loopback patch did not apply"
grep -qF '"0.0.0.0"' "${DEPLOY_DIR}/hummingbot-api/Dockerfile" && fail "Hummingbot API Dockerfile still contains 0.0.0.0 after patch" || true
msg "  both listeners on 127.0.0.1 and verified"

# ── 2c. OpenAI API key: patch pydantic_ai_client.py to read OPENAI_API_KEY ─
# Fase 1.9, 13 Nov 2026. Built after HAMID's ACP diagnosis (08:25-08:40 WIB):
#   - The market_screener tick never used OpenAI at all. Its agent_key
#     resolves to claude-code:hcnsec from agents/market_screener/AGENT.md,
#     because no code in the Condor repo reads AGENT_KEY or
#     MODEL_BASE_URL from the environment (repo-wide grep: 0 matches).
#     So every model change in condor/.env (HCNSEC, then FortyTwo)
#     changed nothing the tick actually ran. The engine took the Claude
#     ACP path, spawned claude-agent-acp, and its handshake has no
#     timeout, so the tick hung forever: RUNNING, tick_count=0, no
#     error. Same symptom on both providers (HCNSEC 27 min, FortyTwo
#     15 min).
#   - Even routed to the OpenAI path, the tick would fail: _build_model
#     passes a hardcoded api_key="not-needed" for openai+base_url
#     (lines 380 and 391 at the pinned commit), never OPENAI_API_KEY
#     from the environment, so HCNSEC/FortyTwo/Apinex would answer 401.
#   Fix: patch ONLY the openai+custom-base_url branch below so it reads
#   OPENAI_API_KEY from the environment and fails loudly when it is
#   empty. The ollama/lmstudio branch keeps "not-needed" on purpose:
#   local inference servers ignore the key.
#   Idempotent (same rule as 2b): skip when already patched, fail only
#   when the exact unpatched block is not found. Never guess a patch.
msg "2c/8. Patching OpenAI API key handling (pydantic_ai_client.py)..."
PYDANTIC_CLIENT="${DEPLOY_DIR}/condor/condor/acp/pydantic_ai_client.py"
if grep -q 'OPENAI_API_KEY is not set' "${PYDANTIC_CLIENT}"; then
    msg "  pydantic_ai_client.py already patched, patch skipped"
else
    python3 - "${PYDANTIC_CLIENT}" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''        # OpenAI with custom base_url (vLLM, TGI, etc.)
        if prefix == "openai" and base_url:
            openai_client = AsyncOpenAI(
                base_url=base_url,
                api_key="not-needed",
                timeout=_local_timeout,
            )
'''
new = '''        # OpenAI with custom base_url (vLLM, TGI, etc.)
        if prefix == "openai" and base_url:
            _openai_key = os.environ.get("OPENAI_API_KEY")
            if not _openai_key:
                raise RuntimeError(
                    "OPENAI_API_KEY is not set. Add it to your .env to use openai:* models with a custom base_url."
                )
            openai_client = AsyncOpenAI(
                base_url=base_url,
                api_key=_openai_key,
                timeout=_local_timeout,
            )
'''
if old not in src:
    print("FAIL pydantic_ai_client.py does not contain the expected openai+base_url block, do not guess a different patch, report this", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(src.replace(old, new, 1))
print("patched")
PYEOF
    msg "  pydantic_ai_client.py patched to read OPENAI_API_KEY from env"
fi
grep -q 'OPENAI_API_KEY is not set' "${PYDANTIC_CLIENT}" || fail "OpenAI API key patch did not apply"
python3 -m py_compile "${PYDANTIC_CLIENT}" || fail "pydantic_ai_client.py does not compile after patch"

# ── 2d. Candle cap: get_candles must never return 720 candles per call ──
# Fase 2.0, 13 Nov 2026. Measured from the pinned code + Garing's log:
#   - The static tick prompt is small (~7k tokens). The blowup is DYNAMIC:
#     tool results accumulate during the tick. One candles call defaults to
#     days=30 (720 candles at 1h, ~20k tokens as a table); 10 pairs is
#     ~200k tokens, enough to exceed FortyTwo's 262,144 limit.
#   - The strategy tells the agent to pass limit=24, but NEITHER
#     get_market_data nor get_candles accepts a limit parameter, so the
#     instruction is silently ignored and the full 30 days come back.
#   Fix: add a limit parameter to get_candles AND to the get_market_data
#   MCP tool, plus an absolute cap of 48 records per call, so no caller
#   (and no model) can fetch more than 48 candles in one call.
#   Idempotent (same rule as 2b/2c): skip when already patched, fail only
#   when the exact unpatched block is not found. Never guess a patch.
msg "2d/8. Capping candles per call (market_data.py)..."
CANDLES_PY="${DEPLOY_DIR}/condor/mcp_servers/hummingbot_api/tools/market_data.py"
if grep -q 'max_records = min(max_records, 48)' "${CANDLES_PY}"; then
    msg "  market_data.py already patched, patch skipped"
else
    python3 - "${CANDLES_PY}" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
# NOTE: every old block below ends with a TRAILING NEWLINE (the closing
# quotes sit on their own line). That pins the end of the match: a plain
# substring check would also match a file where the last changed line
# merely has extra text appended to it, and the patch would then
# "succeed" on a corrupted file. The trailing newline makes that fail.
old_sig = '''async def get_candles(
    client: Any,
    connector_name: str,
    trading_pair: str,
    interval: str = "1h",
    days: int = 30,
) -> dict[str, Any]:
    """
    Get candle data for a trading pair.
'''
new_sig = '''async def get_candles(
    client: Any,
    connector_name: str,
    trading_pair: str,
    interval: str = "1h",
    days: int = 30,
    limit: int | None = None,
) -> dict[str, Any]:
    """
    Get candle data for a trading pair.
'''
old_doc = """        interval: Candle interval (e.g., '1h', '5m', '1d')
        days: Number of days of historical data

    Returns:
        Dictionary containing candles data and formatted table
"""
new_doc = """        interval: Candle interval (e.g., '1h', '5m', '1d')
        days: Number of days of historical data
        limit: Maximum candles to return (caps the record count; absolute cap 48)

    Returns:
        Dictionary containing candles data and formatted table
"""
old_cap = '''    # Adjust for interval multiplier
    interval_num = interval[:-1]
    if interval_num:
        max_records = int(max_records / int(interval_num))

    # Fetch candles
    candles = await client.market_data.get_candles(
        connector_name=connector_name,
'''
new_cap = '''    # Adjust for interval multiplier
    interval_num = interval[:-1]
    if interval_num:
        max_records = int(max_records / int(interval_num))

    # Fase 2.0: cap candles per call. One tool result must not blow up the
    # model context: 30d x 1h is 720 candles (~20k tokens as a table); 10
    # pairs would exceed a 262k context and stall a 1M-context model past
    # its request timeout. The strategy asks for 24; the absolute cap is 48.
    if limit is not None:
        max_records = min(max_records, limit)
    max_records = min(max_records, 48)

    # Fetch candles
    candles = await client.market_data.get_candles(
        connector_name=connector_name,
'''
for label, old, new in (("signature", old_sig, new_sig), ("docstring", old_doc, new_doc), ("cap", old_cap, new_cap)):
    if old not in src:
        print(f"FAIL market_data.py does not contain the expected get_candles {label} block, do not guess a different patch, report this", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new, 1)
open(path, "w").write(src)
print("patched")
PYEOF
    msg "  market_data.py patched: get_candles capped at 48 records"
fi
grep -q 'max_records = min(max_records, 48)' "${CANDLES_PY}" || fail "Candle cap patch did not apply"
python3 -m py_compile "${CANDLES_PY}" || fail "market_data.py does not compile after patch"

# ── 2e. Candle limit passthrough: get_market_data accepts limit ────────
# Fase 2.0, 13 Nov 2026. The MCP tool get_market_data is the only way the
# agent fetches candles, and it never accepted the limit the strategy
# instructs (limit=24). This patch adds the parameter and passes it to
# get_candles, so the strategy instruction finally works. Same idempotent
# rule as 2b/2c/2d: skip when already patched, fail only when the exact
# unpatched block is not found.
msg "2e/8. Adding limit passthrough (hummingbot_api server.py)..."
HB_SERVER_PY="${DEPLOY_DIR}/condor/mcp_servers/hummingbot_api/server.py"
if grep -q 'limit: int | None = None' "${HB_SERVER_PY}"; then
    msg "  server.py already patched, patch skipped"
else
    python3 - "${HB_SERVER_PY}" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
# NOTE: every old block below ends with a TRAILING NEWLINE (the closing
# quotes sit on their own line). That pins the end of the match: a plain
# substring check would also match a file where the last changed line
# merely has extra text appended to it; the trailing newline makes that
# fail instead of patching a corrupted file.
old_sig = '''async def get_market_data(
    data_type: Literal["prices", "candles", "funding_rate", "order_book"],
    connector_name: str,
    trading_pairs: list[str] | None = None,
    trading_pair: str | None = None,
    interval: str = "1h",
    days: int = 30,
    query_type: (
        Literal[
'''
new_sig = '''async def get_market_data(
    data_type: Literal["prices", "candles", "funding_rate", "order_book"],
    connector_name: str,
    trading_pairs: list[str] | None = None,
    trading_pair: str | None = None,
    interval: str = "1h",
    days: int = 30,
    limit: int | None = None,
    query_type: (
        Literal[
'''
old_doc = """        days: Number of days of historical data for 'candles' (default: 30).
        query_type: Order book query type for 'order_book' (default: 'snapshot'). Options: 'snapshot',
            'volume_for_price', 'price_for_volume', 'quote_volume_for_price', 'price_for_quote_volume'.
"""
new_doc = """        days: Number of days of historical data for 'candles' (default: 30).
        limit: Maximum candles to return for 'candles' (the strategy asks for 24; absolute cap 48).
        query_type: Order book query type for 'order_book' (default: 'snapshot'). Options: 'snapshot',
            'volume_for_price', 'price_for_volume', 'quote_volume_for_price', 'price_for_quote_volume'.
"""
old_call = '''        result = await market_data_tools.get_candles(
            client=client,
            connector_name=connector_name,
            trading_pair=trading_pair,
            interval=interval,
            days=days,
        )
        return (
            f"Candles for {result['trading_pair']} on {result['connector_name']}:\\n"
'''
new_call = '''        result = await market_data_tools.get_candles(
            client=client,
            connector_name=connector_name,
            trading_pair=trading_pair,
            interval=interval,
            days=days,
            limit=limit,
        )
        return (
            f"Candles for {result['trading_pair']} on {result['connector_name']}:\\n"
'''
for label, old, new in (("signature", old_sig, new_sig), ("docstring", old_doc, new_doc), ("call", old_call, new_call)):
    if old not in src:
        print(f"FAIL server.py does not contain the expected get_market_data {label} block, do not guess a different patch, report this", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new, 1)
open(path, "w").write(src)
print("patched")
PYEOF
    msg "  server.py patched: get_market_data accepts limit"
fi
grep -q 'limit: int | None = None' "${HB_SERVER_PY}" || fail "Limit passthrough patch did not apply"
python3 -m py_compile "${HB_SERVER_PY}" || fail "server.py does not compile after patch"

# ── 2f. Routine allowlist: market_screener may call manage_routines ───
# Fase 2.0, 13 Nov 2026. The strategy's preferred Step 0 is the
# scan_universe routine: one call returns the whole ranked table, instead
# of ~10 per-pair get_market_data calls. But the agent could never call it:
# manage_routines is not in the AGENT.md tools allowlist, and
# _prepare_tools filters everything else out before the model sees it.
# Garing confirmed the routine "tidak tersedia dan tidak berjalan" on the
# MiniMax tick. This patch adds it to the allowlist.
# NOTE: the allowlist is by tool NAME, so the agent also gains the
# routine tool's other actions (list/describe/create/edit/delete). The
# strategy only instructs run; this is our own screener in a dry-run
# experiment, and the routine it runs (scan_universe) is code-reviewed.
# If the routine fails at runtime, the strategy falls back to
# get_market_data per pair, so the tick still works.
# Idempotent: skip when already present, fail only when the exact
# unpatched tools list is not found.
msg "2f/8. Adding manage_routines to the market_screener allowlist..."
SCREENER_AGENT_MD="${DEPLOY_DIR}/condor/agents/market_screener/AGENT.md"
if grep -q '^- manage_routines$' "${SCREENER_AGENT_MD}"; then
    msg "  market_screener AGENT.md already patched, patch skipped"
else
    python3 - "${SCREENER_AGENT_MD}" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
# NOTE: the old block below ends with a TRAILING NEWLINE (the closing
# quotes sit on their own line). That pins the end of the match: a plain
# substring check would also match a file where the last list line merely
# has extra text appended to it; the trailing newline makes that fail
# instead of patching a corrupted file.
old = '''tools:
- get_market_data
- manage_signal
- manage_memory
- manage_skill
- search_history
when_to_consult: When the user asks which pairs are worth trading right now, where
  the market's opportunities are, or wants a ranked watchlist across many perpetual
'''
new = '''tools:
- get_market_data
- manage_signal
- manage_memory
- manage_skill
- search_history
- manage_routines
when_to_consult: When the user asks which pairs are worth trading right now, where
  the market's opportunities are, or wants a ranked watchlist across many perpetual
'''
if old not in src:
    print("FAIL market_screener AGENT.md does not contain the expected tools list, do not guess a different patch, report this", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(src.replace(old, new, 1))
print("patched")
PYEOF
    msg "  market_screener AGENT.md patched: manage_routines allowlisted"
fi
grep -q '^- manage_routines$' "${SCREENER_AGENT_MD}" || fail "Routine allowlist patch did not apply"

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
      test: ["CMD-SHELL", "EMQX_HEALTHCHECK=1 emqx ping"]
      interval: 10s
      retries: 10
      start_period: 60s
      # Fase 1.6: the test MUST be CMD-SHELL, not CMD. CMD runs the
      # string as one literal executable name, so Docker reported
      # "executable file not found in $PATH" and the broker stayed
      # unhealthy even though emqx ctl status and emqx ping both work
      # inside the container. CMD-SHELL runs it via /bin/sh -c, so the
      # env assignment is interpreted correctly. start_period is a real
      # YAML property here (Fase 1.5 only mentioned it in a comment and
      # never added the line); EMQX first boot is slow and needs 60s
      # before failures are counted.
    ports:
      - "127.0.0.1:1883:1883"
      - "127.0.0.1:8083:8083"
      - "127.0.0.1:18083:18083"
    restart: unless-stopped
EOFCOMPOSE
# This file holds database passwords, so it must be owner-only.
chmod 600 "${COMPOSE_DIR}/docker-compose.yml"

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
API_BIND=127.0.0.1
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

# Fase 2.0: preserve an existing model route + key on rerun. Before this,
# every rerun rewrote condor/.env to the HCNSEC default and emptied
# OPENAI_API_KEY (observed at the Fase 1.9 execution), forcing a manual
# restore of the route and key. Now: keep AGENT_KEY / MODEL_BASE_URL /
# OPENAI_API_KEY when the file already sets them non-empty; otherwise
# write the defaults below. Values are never echoed or logged.
_EXISTING_AGENT_KEY=""
_EXISTING_MODEL_BASE_URL=""
_EXISTING_OPENAI_API_KEY=""
if [ -f "${INSTALL_ROOT}/condor/.env" ]; then
    _EXISTING_AGENT_KEY=$(grep -E '^AGENT_KEY=' "${INSTALL_ROOT}/condor/.env" | cut -d= -f2- || true)
    _EXISTING_MODEL_BASE_URL=$(grep -E '^MODEL_BASE_URL=' "${INSTALL_ROOT}/condor/.env" | cut -d= -f2- || true)
    _EXISTING_OPENAI_API_KEY=$(grep -E '^OPENAI_API_KEY=' "${INSTALL_ROOT}/condor/.env" | cut -d= -f2- || true)
fi

{
    echo "ADMIN_USER_ID=${ADMIN_ID}"
    echo "USE_TAILSCALE=false"
    echo "DEPLOY_HUMMINGBOT_API=true"
    echo "WEB_PORT=${WEB_PORT:-8088}"
    echo "WEB_URL=${WEB_URL:-http://localhost:8088}"
    echo "PAPER_MODE=true"
    echo "LIVE_TRADING_CONFIRMED=no"
    echo "CONDOR_ADMIN_USERNAME=${CONDOR_ADMIN_USERNAME:-admin}"
    echo "AGENT_KEY=${_EXISTING_AGENT_KEY:-openai:MiniMax-M3.1-Flash}"
    echo "MODEL_BASE_URL=${_EXISTING_MODEL_BASE_URL:-https://api.hcnsec.cn/v1}"
    echo "OPENAI_API_KEY=${_EXISTING_OPENAI_API_KEY:-}"
} > "${INSTALL_ROOT}/condor/.env"
chown "${CONDOR_USER}:${CONDOR_USER}" "${INSTALL_ROOT}/condor/.env"
chmod 600 "${INSTALL_ROOT}/condor/.env"

mkdir -p "${INSTALL_ROOT}/condor/state" "${INSTALL_ROOT}/condor/agents/_signals/active"
chown -R "${CONDOR_USER}:${CONDOR_USER}" "${INSTALL_ROOT}/condor/state" "${INSTALL_ROOT}/condor/agents/_signals"

# ── 7. systemd units: infra + web API only, main + bootstrap DISABLED ───
# condor-main runs main.py, which always builds a Telegram Application and
# needs a real TELEGRAM_TOKEN. This local install has no Telegram token, so
# it installs condor-web.service instead: the FastAPI web app only
# (condor.web.app:create_app), bound to 127.0.0.1:8088, no bot, no strategies.
msg "7/8. systemd service units (web API only, main and bootstrap DISABLED)..."
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-infra.service" \
    /etc/systemd/system/condor-infra.service
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-web.service" \
    /etc/systemd/system/condor-web.service
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-main.service" \
    /etc/systemd/system/condor-main.service
# Local run: Hummingbot API and Condor are on the same machine, so no
# Tailscale is used. Strip tailscaled.service from the unit's After line
# so the local service does not reference a service that is never installed.
sed -i 's/ tailscaled.service//' /etc/systemd/system/condor-main.service
install -m 0644 "${INSTALL_ROOT}/deploy/vps/systemd/condor-bootstrap-pipeline.service" \
    /etc/systemd/system/condor-bootstrap-pipeline.service
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-bootstrap-pipeline.sh" \
    /usr/local/bin/condor-bootstrap-pipeline.sh
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-restart-agents.sh" \
    /usr/local/bin/condor-restart-agents.sh
install -m 0755 "${INSTALL_ROOT}/deploy/vps/systemd/condor-start-hb-api.sh" \
    /usr/local/bin/condor-start-hb-api.sh
# Fase 1.8: prove the installed startup script is the new one. The old
# script checked /health and failed condor-infra; the new one checks
# GET /. Fail the install if the old check is still in the file.
grep -q '8000/health' /usr/local/bin/condor-start-hb-api.sh && fail "installed condor-start-hb-api.sh still checks /health, the deploy refresh did not apply" || true
grep -qF 'http://localhost:8000/ ||' /usr/local/bin/condor-start-hb-api.sh || fail "installed condor-start-hb-api.sh does not check GET /, the deploy refresh did not apply"
msg "  installed condor-start-hb-api.sh checks GET / (verified)"

systemctl daemon-reload
systemctl enable --now condor-infra condor-web
systemctl disable condor-main condor-bootstrap-pipeline 2>/dev/null || true
systemctl stop condor-main condor-bootstrap-pipeline 2>/dev/null || true

# ── 8. Verify: infra health only, no strategies ─────────────────────────
msg "8/8. Verifying (infra health only, no strategies)..."
sleep 10
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps || warn "could not list compose services"
systemctl is-active condor-infra condor-web || fail "condor-infra or condor-web is not active, installer stops here, check systemctl status and report"
WEB_CODE="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8088/ 2>/dev/null || echo "000")"
msg "condor web API on 127.0.0.1:8088 returned HTTP ${WEB_CODE} (any HTTP code here means the server is up; auth-gated routes may return 401 or 404)"
systemctl is-enabled condor-bootstrap-pipeline 2>/dev/null | grep -q disabled && msg "bootstrap pipeline is disabled, as required" || warn "bootstrap pipeline is NOT disabled, check it before continuing"
curl -sf http://127.0.0.1:8000/ >/dev/null 2>&1 && msg "hummingbot-api /: 200" || warn "hummingbot-api / did not return 200 yet, check condor-start-hb-api.sh and report"
# Credential file audit: no file holding a password may be group- or
# other-readable. Check every runtime file the installer wrote.
for _f in "${LOCAL_SECRETS_FILE}" "${COMPOSE_DIR}/docker-compose.yml" "${HB_ENV}" "${CONDOR_CFG}" "${INSTALL_ROOT}/condor/.env"; do
    [ -f "${_f}" ] || fail "expected credential file missing: ${_f}"
    _mode="$(stat -c %a "${_f}")"
    [ "${_mode}" = "600" ] || fail "credential file ${_f} has mode ${_mode}, expected 600"
done
msg "all credential files are mode 600: local-secrets, compose, hummingbot-api .env, condor config.yml, condor .env"
# Bind check: no service may listen on 0.0.0.0, and port 80 must stay closed.
if command -v ss >/dev/null 2>&1; then
    PUBLIC_BINDS="$(ss -ltn 2>/dev/null | grep -E '0.0.0.0:(80|8000|8088|5432|1883|18083|8083)\b' || true)"
    if [ -n "${PUBLIC_BINDS}" ]; then
        echo "${PUBLIC_BINDS}" >&2
        fail "public bind found on 0.0.0.0, stop every service and report this"
    fi
    msg "no service listens on 0.0.0.0 for ports 80, 8000, 8088, 5432, 1883, 18083, 8083"
fi
# Nginx must not be running or enabled by this install.
if systemctl is-enabled nginx 2>/dev/null | grep -q enabled; then
    fail "nginx.service is enabled, this local-only install must not enable it"
fi
if systemctl is-active nginx 2>/dev/null | grep -q active; then
    fail "nginx.service is active, this local-only install must not start it"
fi
msg "nginx is not enabled or active"

# ── Final ───────────────────────────────────────────────────────────────
msg ""
msg "Local non-trading install complete."
msg "  condor dashboard API: http://127.0.0.1:8088 (web only, no Telegram bot)"
msg "  hummingbot-api:    http://127.0.0.1:8000/"
msg "  canonical secrets file: unchanged, still exactly 3 values"
msg "  local passwords: /etc/condor/local-secrets.env (chmod 600)"
msg "  condor-main and bootstrap: DISABLED, no strategies started, no executor, no order."
msg "  Next: report the / result and systemctl status to HAMID."
msg "  Do NOT start condor-main or condor-bootstrap-pipeline, do NOT enter any API key,"
msg "  and do NOT connect Gate.io until HAMID sends the next step."
