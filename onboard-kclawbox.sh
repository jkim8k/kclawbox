#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WORKSPACES_DIR="${SCRIPT_DIR}/workspaces"
MODEL_DEFAULT="qwen3.6:latest"

usage() {
  cat <<'EOF'
Usage:
  ./onboard-kclawbox.sh [options]

Options:
  --workspace-name <name>         Agent/workspace name (English, one word)
  --model <name>                  Ollama model to preload
  --gateway-token <token>         Gateway auth token
  --container-name <name>         Docker container name
  --image-name <name>             Docker image name
  --ollama-port <port>            Host port bound to Ollama
  --openclaw-port <port>          Host port bound to OpenClaw
  --telegram-bot-token <token>    Telegram bot token for auto channel setup
  --telegram-allow-from <ids>     Comma-separated Telegram user ids
  --up                            Start immediately after writing .env (default)
  --no-up                         Write config only, do not start the container
  --no-chat                       Do not jump into CLI chat after onboarding
  --force                         Overwrite existing .env values
  -h, --help                      Show help

Examples:
  ./onboard-kclawbox.sh
  ./onboard-kclawbox.sh --workspace-name gator
  ./onboard-kclawbox.sh \
    --workspace-name gator \
    --telegram-bot-token 123456:ABCDEF \
    --telegram-allow-from <telegram-user-id>
  ./onboard-kclawbox.sh --no-chat
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

wait_for_kclawbox_ready() {
  local container_name="$1"
  local timeout_secs="${2:-1800}"
  local start_ts now_ts elapsed_secs elapsed_display
  local last_status current_status phase detail gateway_code
  start_ts="$(date +%s)"
  last_status=""

  echo "waiting for kclawbox to finish onboarding..."

  while true; do
    if docker exec "${container_name}" bash -lc 'test -x /usr/local/node/bin/openclaw' >/dev/null 2>&1; then
      gateway_code="$(
        docker exec "${container_name}" bash -lc "curl -s -o /tmp/kclawbox-gateway.out -w '%{http_code}' http://127.0.0.1:18789/ 2>/dev/null || true"
      )"
      if [[ "${gateway_code}" =~ ^(200|302|401|403|404)$ ]]; then
        echo "kclawbox ready"
        return 0
      fi
    fi

    current_status="$(
      docker logs --tail 80 "${container_name}" 2>&1 | node -e '
        const fs = require("fs");
        const text = fs.readFileSync(0, "utf8");
        const clean = text
          .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "")
          .replace(/\r/g, "\n");
        const lines = clean.split(/\n+/).map((line) => line.trim()).filter(Boolean);

        const pickLast = (pattern) => {
          for (let i = lines.length - 1; i >= 0; i -= 1) {
            if (pattern.test(lines[i])) {
              return lines[i];
            }
          }
          return "";
        };

        let phase = "preparing container";
        let detail = "starting container";

        if (/\[gateway\] ready|starting channels and sidecars|starting provider/i.test(clean)) {
          phase = "starting gateway";
          detail = pickLast(/\[gateway\] ready|starting channels and sidecars|starting provider|Browser control listening/i) || "gateway startup in progress";
        } else if (/starting openclaw gateway|Starting gateway/i.test(clean)) {
          phase = "starting gateway";
          detail = pickLast(/starting openclaw gateway|Starting gateway|gateway did not start/i) || "starting gateway";
        } else if (/Installing OpenClaw|OpenClaw installed successfully|bootstrapping openclaw|added \d+ packages/i.test(clean)) {
          phase = "installing openclaw";
          detail = pickLast(/Installing OpenClaw|OpenClaw installed successfully|bootstrapping openclaw|added \d+ packages|Setting up OpenClaw with Ollama/i) || "installing OpenClaw";
        } else if (/pulling manifest|pulling [^:]+:|verifying sha256 digest|writing manifest|success/i.test(clean)) {
          phase = "downloading model";
          detail = pickLast(/pulling manifest|pulling [^:]+:|verifying sha256 digest|writing manifest|success/i) || "downloading model";
        } else if (/installing npm deps|installing agent-browser CLI/i.test(clean)) {
          phase = "installing default skills";
          detail = pickLast(/installing npm deps|installing agent-browser CLI|installed workspace skill|installed default skill/i) || "installing bundled skills";
        } else if (/starting ollama serve|ollama is ready/i.test(clean)) {
          phase = "starting ollama";
          detail = pickLast(/starting ollama serve|ollama is ready/i) || "starting Ollama";
        }

        process.stdout.write(JSON.stringify({ phase, detail }));
      '
    )"

    phase="$(STATUS_JSON="${current_status}" node -e 'const data = JSON.parse(process.env.STATUS_JSON || "{}"); process.stdout.write(data.phase || "preparing container");')"
    detail="$(STATUS_JSON="${current_status}" node -e 'const data = JSON.parse(process.env.STATUS_JSON || "{}"); process.stdout.write(data.detail || "starting container");')"

    now_ts="$(date +%s)"
    elapsed_secs=$((now_ts - start_ts))
    elapsed_display="$(
      ELAPSED_SECS="${elapsed_secs}" node -e '
        const secs = Number(process.env.ELAPSED_SECS || "0");
        const mins = Math.floor(secs / 60);
        const rem = secs % 60;
        if (mins > 0) {
          process.stdout.write(`${mins}m ${String(rem).padStart(2, "0")}s`);
        } else {
          process.stdout.write(`${rem}s`);
        }
      '
    )"

    if [[ "${current_status}" != "${last_status}" ]]; then
      printf '\n[%s] %s\n' "${elapsed_display}" "${phase}"
      printf '  %s\n' "${detail}"
      last_status="${current_status}"
    fi

    if (( now_ts - start_ts >= timeout_secs )); then
      echo
      echo "error: kclawbox did not become ready within ${timeout_secs}s" >&2
      echo "tip: docker logs --tail 200 ${container_name}" >&2
      return 1
    fi

    sleep 5
  done
}

