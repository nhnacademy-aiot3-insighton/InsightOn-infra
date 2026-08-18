#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 077

INFRA_DIR=~/insighton-infra
ENV_FILE="$INFRA_DIR/.env"
LOCK_FILE="$INFRA_DIR/.deploy.lock"
LOCK_TIMEOUT=60
HEALTH_MAX_ATTEMPTS=30
HEALTH_INTERVAL=2

# MARK: Per-service env var manifest

declare -A SERVICE_ENV_VARS=(
  [ai]="CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD REDIS_PASSWORD GEMINI_API_KEY DB_PASSWORD RABBITMQ_PASSWORD INFLUXDB_TOKEN"
  [auth]="CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD DB_PASSWORD REDIS_PASSWORD JWT_PRIVATE_KEY JWT_PUBLIC_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET BREVO_SMTP_LOGIN BREVO_SMTP_KEY"
  [core]="CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD DB_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD INFLUXDB_TOKEN KMA_KEY AIR_KEY"
  [gateway]="CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD REDIS_PASSWORD JWT_PUBLIC_KEY"
  [ruleengine]="CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD DB_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD"
  [config]="CONFIG_GITHUB_USERNAME CONFIG_GITHUB_TOKEN CONFIG_REPO_URI CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD"
  [eureka]=""
  [front]=""
)

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# MARK: Argument parsing

