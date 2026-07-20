#!/bin/bash
set -e

INFRA_DIR=~/insighton-infra
ENV_FILE="$INFRA_DIR/.env"
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

    cat > "$ENV_FILE" << ENVEOF
CONFIG_REPO_URI=$CONFIG_REPO_URI
CONFIG_REPO_BRANCH=$CONFIG_REPO_BRANCH
CONFIG_SERVER_USERNAME=$CONFIG_SERVER_USERNAME
CONFIG_SERVER_PASSWORD=$CONFIG_SERVER_PASSWORD
DB_URL=$DB_URL
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
REDIS_PASSWORD=$REDIS_PASSWORD
RABBITMQ_HOST=$RABBITMQ_HOST
RABBITMQ_AMQP_PORT=$RABBITMQ_AMQP_PORT
RABBITMQ_USERNAME=$RABBITMQ_USERNAME
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
INFLUXDB_URL=$INFLUXDB_URL
INFLUXDB_ORG=$INFLUXDB_ORG
INFLUXDB_BUCKET=$INFLUXDB_BUCKET
INFLUXDB_TOKEN=$INFLUXDB_TOKEN
ENVEOF

    chmod 600 "$ENV_FILE"

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

deploy_replica "insighton-config"

echo "Rolling deployment complete!"