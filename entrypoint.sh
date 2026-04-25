#!/usr/bin/env bash
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.6:latest}"
OLLAMA_CLIENT_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
OLLAMA_SERVER_HOST="${OLLAMA_SERVER_HOST:-0.0.0.0:11434}"
OPENCLAW_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-openclaw-local-token}"
AGENT_ENGLISH_NAME="${KCLAWBOX_AGENT_NAME:-}"
WORKSPACE_NAME="${KCLAWBOX_WORKSPACE_NAME:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOW_FROM="${TELEGRAM_ALLOW_FROM:-}"
OPENCLAW_BIN="/usr/local/node/bin/openclaw"
OPENCLAW_RUNTIME_DIR="${OPENCLAW_HOME}/.openclaw"
OPENCLAW_JSON="${OPENCLAW_RUNTIME_DIR}/openclaw.json"
OPENCLAW_RUNTIME_WORKSPACE_DIR="${OPENCLAW_RUNTIME_DIR}/workspace"
OPENCLAW_RUNTIME_SKILLS_DIR="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/skills"
OPENCLAW_RUNTIME_CLAWHUB_DIR="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/.clawhub"
DEFAULT_OPENCLAW_SKILLS_DIR="${KC_DEFAULT_OPENCLAW_SKILLS_DIR:-/opt/kclawbox/default-openclaw-skills}"
DEFAULT_OPENCLAW_WORKSPACE_DIR="${KC_DEFAULT_OPENCLAW_WORKSPACE_DIR:-/opt/kclawbox/default-openclaw-workspace}"
KCLAWBOX_WORKSPACE_MARKER="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/.kclawbox-defaults-installed"
KCLAWBOX_AGENT_MARKER="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/.kclawbox-agent-name-set"

mkdir -p "${HOME}" "${OLLAMA_MODELS}" "${OPENCLAW_CONFIG_DIR}" "${OPENCLAW_WORKSPACE_DIR}"

mkdir -p "${OPENCLAW_RUNTIME_SKILLS_DIR}" "${OPENCLAW_RUNTIME_CLAWHUB_DIR}"

if [[ -f "${DEFAULT_OPENCLAW_WORKSPACE_DIR}/.clawhub/lock.json" ]] && [[ ! -f "${OPENCLAW_RUNTIME_CLAWHUB_DIR}/lock.json" ]]; then
  cp "${DEFAULT_OPENCLAW_WORKSPACE_DIR}/.clawhub/lock.json" "${OPENCLAW_RUNTIME_CLAWHUB_DIR}/lock.json"
  echo "[kclawbox] installed default clawhub lock"
fi

