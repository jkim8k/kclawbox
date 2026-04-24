#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage:
  ./chat-kclawbox.sh [options] [message]

Options:
  --container-name <name>   Docker container name override
  --to <target>             Session target used for the local CLI test
  --json                    Print raw JSON result
  -h, --help                Show help

Examples:
  ./chat-kclawbox.sh
  ./chat-kclawbox.sh "안녕. 지금 준비 상태를 짧게 말해줘."
  ./chat-kclawbox.sh --json "Reply with exactly: CLI_OK"
  ./chat-kclawbox.sh --to +820000000000 "SRT skill이 보이는지 확인해줘."
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

wait_for_chat_ready() {
  local timeout_secs="${1:-900}"
  local start_ts now_ts
  start_ts="$(date +%s)"

  echo "waiting for kclawbox chat backend..."

  while true; do
    if docker exec "${container_name}" bash -lc 'test -x /usr/local/node/bin/openclaw' >/dev/null 2>&1; then
      gateway_code="$(
        docker exec "${container_name}" bash -lc "curl -s -o /tmp/kclawbox-gateway.out -w '%{http_code}' http://127.0.0.1:18789/ 2>/dev/null || true"
      )"
      if [[ "${gateway_code}" =~ ^(200|302|401|403|404)$ ]]; then
        echo "chat backend ready"
        return 0
      fi
    fi

    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout_secs )); then
      echo "error: kclawbox is still not ready after ${timeout_secs}s" >&2
      echo "tip: docker logs --tail 200 ${container_name}" >&2
      return 1
    fi

    sleep 3
  done
}

read_env_value() {
  local key="$1"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true
  fi
}

container_name="$(read_env_value OPENCLAW_CONTAINER_NAME)"
target="+820000000000"
raw_json="no"

if [[ -z "${container_name}" ]]; then
  container_name="kclawbox"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container-name)
      container_name="${2:-}"
      shift 2
      ;;
    --to)
      target="${2:-}"
      shift 2
      ;;
    --json)
      raw_json="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if ! docker inspect -f '{{.Name}}' "${container_name}" >/dev/null 2>&1; then
  die "container not found: ${container_name}"
fi

wait_for_chat_ready

send_message() {
  local message="$1"
  local telegram_configured prompt_message result_json reply_text

  telegram_configured="$(docker exec "${container_name}" bash -lc '/usr/local/node/bin/openclaw channels list --json 2>/dev/null | grep -q "\"telegram\"" && echo yes || true')"
  prompt_message="${message}"

  if [[ "${telegram_configured}" != "yes" ]]; then
    prompt_message="$(
      USER_MESSAGE="${message}" node -e '
        const userMessage = process.env.USER_MESSAGE || "";
        const prefix = [
          "[KCLAWBOX CLI ONBOARDING CONTEXT]",
          "- Telegram is not configured yet.",
          "- Telegram setup must happen inside this conversation, not by telling the user to rerun shell commands with token flags.",
          "- If the user gives a Telegram bot token and Telegram user id, configure Telegram yourself by running ./scripts/setup_telegram.sh \"<token>\" \"<user-id>\" from the workspace.",
          "- If only one value is missing, ask only for the missing value.",
          "- Keep the reply concise and onboarding-focused.",
          "",
          "[USER MESSAGE]",
          userMessage,
        ].join("\n");
        process.stdout.write(prefix);
      '
    )"
  fi

  result_json="$(
    docker exec \
      -e CHAT_TARGET="${target}" \
      -e CHAT_MESSAGE="${prompt_message}" \
      "${container_name}" \
      bash -lc '
        set -euo pipefail
        token="${OPENCLAW_GATEWAY_TOKEN:-}"
        [[ -n "${token}" ]] || { echo "missing OPENCLAW_GATEWAY_TOKEN in container" >&2; exit 1; }
        /usr/local/node/bin/openclaw config set gateway.remote.token "${token}" >/dev/null
        /usr/local/node/bin/openclaw agent --to "${CHAT_TARGET}" --message "${CHAT_MESSAGE}" --json
      '
  )"

  if [[ "${raw_json}" == "yes" ]]; then
    printf '%s\n' "${result_json}"
  else
    reply_text="$(
      RESULT_JSON="${result_json}" node -e '
        const data = JSON.parse(process.env.RESULT_JSON || "{}");
        const payloads = data?.result?.payloads || [];
        const text = payloads
          .map((payload) => payload?.text || "")
          .filter(Boolean)
          .join("\n\n")
          .trim();
        process.stdout.write(text || "");
      '
    )"
    printf '\nassistant> %s\n' "${reply_text}"
  fi

  telegram_configured="$(docker exec "${container_name}" bash -lc '/usr/local/node/bin/openclaw channels list --json 2>/dev/null | grep -q "\"telegram\"" && echo yes || true')"

  echo
  if [[ "${telegram_configured}" == "yes" ]]; then
    echo "telegram_next=send a DM to your configured Telegram bot"
  else
    echo "telegram_next=continue in chat"
    echo "hint=Telegram 연결 도와줘. 내가 토큰 줄게."
  fi
}

message="${*:-}"

if [[ -n "${message}" ]]; then
  send_message "${message}"
  exit 0
fi

echo "kclawbox chat started"
echo "type /exit to quit"
echo "type /telegram to start Telegram onboarding"

while true; do
  printf '\nyou> '
  IFS= read -r line || break

  case "${line}" in
    "")
      continue
      ;;
    /exit|/quit)
      break
      ;;
    /telegram)
      send_message "Telegram 연결 도와줘. 내가 토큰 줄게."
      ;;
    *)
      send_message "${line}"
      ;;
  esac
done
