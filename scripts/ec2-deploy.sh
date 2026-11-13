#!/usr/bin/env bash
# ec2-deploy.sh - installed on the EC2 host by Terraform user data as /usr/local/bin/devops-task-deploy.
# Invoked by GitHub Actions through AWS SSM Run Command:
#
#   devops-task-deploy ghcr.io/<owner>/devops-task:sha-abc1234
#
# Steps: pull new image -> replace container -> smoke test /health ->
#        on failure, automatically restart the previously running image and exit 1.

set -euo pipefail

readonly NAME="devops-task"
readonly STATE_DIR="/opt/devops-task"
readonly CURRENT_FILE="${STATE_DIR}/current_image"
readonly CONF_FILE="${STATE_DIR}/deploy.conf" # written by user data: AWS_REGION, LOG_GROUP, HOST_PORT, APP_ENV
readonly SMOKE_RETRIES=20
readonly SMOKE_INTERVAL=3

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[[ $# -eq 1 ]] || { echo "usage: $0 <image-ref>" >&2; exit 2; }
NEW_IMAGE=$1

# shellcheck source=/dev/null
source "$CONF_FILE"
: "${AWS_REGION:?missing in ${CONF_FILE}}" "${LOG_GROUP:?missing in ${CONF_FILE}}"
HOST_PORT=${HOST_PORT:-80}
APP_ENV=${APP_ENV:-production}

run_container() {
  local image=$1
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    --restart unless-stopped \
    -p "${HOST_PORT}:8080" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 256m --cpus 0.5 \
    --stop-timeout 30 \
    -e APP_ENV="$APP_ENV" -e LOG_LEVEL=INFO \
    --log-driver awslogs \
    --log-opt awslogs-region="$AWS_REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt awslogs-stream="${NAME}-$(hostname)" \
    "$image" >/dev/null
}

smoke_test() {
  local i
  for ((i = 1; i <= SMOKE_RETRIES; i++)); do
    if curl -fsS -m 3 "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
      log "smoke test passed (attempt ${i})"
      return 0
    fi
    sleep "$SMOKE_INTERVAL"
  done
  log "smoke test FAILED after ${SMOKE_RETRIES} attempts"
  return 1
}

PREVIOUS_IMAGE=""
[[ -f "$CURRENT_FILE" ]] && PREVIOUS_IMAGE=$(<"$CURRENT_FILE")
log "current: ${PREVIOUS_IMAGE:-<none>}  new: ${NEW_IMAGE}"

docker pull --quiet "$NEW_IMAGE"
run_container "$NEW_IMAGE"

if smoke_test; then
  printf '%s\n' "$NEW_IMAGE" >"$CURRENT_FILE"
  docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
  log "deployed ${NEW_IMAGE}"
  exit 0
fi

docker logs --tail 50 "$NAME" 2>&1 || true
if [[ -n "$PREVIOUS_IMAGE" && "$PREVIOUS_IMAGE" != "$NEW_IMAGE" ]]; then
  log "rolling back to ${PREVIOUS_IMAGE}"
  run_container "$PREVIOUS_IMAGE"
  if smoke_test; then
    log "rollback succeeded"
  else
    log "rollback ALSO failed - manual intervention required"
  fi
else
  log "no previous image to roll back to"
fi
exit 1
