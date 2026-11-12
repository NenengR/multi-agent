#!/usr/bin/env bash
# Bring up hummingbot-api (a real docker container).
set -euo pipefail
HB_DIR=/home/condor/condor-deploy/hummingbot-api
if ! docker ps --format '{{.Names}}' | grep -q '^hummingbot-api$'; then
    echo "starting hummingbot-api container..."
    docker start hummingbot-api >/dev/null || docker run -d \
        --name hummingbot-api \
        --network host \
        --restart unless-stopped \
        --env-file "${HB_DIR}/.env" \
        -v "${HB_DIR}/credentials:/hummingbot-api/credentials" \
        -v "${HB_DIR}/bots:/hummingbot-api/bots" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /proc:/host/proc:ro \
        -v /etc/hostname:/host/disk-probe:ro \
        -e HOST_PROC=/host/proc \
        -e HOST_DISK_PATH=/host/disk-probe \
        hummingbot-api-local
fi
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/health || echo fail)"
echo "hummingbot-api health: ${code}"
[ "${code}" = "200" ] || { echo "hummingbot-api /health is not 200, check docker logs hummingbot-api" >&2; exit 1; }
