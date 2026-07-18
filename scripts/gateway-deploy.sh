#!/bin/bash
set -e

INFRA_DIR=~/insighton-infra
LOCK_FILE="$INFRA_DIR/.deploy.lock"

wait_healthy() {
  local name=$1
  for i in $(seq 1 30); do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
      echo "$name is healthy (attempt $i)"
      return 0
    fi
    sleep 2
  done
  return 1
}

deploy_replica() {
  local name=$1

  echo "----- Deploying $name -----"

  (
    flock -x 200

    cd "$INFRA_DIR"

    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$name" 2>/dev/null || echo "")

    docker compose pull "$name"
    docker compose up -d --no-deps "$name"

    echo "Waiting for $name to become healthy..."
    if wait_healthy "$name"; then
      exit 0
    fi

    echo "$name failed health check!"

    if [ -z "$OLD_IMAGE_ID" ]; then
      echo "No previous image record found, rollback not possible (presumed to be the initial deployment). Deployment failed and terminated."
      exit 1
    fi

    echo "----- Rolling back $name to previous image -----"
    IMAGE_NAME=$(docker compose config --images "$name")
    docker tag "$OLD_IMAGE_ID" "$IMAGE_NAME"
    docker compose up -d --no-deps "$name"

    if wait_healthy "$name"; then
      echo "$name rollback succeeded"
      exit 1
    fi

    echo "$name rollback also failed! Manual verification required"
    exit 1

  ) 200>"$LOCK_FILE"
}

deploy_replica "insighton-gateway-1"
deploy_replica "insighton-gateway-2"

echo "Rolling deployment complete!"