read_env_value() {
  local key="$1"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true
  fi
}

random_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

docker_container_exists() {
  local name="$1"
  docker inspect -f '{{.Name}}' "${name}" >/dev/null 2>&1
}

port_is_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{n=split($4, a, ":"); print a[n]}' | grep -Fxq "${port}"
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR > 2 {n=split($4, a, ":"); print a[n]}' | grep -Fxq "${port}"
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  return 1
}

choose_container_name() {
  local preferred="$1"
  local candidate="$preferred"
  local index=2
  while docker_container_exists "${candidate}"; do
    candidate="${preferred}-${index}"
    index=$((index + 1))
  done
  printf '%s\n' "${candidate}"
}

choose_free_port() {
  local preferred="$1"
  local candidate="$preferred"
  while port_is_in_use "${candidate}"; do
    candidate=$((candidate + 10000))
    if (( candidate > 65000 )); then
      die "could not find a free port derived from ${preferred}"
    fi
  done
  printf '%s\n' "${candidate}"
}

default_image_name() {
  local selected_container_name="$1"
  printf '%s\n' "kclawbox:${selected_container_name}"
}

is_valid_workspace_name() {
  [[ "${1:-}" =~ ^[A-Za-z]+$ ]]
}

normalize_workspace_name() {
  printf '%s\n' "${1,,}"
}

prompt_for_workspace_name() {
  local input=""
  while true; do
    printf 'agent english name (one word): '
    IFS= read -r input || exit 1
    input="$(normalize_workspace_name "${input}")"
    if is_valid_workspace_name "${input}"; then
      printf '%s\n' "${input}"
      return 0
    fi
    echo "error: use English letters only, one word, for example: gator" >&2
  done
}

