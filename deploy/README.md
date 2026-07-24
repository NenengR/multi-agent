# VPS Deployment

This bundles the Condor multi-agent trading pipeline (Condor + Hummingbot API +
recovery agents) for self-hosted deployment on a VPS.

## Target

- **Ubuntu 22.04 LTS** on a 6 vCPU / 12 GB RAM / 200 GB SSD VPS
- Lean (no desktop), single non-root user with `sudo`
- Outbound HTTPS to `api.hcnsec.cn` (LLM), `fapi.binance.com` (now reachable without DNS poison), `api.gate.io`, `api.telegram.org`, `api.tailscale.com`
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
git clone https://github.com/NenengR/condor.git ~/condor
cd ~/condor
git submodule update --init --recursive
cp deploy/vps/env.example /etc/condor/secrets.env
sudo install -m 600 -o root -g root /dev/null /etc/condor/secrets.env  # touch only
sudo bash -c "EDITOR=nano edit /etc/condor/secrets.env"  # fill TELEGRAM_TOKEN, *_API_KEY, etc.

cp /home/$USER/condor/config.yml.example /home/$USER/condor/config.yml
# Edit /home/$USER/condor/config.yml to set admin_id and web_jwt_secret (openssl rand -base64 32)

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
curl -H "Authorization: Bearer $(/home/condor/.local/bin/uv run --directory /home/condor/condor \
    python -c "import sys; sys.path.insert(0, '/home/condor/condor'); from condor.web.auth import create_jwt; print(create_jwt(user_id=${ADMIN_USER_ID}, username='heliosneo', role='admin'))")" \
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
cd ~/condor
git pull --recurse-submodules
git submodule update --init --recursive

# Frontend updated? Rebuild:
cd frontend && npm install --omit=dev && npm run build && cd ..

# Apply Python deps:
uv sync

# Restart in dependency order:
sudo systemctl restart condor-main
sudo /usr/local/bin/condor-restart-agents.sh
```

## Uninstall

```bash
sudo bash deploy/vps/uninstall-condor.sh
# Removes:  systemd units, docker containers, /opt/condor/compose,
#           hummingbot-api container, build artefacts.
# Keeps:    ~/condor repo, ~/condor/state, jq-installed uv
```

## Failure modes

| Symptom | First check | Fix |
|---|---|---|
| `condor-main` OOM-killed | `journalctl -u condor-main \| grep cgroup_kill` | raise `MemoryMax=` if box has RAM; check for runaway TickEngine session |
| Pipeline health shows `<slug>: stale` | `journalctl -u condor-main --since 30min` | `sudo /usr/local/bin/condor-restart-agents.sh` |
| `Managed-by-port 8088` already bound | `ss -ltnp \| grep 8088` | stop conflicting service or change `WEB_PORT` |
| `MODULE_NOT_FOUND hummingbot` | `uv sync` from `~/condor/condor` | re-run `uv pip install -e ../hummingbot-api` plus `uv sync` |
| `trading/orders` 500 | `./deploy/vps/systemd/condor-restart-agents.sh` then recheck | known intermittent in `hummingbot-api`; triage `docker logs hummingbot-api` |
| Binance SSL fails (`CERTIFICATE_VERIFY_FAILED`) | `curl -I https://fapi.binance.com/api/v3/exchangeInfo` | check `/etc/hosts` is **clean** (no MITM entries) — VPS should not need overrides |

## Notes

- The recovery grid strategy (`execution_agent/b_usdt_recovery_grid`) was deleted
  in 2026-07-23 after a defect that emitted `side=2` when closing LONG rungs.
  See `condor/agents/execution_agent/strategies/_archive_b_usdt_recovery_grid_*`.
- The MCP `manage_executors` tool was patched in 2026-07-22 to coerce
  `side/open_order_type/close_order_type` to ints (see
  `condor/mcp_servers/hummingbot_api/tools/executors.py`).
- **Do not commit `config.yml`, `.env`, or state.** `deploy/vps/env.example`
  and `config.yml.example` are the only templates that ship in-tree.
