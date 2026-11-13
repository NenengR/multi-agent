# VPS Operations Runbook

Day-to-day operations for the Condor trading pipeline on the VPS.

## Service overview

| Service | What it does |
|---|---|
| `condor-infra` | Postgres + EMQX broker + hummingbot-api container |
| `condor-main` | FastAPI web (8088) + Telegram bot + agent loop |
| `condor-bootstrap-pipeline` | One-shot: POSTs /start for each agent after condor-main is healthy |

All services run as the `condor` user. Inbound access via Tailscale only (no public ports).

---

## Daily checks

```bash
# Service health
systemctl status condor-infra condor-main

# Pipeline agent health (replace TOKEN)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8088/api/v1/pipeline/health | jq .

# Recent signals
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8088/api/v1/pipeline/signals?limit=10" | jq .

# Hummingbot API
curl -s http://127.0.0.1:8000/health | jq .
```

---

## Start / stop / restart

```bash
# Restart everything (infra first, then main)
sudo systemctl restart condor-infra
sudo systemctl restart condor-main

# Restart agents only (kills stale ACP/MCP processes, re-POSTs /start)
sudo /usr/local/bin/condor-restart-agents.sh

# Stop all trading (emergency)
sudo systemctl stop condor-main condor-infra
```

---

## Logs

```bash
# Live condor-main log (Telegram bot + web API + agents)
journalctl -u condor-main -f

# Infra (postgres, broker, hummingbot-api)
journalctl -u condor-infra -f

# Hummingbot API container
docker logs -f hummingbot-api

# Agent-level logs (execution_agent example)
tail -f /home/condor/condor-deploy/condor/agents/execution_agent/store/*/audit.log
```

---

## Secrets rotation

Secrets live in `/etc/condor/secrets.env` (root-owned, chmod 600).

```bash
sudo nano /etc/condor/secrets.env   # edit key(s)
sudo systemctl restart condor-main  # picks up new env
```

Required secrets for agent ticks:
- `ANTHROPIC_API_KEY_HCNSEC` — agents use `agent_key: claude-code:hcnsec`; empty = agents never tick
- `ANTHROPIC_BASE_URL_HCNSEC` — ACP bridge endpoint for the hcnsec provider

JWT secret (web dashboard sessions) lives in `condor/config.yml`:
```bash
sudo -u condor nano /home/condor/condor-deploy/condor/config.yml  # update web_jwt_secret
sudo systemctl restart condor-main
```

---

## Update / redeploy

```bash
cd /home/condor/condor-deploy

# Pull latest deployment manifest
git pull

# Pull latest condor subproject
cd condor && git pull && cd ..

# Rebuild frontend
cd condor/frontend && npm install --omit=dev && npm run build && cd ../..
sudo rm -rf condor/frontend/node_modules

# Sync Python deps
sudo -u condor bash -c '. ~/.local/bin/env && cd /home/condor/condor-deploy/condor && uv sync'

# Restart
sudo systemctl restart condor-infra condor-main
```

---

## Database

```bash
# Connect
docker exec -it $(docker ps -qf name=postgres) psql -U hbot -d hummingbot_api

# Backup
docker exec $(docker ps -qf name=postgres) \
    pg_dump -U hbot hummingbot_api | gzip > ~/backups/hbot-$(date +%Y%m%d).sql.gz

# Restore
gunzip -c ~/backups/hbot-YYYYMMDD.sql.gz | \
    docker exec -i $(docker ps -qf name=postgres) psql -U hbot hummingbot_api
```

---

## Tailscale

```bash
tailscale status          # connected peers
tailscale ip -1           # this machine's Tailscale IP
sudo tailscale up         # reconnect if disconnected
```

---

## Disk / memory

```bash
df -h /                   # disk usage
free -h                   # memory
docker system df          # docker image/volume usage
docker system prune -f    # remove stopped containers + dangling images
```

---

## Emergency: kill all agent processes

```bash
# Kill all claude-agent-acp and MCP server processes
pkill -f "claude-agent-acp" || true
pkill -f "mcp_servers"       || true
sudo systemctl restart condor-main
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Agent ticks show "unknown" / no `meta.yaml` | `ANTHROPIC_API_KEY_HCNSEC` or `ANTHROPIC_BASE_URL_HCNSEC` empty | Fill both in `/etc/condor/secrets.env`, restart condor-main |
| `uv: command not found` in journal | `PATH` missing `/home/condor/.local/bin` | Ensure `condor-main.service` has `Environment=PATH=/home/condor/.local/bin:...` |
| `claude-agent-acp: command not found` | npm global package not installed | `npm install -g @agentclientprotocol/claude-agent-acp` as root |

---

## Reinstall from scratch

```bash
# On a fresh Ubuntu 22.04 VPS:
sudo apt-get install -y git
git clone <repo-url> ~/condor-deploy
cd /home/condor/condor-deploy
sudo mkdir -p /etc/condor
sudo cp deploy/vps/env.example /etc/condor/secrets.env
sudo chmod 600 /etc/condor/secrets.env
sudo nano /etc/condor/secrets.env   # fill all fields
sudo bash deploy/vps/install-condor.sh
```