workspace_name=""
model=""
gateway_token=""
telegram_bot_token=""
telegram_allow_from=""
container_name=""
image_name=""
ollama_host_port=""
openclaw_host_port=""
host_ollama_dir=""
host_openclaw_dir=""
host_home_dir=""
run_up="yes"
auto_chat="yes"
force="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-name)
      workspace_name="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --gateway-token)
      gateway_token="${2:-}"
      shift 2
      ;;
    --container-name)
      container_name="${2:-}"
      shift 2
      ;;
    --image-name)
      image_name="${2:-}"
      shift 2
      ;;
    --ollama-port)
      ollama_host_port="${2:-}"
      shift 2
      ;;
    --openclaw-port)
      openclaw_host_port="${2:-}"
      shift 2
      ;;
    --telegram-bot-token)
      telegram_bot_token="${2:-}"
      shift 2
      ;;
    --telegram-allow-from)
      telegram_allow_from="${2:-}"
      shift 2
      ;;
    --up)
      run_up="yes"
      shift
      ;;
    --no-up)
      run_up="no"
      shift
      ;;
    --no-chat)
      auto_chat="no"
      shift
      ;;
    --force)
      force="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -f "${ENV_FILE}" && "${force}" != "yes" ]]; then
  [[ -n "${workspace_name}" ]] || workspace_name="$(read_env_value KCLAWBOX_WORKSPACE_NAME)"
  [[ -n "${model}" ]] || model="$(read_env_value OLLAMA_MODEL)"
  [[ -n "${gateway_token}" ]] || gateway_token="$(read_env_value OPENCLAW_GATEWAY_TOKEN)"
  [[ -n "${telegram_bot_token}" ]] || telegram_bot_token="$(read_env_value TELEGRAM_BOT_TOKEN)"
  [[ -n "${telegram_allow_from}" ]] || telegram_allow_from="$(read_env_value TELEGRAM_ALLOW_FROM)"
  [[ -n "${container_name}" ]] || container_name="$(read_env_value OPENCLAW_CONTAINER_NAME)"
  [[ -n "${image_name}" ]] || image_name="$(read_env_value OPENCLAW_IMAGE_NAME)"
  [[ -n "${ollama_host_port}" ]] || ollama_host_port="$(read_env_value OLLAMA_HOST_PORT)"
  [[ -n "${openclaw_host_port}" ]] || openclaw_host_port="$(read_env_value OPENCLAW_HOST_PORT)"
  [[ -n "${host_ollama_dir}" ]] || host_ollama_dir="$(read_env_value HOST_OLLAMA_DIR)"
  [[ -n "${host_openclaw_dir}" ]] || host_openclaw_dir="$(read_env_value HOST_OPENCLAW_DIR)"
  [[ -n "${host_home_dir}" ]] || host_home_dir="$(read_env_value HOST_HOME_DIR)"
  echo "loading existing ${ENV_FILE}; explicit flags override saved values"
fi

if [[ -n "${workspace_name}" ]]; then
  workspace_name="$(normalize_workspace_name "${workspace_name}")"
fi

if [[ -z "${workspace_name}" ]]; then
  workspace_name="$(prompt_for_workspace_name)"
fi

is_valid_workspace_name "${workspace_name}" || die "invalid --workspace-name: use English letters only, one word"

if [[ -z "${model}" ]]; then
  model="${MODEL_DEFAULT}"
fi

if [[ -z "${gateway_token}" ]]; then
  gateway_token="$(random_token)"
fi

if [[ -z "${container_name}" ]]; then
  container_name="$(choose_container_name "kclawbox-${workspace_name}")"
fi

if [[ -z "${image_name}" ]]; then
  image_name="$(default_image_name "${container_name}")"
fi

if [[ -z "${ollama_host_port}" ]]; then
  ollama_host_port="$(choose_free_port 11434)"
fi

if [[ -z "${openclaw_host_port}" ]]; then
  openclaw_host_port="$(choose_free_port 18789)"
