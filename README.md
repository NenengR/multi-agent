# Condor — Multi-Agent Trading Pipeline

Autonomous trading system built on [Hummingbot](https://hummingbot.org) and a custom multi-agent orchestration layer (Condor). Runs on a self-hosted VPS, controlled via Telegram and a web dashboard.

## Architecture

```
Market Screener → Technical Analyst → Sentiment Analyst → Fundamental Analyst
                                    ↓
                          Synthesis Strategist
                                    ↓
                           Signal Bus (EMQX)
                                    ↓
                          Execution Agent → Hummingbot API → Gate.io / Binance
```

Each agent is a Claude-powered loop strategy. The Condor web API (FastAPI, JWT) coordinates them. A Telegram bot provides real-time control and alerts.

## Repository layout

```
deploy/          VPS deployment manifests (systemd units, install script)
condor/          Condor orchestration layer (subproject, cloned by installer)
hummingbot-api/  Hummingbot REST API wrapper (subproject, cloned by installer)
config.yml.example  Template — copy to config.yml and fill secrets before running
```

`condor/` and `hummingbot-api/` are excluded from git (see `.gitignore`). The install script clones them from their own repos.

## Quick start (VPS)

See [`deploy/README.md`](deploy/README.md) for the full setup guide.

```bash
# 1. Clone this repo on a fresh Ubuntu 22.04 VPS
git clone <this-repo> ~/condor-deploy && cd ~/condor-deploy

# 2. Fill secrets
sudo cp deploy/vps/env.example /etc/condor/secrets.env
sudo nano /etc/condor/secrets.env

# 3. Copy and edit config
cp config.yml.example config.yml
nano config.yml   # set hummingbot API credentials, Telegram admin_id, JWT secret

# 4. Run installer (idempotent)
sudo bash deploy/vps/install-condor.sh
```

## Requirements

- Ubuntu 22.04 LTS, 6 vCPU / 12 GB RAM / 200 GB SSD
- Tailscale (inbound access — no public ports exposed)
- Anthropic API key, Telegram bot token, exchange API credentials (Gate.io, Binance, etc.)
