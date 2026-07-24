#!/usr/bin/env bash
# condor-bootstrap-pipeline.sh — once condor-main is healthy, POST /start
# for every agent strategy that should be running on a fresh boot.
# Idempotent: agents already running are skipped (engine.start handles re-activating).
#
# Replaces the per-agent systemd drivel. Each tick is run inside condor-main's
# own process; systemd does not manage individual agents.
set -euo pipefail

. /etc/condor/secrets.env

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
JWT=$(/home/condor/.local/bin/uv run --directory /home/condor/condor-deploy \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor-deploy'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='heliosneo', role='admin'))")

start_strategy() {
    local agent_slug="$1" strategy_slug="$2"
    echo "[bootstrap] starting ${agent_slug}/${strategy_slug} ..."
    curl -sS --max-time 30 -X POST \
        -H "Authorization: Bearer ${JWT}" \
        -H "Content-Type: application/json" \
        -d '{"chat_id":0,"config":{}}' \
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
start_strategy execution_agent    trade_executor

echo "[bootstrap] all agents requested. Check pipeline health:"
echo "  curl -s -H 'Authorization: Bearer <JWT>' ${BASE_URL}/pipeline/health | jq ."