if [[ $# -lt 2 ]]; then
  err "Usage: $0 <service-key> <replica-name-1> [replica-name-2 ...]"
  err "Known service keys: ${!SERVICE_ENV_VARS[*]}"
  exit 1
fi

SERVICE_KEY=$1
shift
REPLICAS=("$@")

if [[ -z "${SERVICE_ENV_VARS[$SERVICE_KEY]+set}" ]]; then
  err "Unknown service key: '$SERVICE_KEY'"
  err "Known service keys: ${!SERVICE_ENV_VARS[*]}"
  exit 1
fi

IFS=' ' read -ra REQUIRED_VARS <<< "${SERVICE_ENV_VARS[$SERVICE_KEY]}"

# MARK: Pre-flight checks

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"
    exit 1
  fi
}

require_cmd docker
require_cmd flock

if ! docker compose version >/dev/null 2>&1; then
  err "'docker compose' plugin is not available."
  exit 1
fi

missing_vars=()
for var_name in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    missing_vars+=("$var_name")
  fi
done
if [[ ${#missing_vars[@]} -gt 0 ]]; then
  err "Missing required environment variables for service '$SERVICE_KEY': ${missing_vars[*]}"
  exit 1
fi

if [[ ! -d "$INFRA_DIR" ]]; then
  err "Directory not found: $INFRA_DIR"
  exit 1
fi

if [[ ! -w "$INFRA_DIR" ]]; then
  err "Directory is not writable: $INFRA_DIR"
  exit 1
fi

if [[ ! -f "$INFRA_DIR/docker-compose.yml" && ! -f "$INFRA_DIR/compose.yaml" ]]; then
  err "No docker-compose.yml / compose.yaml found in $INFRA_DIR"
  exit 1
fi

if [[ ${#REPLICAS[@]} -eq 0 ]]; then
  err "No replica names given. Nothing to deploy."
  exit 1
fi

if (( EUID == 0 )); then
  log "WARNING: running as root. Consider running this script as a non-root user with docker group access."
fi

# MARK: Health check

wait_healthy() {
  local name=$1
  local status

  local stable_required=5
  local stable_count=0

  for ((i = 1; i <= HEALTH_MAX_ATTEMPTS; i++)); do
    status=$(docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$name" 2>/dev/null || echo "not-found")

    case "$status" in
      healthy)
        log "  OK: $name is healthy (attempt $i/$HEALTH_MAX_ATTEMPTS)"
        return 0
        ;;
      no-healthcheck)
        if [[ "$(docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
          ((stable_count++))
          log "  WAIT: $name has no healthcheck defined, running $stable_count/$stable_required consecutive checks (attempt $i/$HEALTH_MAX_ATTEMPTS)"
          if (( stable_count >= stable_required )); then
            log "  OK: $name has no healthcheck defined, but has stayed running for $stable_count consecutive checks (attempt $i)"
            return 0
          fi
        else
          stable_count=0
          log "  WAIT: $name has no healthcheck defined and is not running (attempt $i/$HEALTH_MAX_ATTEMPTS)"
        fi
        ;;
      unhealthy)
        stable_count=0
        log "  WAIT: $name reported unhealthy (attempt $i/$HEALTH_MAX_ATTEMPTS)"
        ;;
      not-found)
        stable_count=0
        log "  WAIT: $name not found yet (attempt $i/$HEALTH_MAX_ATTEMPTS)"
        ;;
      *)
        stable_count=0
        log "  WAIT: $name status: $status (attempt $i/$HEALTH_MAX_ATTEMPTS)"
        ;;
    esac

    sleep "$HEALTH_INTERVAL"
  done

  return 1
}

# MARK: Diagnostics on failure (secrets-safe)

dump_diagnostics() {
  local name=$1
  log "----- Diagnostics for $name -----"
  docker logs --tail=50 "$name" 2>&1 || true
  docker inspect --format='{{json .State}}' "$name" 2>&1 || true
  log "----------------------------------"
}

# MARK: Deploy a single replica

deploy_replica() {
  local name=$1

  if [[ -z "$name" ]]; then
    err "deploy_replica called with an empty name."
    return 1
  fi

  log "===== Deploying $name (service: $SERVICE_KEY) ====="

  (
    if ! flock -w "$LOCK_TIMEOUT" -x 200; then
      err "Could not acquire deploy lock within ${LOCK_TIMEOUT}s. Another deployment may be in progress."
      exit 1
    fi

    if [[ ${#REQUIRED_VARS[@]} -gt 0 ]]; then
      local tmp_env
      tmp_env=$(mktemp "$INFRA_DIR/.env.tmp.XXXXXX")
      {
        for var_name in "${REQUIRED_VARS[@]}"; do
          printf '%s=%s\n' "$var_name" "${!var_name}"
        done
      } > "$tmp_env"
      chmod 600 "$tmp_env"
      mv -f "$tmp_env" "$ENV_FILE"
    fi

    cd "$INFRA_DIR"

    if ! docker compose config -q; then
      err "docker-compose.yml failed validation. Aborting before touching containers."
      exit 1
    fi

    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$name" 2>/dev/null || echo "")
    OLD_IMAGE_NAME=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null || echo "")

    deploy_ok=true

    if ! docker compose pull "$name"; then
      log "  FAIL: pull failed for $name"
      deploy_ok=false
    fi

    if $deploy_ok && ! docker compose up -d --no-deps "$name"; then
      log "  FAIL: up -d failed for $name"
      deploy_ok=false
    fi

    if $deploy_ok && wait_healthy "$name"; then
      log "  SUCCESS: $name deployed successfully"
      exit 0
    fi

    log "  FAIL: $name deployment failed (command failure or health check timeout)"
    dump_diagnostics "$name"

    if [[ -z "$OLD_IMAGE_ID" ]]; then
      log "  No previous image recorded, rollback not possible (assumed initial deployment). Deployment failed."
      exit 1
    fi

    log "----- Rolling back $name to previous image -----"

    if [[ -z "$OLD_IMAGE_NAME" ]]; then
      err "Could not resolve image name for $name; rollback aborted. Manual intervention required."
      exit 1
    fi

    if ! docker tag "$OLD_IMAGE_ID" "$OLD_IMAGE_NAME"; then
      err "docker tag failed while attempting rollback for $name. Manual intervention required."
      exit 1
    fi

    if ! docker compose up -d --no-deps "$name"; then
      err "Rollback restart itself failed for $name. Manual intervention required."
      exit 1
    fi

    if wait_healthy "$name"; then
      log "  ROLLBACK OK: $name rolled back successfully (original deploy still counts as failed)"
      exit 1
    fi

    err "Rollback also failed for $name! Manual intervention required."
    dump_diagnostics "$name"
    exit 1

  ) 200>"$LOCK_FILE"
}

# MARK: Main

failed_replicas=()

for name in "${REPLICAS[@]}"; do
  if ! deploy_replica "$name"; then
    failed_replicas+=("$name")
    err "$name failed to deploy. Stopping rolling deployment."
    break
  fi
done

if [[ ${#failed_replicas[@]} -gt 0 ]]; then
  err "Deployment failed: ${failed_replicas[*]}"
  exit 1
fi

log "===== Rolling deployment complete! ====="