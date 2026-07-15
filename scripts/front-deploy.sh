#!/bin/bash
set -e

INFRA_DIR=~/insighton-infra
LOCK_FILE="$INFRA_DIR/.deploy.lock"

deploy_replica() {
  local name=$1

  echo "----- Deploying $name -----"

  (
    flock -x 200

    cd "$INFRA_DIR"
    docker compose pull "$name"
    docker compose up -d --no-deps "$name"

    echo "Waiting for $name to become healthy..."
    for i in $(seq 1 30); do
      status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
      if [ "$status" = "healthy" ]; then
        echo "$name is healthy (attempt $i)"
        exit 0
      fi
      sleep 2
    done

    echo "$name failed health check!"
    exit 1

  ) 200>"$LOCK_FILE"
}

deploy_replica "insighton-front-1"
deploy_replica "insighton-front-2"

echo "Rolling deployment complete!"