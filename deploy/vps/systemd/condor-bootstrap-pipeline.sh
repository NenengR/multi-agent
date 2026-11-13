#!/usr/bin/env bash
# condor-bootstrap-pipeline.sh — once condor-main is healthy, POST /start
# for every agent strategy that should be running on a fresh boot.
# Idempotent: agents already running are skipped (engine.start handles re-activating).
#
# Replaces the per-agent systemd drivel. Each tick is run inside condor-main's
# own process; systemd does not manage individual agents.
set -euo pipefail

# Env vars (ADMIN_USER_ID, WEB_PORT, etc.) are loaded by systemd's
# EnvironmentFile directive — no need to source secrets.env here.

BASE_URL="http://localhost:${WEB_PORT:-8088}/api/v1"

# Wait for condor-main to be reachable (it may still be importing uv deps).
echo "[bootstrap] waiting for condor at ${BASE_URL}/pipeline/health ..."
for i in {1..60}; do
    if curl -s --max-time 5 "${BASE_URL}/pipeline/health" -o /dev/null -w '%{http_code}\n' 2>/dev/null | grep -q '^2'; then
        echo "[bootstrap] healthy after ${i}s"; break
    fi
    sleep 1
    [ "$i" -eq 60 ] && { echo "[bootstrap] condor-main never became healthy, aborting"; exit 1; }
done

# Mint a JWT for /start endpoints (admin only)
JWT=$(/home/condor/.local/bin/uv run --directory /home/condor/condor-deploy/condor \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor-deploy/condor'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='${CONDOR_ADMIN_USERNAME:-admin}', role='admin'))")

# Fase 1 paper gate: default is dry_run observation only. Execution agent is
# started only when PAPER_MODE=false and LIVE_TRADING_CONFIRMED=yes.
PAPER_MODE="${PAPER_MODE:-true}"
LIVE_TRADING_CONFIRMED="${LIVE_TRADING_CONFIRMED:-no}"
if [ "${PAPER_MODE}" = "true" ]; then
  EXEC_MODE="dry_run"
else
  EXEC_MODE="loop"
fi

start_strategy() {
    local agent_slug="$1" strategy_slug="$2"
    echo "[bootstrap] starting ${agent_slug}/${strategy_slug} ..."
    curl -sS --max-time 30 -X POST \
        -H "Authorization: Bearer ${JWT}" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":0,\"config\":{\"execution_mode\":\"${EXEC_MODE}\"}}" \
        "${BASE_URL}/agents/${agent_slug}/strategies/${strategy_slug}/start" \
        | jq -c '{ok:(.started|type=="boolean" and .==true), err:(.detail//.started//"unknown")}' \
        || echo "[bootstrap]   failed to start ${agent_slug}/${strategy_slug}"
}

# Order matters: signal-producing agents first, then synthesis, then executors.
start_strategy market_screener     opportunity_scanner
start_strategy technical_analyst  technical_scanner
start_strategy sentiment_analyst  sentiment_scanner
start_strategy fundamental_analyst fundamental_scanner
start_strategy synthesis_strategist signal_synthesizer
if [ "${PAPER_MODE}" = "true" ]; then
  echo "[bootstrap] PAPER_MODE=true, execution_agent NOT started (dry_run observation only)"
elif [ "${LIVE_TRADING_CONFIRMED}" = "yes" ]; then
  start_strategy execution_agent    trade_executor
else
  echo "[bootstrap] LIVE_TRADING_CONFIRMED is not yes, execution_agent NOT started. Set PAPER_MODE=false and LIVE_TRADING_CONFIRMED=yes only after master approves live."
fi

echo "[bootstrap] all agents requested. Check pipeline health:"
echo "  curl -s -H 'Authorization: Bearer <JWT>' ${BASE_URL}/pipeline/health | jq ."
