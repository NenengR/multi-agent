#!/usr/bin/env bash
# uninstall-condor.sh — reverse install-condor.sh.
# Stops and disables services, removes docker containers, deletes configs in
# /etc/, but does NOT touch your ~/condor repo or state (so logs / signals /
# agent sessions stay available for inspection).
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }

msg() { echo "[uninstall-condor] $*"; }

msg "stopping and disabling systemd units..."
for unit in condor-main condor-bootstrap-pipeline condor-infra; do
    systemctl stop "${unit}.service" 2>/dev/null || true
    systemctl disable "${unit}.service" 2>/dev/null || true
done

msg "removing systemd unit files..."
rm -f /etc/systemd/system/condor-main.service \
       /etc/systemd/system/condor-bootstrap-pipeline.service \
       /etc/systemd/system/condor-infra.service
systemctl daemon-reload

msg "removing helper scripts..."
rm -f /usr/local/bin/condor-bootstrap-pipeline.sh \
       /usr/local/bin/condor-restart-agents.sh \
       /usr/local/bin/condor-start-hb-api.sh

msg "stopping docker containers (postgres, emqx, hummingbot-api)..."
cd /opt/condor/compose 2>/dev/null && docker compose down -v || true
docker stop hummingbot-api 2>/dev/null || true
docker rm   hummingbot-api 2>/dev/null || true

msg "removing /opt/condor..."
rm -rf /opt/condor

msg "preserving ~/condor repo + state. Verify with: ls ~/condor"
