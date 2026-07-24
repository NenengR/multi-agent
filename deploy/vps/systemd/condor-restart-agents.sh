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
pkill -9 -f "mcp_servers\\\\." 2>/dev/null || true
sleep 2

echo "[restart-agents] re-minting admin JWT..."
JWT=$(/home/condor/.local/bin/uv run --directory /home/condor/condor-deploy \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor-deploy'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='heliosneo', role='admin'))")

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

for entry in "${AGENTS[@]}"; do
  a="${entry%%:*}"
  s="${entry##*:}"
  echo "[restart-agents]   starting ${a}/${s}"
  curl -sS --max-time 30 -X POST \
      -H "Authorization: Bearer ${JWT}" \
      -H "Content-Type: application/json" \
      -d '{"chat_id":0,"config":{}}' \
      "${BASE_URL}/agents/${a}/strategies/${s}/start" \
      | jq -c '"   result: " + (.started|tostring)'
done

echo "[restart-agents] done"