fi

[[ "${ollama_host_port}" =~ ^[0-9]+$ ]] || die "invalid --ollama-port: ${ollama_host_port}"
[[ "${openclaw_host_port}" =~ ^[0-9]+$ ]] || die "invalid --openclaw-port: ${openclaw_host_port}"

if [[ -n "${telegram_bot_token}" && -z "${telegram_allow_from}" ]]; then
  die "--telegram-bot-token requires --telegram-allow-from for a safe default setup"
fi

workspace_rel_dir="./workspaces/${workspace_name}"
workspace_dir="${WORKSPACES_DIR}/${workspace_name}"
if [[ -z "${host_ollama_dir}" ]]; then
  host_ollama_dir="${workspace_rel_dir}/ollama"
fi
if [[ -z "${host_openclaw_dir}" ]]; then
  host_openclaw_dir="${workspace_rel_dir}/openclaw"
fi
if [[ -z "${host_home_dir}" ]]; then
  host_home_dir="${workspace_rel_dir}/home"
fi

mkdir -p \
  "${WORKSPACES_DIR}" \
  "${workspace_dir}/ollama" \
  "${workspace_dir}/openclaw" \
  "${workspace_dir}/home"

printf '%s\n' "${workspace_name}" > "${workspace_dir}/AGENT_NAME.txt"

cat >"${ENV_FILE}" <<EOF
KCLAWBOX_WORKSPACE_NAME=${workspace_name}
KCLAWBOX_AGENT_NAME=${workspace_name}
OLLAMA_MODEL=${model}
OPENCLAW_GATEWAY_TOKEN=${gateway_token}
OPENCLAW_CONTAINER_NAME=${container_name}
OPENCLAW_IMAGE_NAME=${image_name}
OLLAMA_HOST_PORT=${ollama_host_port}
OPENCLAW_HOST_PORT=${openclaw_host_port}
HOST_OLLAMA_DIR=${host_ollama_dir}
HOST_OPENCLAW_DIR=${host_openclaw_dir}
HOST_HOME_DIR=${host_home_dir}
TELEGRAM_BOT_TOKEN=${telegram_bot_token}
TELEGRAM_ALLOW_FROM=${telegram_allow_from}
EOF

echo "wrote ${ENV_FILE}"
echo "KCLAWBOX_WORKSPACE_NAME=${workspace_name}"
echo "OLLAMA_MODEL=${model}"
echo "OPENCLAW_GATEWAY_TOKEN=${gateway_token}"
echo "OPENCLAW_CONTAINER_NAME=${container_name}"
echo "OPENCLAW_IMAGE_NAME=${image_name}"
echo "OLLAMA_HOST_PORT=${ollama_host_port}"
echo "OPENCLAW_HOST_PORT=${openclaw_host_port}"
echo "HOST_OLLAMA_DIR=${host_ollama_dir}"
echo "HOST_OPENCLAW_DIR=${host_openclaw_dir}"
echo "HOST_HOME_DIR=${host_home_dir}"
if [[ -n "${telegram_bot_token}" ]]; then
  echo "TELEGRAM_BOT_TOKEN=configured"
  echo "TELEGRAM_ALLOW_FROM=${telegram_allow_from}"
else
  echo "TELEGRAM_BOT_TOKEN=not_configured"
fi

if [[ "${run_up}" == "yes" ]]; then
  (
    cd "${SCRIPT_DIR}"
    docker compose up --build -d
  )
  wait_for_kclawbox_ready "${container_name}"
  if [[ "${auto_chat}" == "yes" ]]; then
    echo "starting chat..."
    cd "${SCRIPT_DIR}"
    exec ./chat-kclawbox.sh
  fi
  echo "kclawbox is ready"
  echo "next=run ./chat-kclawbox.sh"
else
  echo "next steps:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  ./service.sh start"
fi
