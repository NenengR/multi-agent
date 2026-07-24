#!/usr/bin/env bash
# Bring up hummingbot-api (a real docker container).
set -euo pipefail
if ! docker ps --format '{{.Names}}' | grep -q '^hummingbot-api$'; then
    echo "starting hummingbot-api container..."
    docker start hummingbot-api >/dev/null || docker run -d \
        --name hummingbot-api \
        --network host \
        --restart unless-stopped \
        --env-file /home/condor/hummingbot-api/.env \
        hummingbot-api-local
fi
echo "hummingbot-api reachable: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/ || echo fail)"
