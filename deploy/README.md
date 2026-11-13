# VPS Deployment

This bundles the Condor multi-agent trading pipeline (Condor + Hummingbot API +
recovery agents) for self-hosted deployment on a VPS.

## Target

- **Ubuntu 22.04 LTS** on a 6 vCPU / 12 GB RAM / 200 GB SSD VPS
- Lean (no desktop), single non-root user with `sudo`
- Outbound HTTPS to `api.hcnsec.cn` (LLM), `fapi.binance.com` (Binance futures), `api.gate.io` (Gate.io), `api.telegram.org`, `api.tailscale.com`
- Inbound: Tailscale only (no public ports)

## Topology

```
                        ┌──────────────────────────────────────────────┐
                        │           condor-main.service                │
   Tailscale ────►      │  ── FastAPI (8088, JWT)                      │
   only inbound         │  ── Telegram bot (long polling)              │
                        │  ── TickEngine ↔ claude-agent-acp subprocesses │
                        └───────────────┬──────────────────────────────┘
                                        │
                ┌───────────────────────┴────────────────────────────┐
                │                                                    │
        ┌───────▼────────┐                                  ┌────────▼──────────────┐
        │ condor-infra   │  ── Postgres (5432, 127.0.0.1)    │ MCP servers per agent │
        │ .service       │  ── EMQX broker (1883, 127.0.0.1)  │  ── mcp-hummingbot   │
        │                │  ── hummingbot-api container      │  ── mcp-condor       │
        └────────────────┘                                  └───────────────────────┘

   condor-bootstrap-pipeline.service (oneshot)
   ── POSTs /start for each agent once condor-main is healthy
```

## Files

```
deploy/
├── vps/
│   ├── install-condor.sh              ← one-shot bootstrapper (idempotent)
│   ├── uninstall-condor.sh            ← removes service units + containers
│   ├── env.example                    ← template for /etc/condor/secrets.env
│   └── systemd/
│       ├── condor-infra.service       ← postgres + emqx + hummingbot-api
│       ├── condor-main.service        ← FastAPI + Telegram bot
│       ├── condor-bootstrap-pipeline.service  ← POST /start endpoints
│       ├── condor-bootstrap-pipeline.sh
│       ├── condor-restart-agents.sh   ← kills stale ACP/MCP and POSTs /start
│       └── condor-start-hb-api.sh
└── README.md
```

## Quick start

```bash
# On a fresh Ubuntu 22.04 VPS as a sudo user:
sudo apt-get install -y git
git clone https://github.com/NenengR/multi-agent ~/condor-deploy
cd ~/condor-deploy
# (This single repo is the deployment manifest. The subprojects — condor,
#  hummingbot-api — are cloned automatically by install-condor.sh, not as
#  submodules, so a shallow clone is sufficient.)
sudo install -d -m 755 /etc/condor
sudo cp deploy/vps/env.example /etc/condor/secrets.env
sudo chmod 600 /etc/condor/secrets.env
sudo nano /etc/condor/secrets.env  # fill TELEGRAM_TOKEN, *_API_KEY, HCNSEC keys, PAPER_MODE, and separate passwords

cp ~/condor-deploy/config.yml.example /home/condor/condor-deploy/condor/config.yml
# (after the install script creates the condor user)
# Edit /home/condor/condor-deploy/condor/config.yml to set admin_id and web_jwt_secret (openssl rand -base64 32)

sudo bash deploy/vps/install-condor.sh
```

After install you'll see:

```
[✓] infra:   postgres + emqx + hummingbot-api healthy
[✓] condor:  FastAPI + Telegram bot running :8088 (Tailscale only)
[✓] agents:  bootstrap per-agent POST /start cycled
[✓] tailscale:  mesh device IP 100.x.x.x
```

Verify:

```bash
curl -H "Authorization: Bearer $(/home/condor/.local/bin/uv run --directory /home/condor/condor-deploy/condor \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor-deploy/condor'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='${CONDOR_ADMIN_USERNAME:-admin}', role='admin'))")" \
    http://127.0.0.1:8088/api/v1/pipeline/health | jq .
```

