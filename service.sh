#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage:
  ./service.sh <command> [options]

Commands:
  start      Build and start kclawbox without auto-entering chat
  stop       Stop the running kclawbox container
  restart    Restart the service
  status     Show concise container status
  logs       Show container logs
  chat       Open the interactive CLI chat

Examples:
  ./service.sh start
  ./service.sh stop
  ./service.sh restart
  ./service.sh status
  ./service.sh logs --follow
  ./service.sh chat
EOF
}

read_env_value() {
  local key="$1"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true
  fi
}

container_name="$(read_env_value OPENCLAW_CONTAINER_NAME)"
if [[ -z "${container_name}" ]]; then
  container_name="kclawbox"
fi

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  usage
  exit 1
fi
shift || true

case "${command_name}" in
  start)
    cd "${SCRIPT_DIR}"
    exec ./onboard-kclawbox.sh --no-chat "$@"
    ;;
  stop)
    cd "${SCRIPT_DIR}"
    docker compose stop
    ;;
  restart)
    cd "${SCRIPT_DIR}"
    docker compose stop || true
    exec ./onboard-kclawbox.sh --no-chat "$@"
    ;;
  status)
    cd "${SCRIPT_DIR}"
    if docker inspect -f '{{.Name}}' "${container_name}" >/dev/null 2>&1; then
      docker inspect -f 'container={{.Name}} status={{.State.Status}} started_at={{.State.StartedAt}}' "${container_name}"
      docker compose ps
    else
      echo "container=${container_name} status=not_created"
      exit 1
    fi
    ;;
  logs)
    cd "${SCRIPT_DIR}"
    if [[ $# -eq 0 ]]; then
      docker logs --tail 200 "${container_name}"
    else
      docker logs "$@" "${container_name}"
    fi
    ;;
  chat)
    cd "${SCRIPT_DIR}"
    exec ./chat-kclawbox.sh "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command: ${command_name}" >&2
    usage >&2
    exit 1
    ;;
esac
