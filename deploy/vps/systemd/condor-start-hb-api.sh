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
# Fase 1.5: the pinned hummingbot-api (commit 7ae108f, v1.0.1) has NO
# /health route. main.py defines only GET /, which returns
# {"name": "Hummingbot API", "version": ..., "status": "running"}.
# Checking /health always returned 404, so this script exited 1 and
# condor-infra (whose ExecStartPost runs this script) went failed.
# Check the root route instead; a 200 there means uvicorn serves the API.
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/ || echo fail)"
echo "hummingbot-api root: ${code}"
[ "${code}" = "200" ] || { echo "hummingbot-api / is not 200, check docker logs hummingbot-api" >&2; exit 1; }