## Operation

| Task | Command |
|---|---|
| Service status | `systemctl status condor-infra condor-main condor-bootstrap-pipeline` |
| Restart the daemon (kills all agents) | `sudo systemctl restart condor-main` |
| Restart agents without killing daemon | `sudo /usr/local/bin/condor-restart-agents.sh` |
| Start one specific agent | `curl -X POST -H "Authorization: Bearer $JWT" -d '{}' /api/v1/agents/<slug>/strategies/<sslug>/start` |
| Tail daemon logs | `journalctl -u condor-main -f` |
| Tail infra logs | `journalctl -u condor-infra -f` |
| Container logs | `docker logs hummingbot-api` |
| Pipeline health overview | (see verify command above) |

## Update workflow

```bash
cd ~/condor-deploy
git pull
# Subprojects are pulled separately by operation (only on demand):
(cd condor && git pull)
(cd hummingbot-api && git pull)

# Frontend updated? Rebuild:
(cd condor/frontend && npm install --omit=dev && npm run build)

# Apply Python deps:
(cd condor && uv sync)

# Restart in dependency order:
sudo systemctl restart condor-main
sudo /usr/local/bin/condor-restart-agents.sh
```

## Uninstall

```bash
sudo bash deploy/vps/uninstall-condor.sh
# Removes:  systemd units, docker containers, /opt/condor/compose,
#           hummingbot-api container, build artefacts.
# Keeps:    ~/condor-deploy repo, ~/condor/state, uv install
```

## Failure modes

| Symptom | First check | Fix |
|---|---|---|
| `condor-main` OOM-killed | `journalctl -u condor-main \| grep cgroup_kill` | raise `MemoryMax=` if box has RAM; check for runaway TickEngine session |
| Pipeline health shows `<slug>: stale` | `journalctl -u condor-main --since 30min` | `sudo /usr/local/bin/condor-restart-agents.sh` |
| `Managed-by-port 8088` already bound | `ss -ltnp \| grep 8088` | stop conflicting service or change `WEB_PORT` |
| `MODULE_NOT_FOUND hummingbot` | `uv sync` from `~/condor-deploy/condor` | re-run `uv pip install -e ../hummingbot-api` plus `uv sync` |
| `trading/orders` 500 | `./deploy/vps/systemd/condor-restart-agents.sh` then recheck | known intermittent in `hummingbot-api`; triage `docker logs hummingbot-api` |
| Binance SSL fails (`CERTIFICATE_VERIFY_FAILED`) | `curl -I https://fapi.binance.com/api/v3/exchangeInfo` | check `/etc/hosts` is **clean** (no MITM entries) — VPS should not need overrides |
| Agent ticks show "unknown" / no `meta.yaml` written | check `ANTHROPIC_API_KEY_HCNSEC` + `ANTHROPIC_BASE_URL_HCNSEC` in `/etc/condor/secrets.env` | agents use `claude-code:hcnsec`; empty keys → keyless subprocess that never writes health |
| `uv: command not found` in journal | `which uv` as condor user | ensure `PATH` includes `/home/condor/.local/bin` — systemd unit sets it via `Environment=PATH=...` |

## Notes

- The recovery grid strategy (`execution_agent/b_usdt_recovery_grid`) was deleted
  in 2026-07-23 after a defect that emitted `side=2` when closing LONG rungs.
  See `condor/agents/execution_agent/strategies/_archive_b_usdt_recovery_grid_*`.
- The MCP `manage_executors` tool was patched in 2026-07-22 to coerce
  `side/open_order_type/close_order_type` to ints (see
  `condor/mcp_servers/hummingbot_api/tools/executors.py`).
- **Do not commit `config.yml`, `.env`, or state.** `deploy/vps/env.example`
  and `config.yml.example` are the only templates that ship in-tree.