if [[ -d "${DEFAULT_OPENCLAW_SKILLS_DIR}" ]]; then
  echo "[kclawbox] installing bundled OpenClaw workspace skills"
  for skill_dir in "${DEFAULT_OPENCLAW_SKILLS_DIR}"/*; do
    [[ -d "${skill_dir}" ]] || continue
    skill_name="$(basename "${skill_dir}")"
    if [[ ! -e "${OPENCLAW_RUNTIME_SKILLS_DIR}/${skill_name}" ]]; then
      cp -a "${skill_dir}" "${OPENCLAW_RUNTIME_SKILLS_DIR}/${skill_name}"
      echo "[kclawbox] installed workspace skill ${skill_name}"
    fi
  done
fi

ensure_npm_deps() {
  local skill_dir="$1"
  if [[ -f "${skill_dir}/package.json" && ! -d "${skill_dir}/node_modules" ]]; then
    echo "[kclawbox] installing npm deps for $(basename "${skill_dir}")"
    (cd "${skill_dir}" && npm install --omit=dev)
  fi
}

ensure_npm_deps "${OPENCLAW_RUNTIME_SKILLS_DIR}/memory-qdrant"
ensure_npm_deps "${OPENCLAW_RUNTIME_SKILLS_DIR}/elite-longterm-memory-local"

if ! command -v agent-browser >/dev/null 2>&1; then
  echo "[kclawbox] installing agent-browser CLI"
  npm install -g agent-browser
fi

if ! command -v agent-browser >/dev/null 2>&1; then
  echo "[kclawbox] agent-browser installation failed"
  exit 1
fi

git config --global url."https://github.com/".insteadOf ssh://git@github.com/
git config --global url."https://github.com/".insteadOf git@github.com:

echo "[kclawbox] starting ollama serve"
OLLAMA_HOST="${OLLAMA_SERVER_HOST}" ollama serve > /tmp/ollama-serve.log 2>&1 &
OLLAMA_PID=$!

cleanup() {
  if kill -0 "${OLLAMA_PID}" >/dev/null 2>&1; then
    kill "${OLLAMA_PID}" >/dev/null 2>&1 || true
    wait "${OLLAMA_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  if OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama list >/dev/null 2>&1; then
  echo "[kclawbox] ollama failed to become ready"
  cat /tmp/ollama-serve.log || true
  exit 1
fi

echo "[kclawbox] ollama is ready"
echo "[kclawbox] pulling model ${MODEL}"
OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama pull "${MODEL}"

if [ ! -x "${OPENCLAW_BIN}" ] || [ ! -f "${OPENCLAW_JSON}" ]; then
  echo "[kclawbox] bootstrapping openclaw via ollama launch"
  set +e
  env OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_TOKEN}" OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama launch openclaw --model "${MODEL}" --yes
  launch_status=$?
  set -e
  echo "[kclawbox] ollama launch exit=${launch_status}"
fi

if [ ! -x "${OPENCLAW_BIN}" ] || [ ! -f "${OPENCLAW_JSON}" ]; then
  echo "[kclawbox] openclaw bootstrap incomplete"
  exit 1
fi

if [[ -d "${DEFAULT_OPENCLAW_WORKSPACE_DIR}" && ! -f "${KCLAWBOX_WORKSPACE_MARKER}" ]]; then
  echo "[kclawbox] seeding default OpenClaw workspace files"
  cp -af "${DEFAULT_OPENCLAW_WORKSPACE_DIR}/." "${OPENCLAW_RUNTIME_WORKSPACE_DIR}/"
  if [[ -f "${OPENCLAW_RUNTIME_WORKSPACE_DIR}/scripts/setup_telegram.sh" ]]; then
    chmod 755 "${OPENCLAW_RUNTIME_WORKSPACE_DIR}/scripts/setup_telegram.sh"
  fi
  touch "${KCLAWBOX_WORKSPACE_MARKER}"
fi

if [[ -n "${AGENT_ENGLISH_NAME}" && ! -f "${KCLAWBOX_AGENT_MARKER}" && -f "${OPENCLAW_RUNTIME_WORKSPACE_DIR}/IDENTITY.md" ]]; then
  echo "[kclawbox] setting agent name to ${AGENT_ENGLISH_NAME}"
  AGENT_ENGLISH_NAME="${AGENT_ENGLISH_NAME}" \
  WORKSPACE_NAME="${WORKSPACE_NAME}" \
  IDENTITY_PATH="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/IDENTITY.md" \
  PROFILE_PATH="${OPENCLAW_RUNTIME_WORKSPACE_DIR}/KCLAWBOX_PROFILE.txt" \
  node - <<'EOF'
const fs = require("fs");
const path = process.env.IDENTITY_PATH;
const agentName = process.env.AGENT_ENGLISH_NAME || "";
const workspaceName = process.env.WORKSPACE_NAME || "";
if (!path || !agentName) process.exit(0);
let text = fs.readFileSync(path, "utf8");
text = text.replace(/- \*\*Name:\*\*(?:.*\n)?(?:  _\(pick something you like\)_\n)?/m, `- **Name:** ${agentName}\n`);
fs.writeFileSync(path, text);
const profilePath = process.env.PROFILE_PATH;
if (profilePath) {
  fs.writeFileSync(profilePath, `agent_name=${agentName}\nworkspace_name=${workspaceName}\n`);
}
EOF
  touch "${KCLAWBOX_AGENT_MARKER}"
fi

echo "[kclawbox] configuring openclaw gateway"
"${OPENCLAW_BIN}" config set gateway.mode local
"${OPENCLAW_BIN}" config set gateway.bind lan
"${OPENCLAW_BIN}" config set gateway.auth.mode token
"${OPENCLAW_BIN}" config set gateway.auth.token "${OPENCLAW_TOKEN}"

if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo "[kclawbox] configuring telegram channel"
  "${OPENCLAW_BIN}" channels add --channel telegram --token "${TELEGRAM_BOT_TOKEN}" --name "Telegram default"
  if [[ -n "${TELEGRAM_ALLOW_FROM}" ]]; then
    allow_from_json="$(
      TELEGRAM_ALLOW_FROM="${TELEGRAM_ALLOW_FROM}" node -e '
        const ids = (process.env.TELEGRAM_ALLOW_FROM || "")
          .split(",")
          .map((v) => v.trim())
          .filter(Boolean);
        process.stdout.write(JSON.stringify(ids));
      '
    )"
    "${OPENCLAW_BIN}" config set channels.telegram.dmPolicy allowlist
    "${OPENCLAW_BIN}" config set channels.telegram.allowFrom "${allow_from_json}" --strict-json
  fi
fi

if "${OPENCLAW_BIN}" channels list --json 2>/dev/null | grep -q '"telegram"'; then
  rm -f "${OPENCLAW_RUNTIME_WORKSPACE_DIR}/BOOTSTRAP.md"
fi

echo "[kclawbox] starting openclaw gateway"
exec "${OPENCLAW_BIN}" gateway run --allow-unconfigured --bind lan --auth token --token "${OPENCLAW_TOKEN}" --port 18789
