#!/usr/bin/env bash
# condor-restart-agents.sh — kills any leftover claude-agent-acp / MCP subprocesses
# and restarts agent engines via the API. Use when agents appear stale without
# restarting all of condor-main.
#
# Usage: sudo bash /usr/local/bin/condor-restart-agents.sh
set -euo pipefail

. /etc/condor/secrets.env
BASE_URL="http://localhost:${WEB_PORT:-8088}/api/v1"

echo "[restart-agents] reaping orphan ACP/MCP subprocesses..."
pkill -9 -f "claude-agent-acp" 2>/dev/null || true
pkill -9 -f "mcp_servers" 2>/dev/null || true
sleep 2

echo "[restart-agents] re-minting admin JWT..."
JWT=$(/home/condor/.local/bin/uv run --directory /home/condor/condor-deploy/condor \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor-deploy/condor'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='${CONDOR_ADMIN_USERNAME:-admin}', role='admin'))")

# Stop (if running) and start each known strategy.
AGENTS=(
  "market_screener:opportunity_scanner"
  "technical_analyst:technical_scanner"
  "sentiment_analyst:sentiment_scanner"
  "fundamental_analyst:fundamental_scanner"
  "synthesis_strategist:signal_synthesizer"
  "execution_agent:trade_executor"
)

for entry in "${AGENTS[@]}"; do
  a="${entry%%:*}"
  s="${entry##*:}"
  curl -sS --max-time 5 -X POST -H "Authorization: Bearer ${JWT}" \
      "${BASE_URL}/agents/${a}/strategies/${s}/stop" >/dev/null || true
done
sleep 2

PAPER_MODE="${PAPER_MODE:-true}"
LIVE_TRADING_CONFIRMED="${LIVE_TRADING_CONFIRMED:-no}"
if [ "${PAPER_MODE}" = "true" ]; then
  EXEC_MODE="dry_run"
  echo "[restart-agents] PAPER_MODE=true, execution_agent will NOT be restarted (dry_run observation only)"
elif [ "${LIVE_TRADING_CONFIRMED}" = "yes" ]; then
  EXEC_MODE="loop"
else
  EXEC_MODE="dry_run"
  echo "[restart-agents] LIVE_TRADING_CONFIRMED is not yes, restarting in dry_run and skipping execution_agent"
fi
for entry in "${AGENTS[@]}"; do
  a="${entry%%:*}"
  s="${entry##*:}"
  if [ "${a}" = "execution_agent" ] && { [ "${PAPER_MODE}" = "true" ] || [ "${LIVE_TRADING_CONFIRMED}" != "yes" ]; }; then
    echo "[restart-agents]   skipping ${a}/${s} in paper mode"
    continue
  fi
  echo "[restart-agents]   starting ${a}/${s}"
  curl -sS --max-time 30 -X POST \
      -H "Authorization: Bearer ${JWT}" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":0,\"config\":{\"execution_mode\":\"${EXEC_MODE}\"}}" \
      "${BASE_URL}/agents/${a}/strategies/${s}/start" \
      | jq -c '"   result: " + (.started|tostring)' \
      || echo "[restart-agents]   failed to start ${a}/${s}"
done

echo "[restart-agents] done"
