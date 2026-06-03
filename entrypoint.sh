#!/usr/bin/env bash
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.6:latest}"
OLLAMA_CLIENT_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
OLLAMA_SERVER_HOST="${OLLAMA_SERVER_HOST:-127.0.0.1:11435}"
KC_LOOPGUARD_LISTEN_PORT="${KC_LOOPGUARD_LISTEN_PORT:-11434}"
KC_LOOPGUARD_UPSTREAM_PORT="${KC_LOOPGUARD_UPSTREAM_PORT:-11435}"
KC_LOOPGUARD_SCRIPT="${KC_LOOPGUARD_SCRIPT:-/opt/kclawbox/runtime/ollama-loop-guard.mjs}"
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

echo "[kclawbox] starting ollama serve (bind ${OLLAMA_SERVER_HOST})"
OLLAMA_HOST="${OLLAMA_SERVER_HOST}" ollama serve > /tmp/ollama-serve.log 2>&1 &
OLLAMA_PID=$!

LOOPGUARD_PID=""
cleanup() {
  if [[ -n "${LOOPGUARD_PID}" ]] && kill -0 "${LOOPGUARD_PID}" >/dev/null 2>&1; then
    kill "${LOOPGUARD_PID}" >/dev/null 2>&1 || true
    wait "${LOOPGUARD_PID}" >/dev/null 2>&1 || true
  fi
  if kill -0 "${OLLAMA_PID}" >/dev/null 2>&1; then
    kill "${OLLAMA_PID}" >/dev/null 2>&1 || true
    wait "${OLLAMA_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Wait for ollama serve to come up on its bind port (do not go through the
# loop-guard proxy yet — it is not running).
for _ in $(seq 1 60); do
  if OLLAMA_HOST="${OLLAMA_SERVER_HOST}" ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! OLLAMA_HOST="${OLLAMA_SERVER_HOST}" ollama list >/dev/null 2>&1; then
  echo "[kclawbox] ollama failed to become ready"
  cat /tmp/ollama-serve.log || true
  exit 1
fi

echo "[kclawbox] ollama is ready"

if [[ -f "${KC_LOOPGUARD_SCRIPT}" ]]; then
  echo "[kclawbox] starting ollama loop guard (proxy ${KC_LOOPGUARD_LISTEN_PORT} -> ${KC_LOOPGUARD_UPSTREAM_PORT})"
  OLLAMA_LOOPGUARD_LISTEN_HOST=0.0.0.0 \
  OLLAMA_LOOPGUARD_LISTEN_PORT="${KC_LOOPGUARD_LISTEN_PORT}" \
  OLLAMA_LOOPGUARD_UPSTREAM_HOST=127.0.0.1 \
  OLLAMA_LOOPGUARD_UPSTREAM_PORT="${KC_LOOPGUARD_UPSTREAM_PORT}" \
  /usr/local/node/bin/node "${KC_LOOPGUARD_SCRIPT}" > /tmp/ollama-loop-guard.log 2>&1 &
  LOOPGUARD_PID=$!

  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${KC_LOOPGUARD_LISTEN_PORT}/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! curl -fsS "http://127.0.0.1:${KC_LOOPGUARD_LISTEN_PORT}/api/tags" >/dev/null 2>&1; then
    echo "[kclawbox] loop guard failed to become ready"
    cat /tmp/ollama-loop-guard.log || true
    exit 1
  fi
  echo "[kclawbox] loop guard is ready"
else
  echo "[kclawbox] loop guard script not present at ${KC_LOOPGUARD_SCRIPT}; clients will hit ollama directly"
fi
echo "[kclawbox] pulling model ${MODEL}"
OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama pull "${MODEL}"

# Local embedding model for built-in memory_search + the L3 memory indexer, so
# neither needs an external embedding API key.
MEMORY_EMBED_MODEL="${KCLAWBOX_MEMORY_EMBED_MODEL:-nomic-embed-text:latest}"
echo "[kclawbox] pulling embedding model ${MEMORY_EMBED_MODEL}"
OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama pull "${MEMORY_EMBED_MODEL}" || echo "[kclawbox] WARN: embed model pull failed; memory_search may degrade to FTS-only"

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

# Pin built-in memory_search to LOCAL Ollama embeddings so it never requires an
# external embedding API key (OpenAI/Gemini/Voyage/Mistral). When memorySearch
# is unset, recent OpenClaw defaults to the openai provider, which the onboard
# wizard can reintroduce on upgrades — re-assert local on every boot.
MEMORY_EMBED_MODEL="${KCLAWBOX_MEMORY_EMBED_MODEL:-nomic-embed-text:latest}"
echo "[kclawbox] pinning memory_search to local ollama embeddings (${MEMORY_EMBED_MODEL})"
"${OPENCLAW_BIN}" config set agents.defaults.memorySearch.provider ollama
"${OPENCLAW_BIN}" config set agents.defaults.memorySearch.model "${MEMORY_EMBED_MODEL}"

# Pin web tools to KEY-FREE providers. The onboard wizard wipes tools.web on
# upgrades; when unset, web_search auto-detects the ollama provider, which needs
# `ollama signin` (ollama.com auth) and fails with "authentication failed".
# DuckDuckGo needs no key/account; web_fetch uses the built-in local HTTP fetch.
"${OPENCLAW_BIN}" config set tools.web.search.enabled true
"${OPENCLAW_BIN}" config set tools.web.fetch.enabled true
# Configure every provider we have credentials/endpoints for, then pick the active one.
# SearXNG (self-hosted metasearch) is a stock provider — key-free and aggregates many
# engines, so a single query already has engine-level resilience.
if [[ -n "${SEARXNG_BASE_URL:-}" ]]; then
  "${OPENCLAW_BIN}" config set plugins.entries.searxng.enabled true
  "${OPENCLAW_BIN}" config set plugins.entries.searxng.config.webSearch.baseUrl "${SEARXNG_BASE_URL}"
fi
# Brave is an external plugin; keep it installed+configured as an option even when not active.
if [[ -n "${BRAVE_API_KEY:-}" ]]; then
  "${OPENCLAW_BIN}" plugins install @openclaw/brave-plugin >/dev/null 2>&1 || echo "[kclawbox] note: brave-plugin already present or install skipped"
  "${OPENCLAW_BIN}" config set plugins.entries.brave.enabled true
  "${OPENCLAW_BIN}" config set plugins.entries.brave.config.webSearch.apiKey "${BRAVE_API_KEY}"
fi
# Active provider precedence: explicit override > SearXNG (key-free) > Brave > DuckDuckGo.
if [[ -n "${KCLAWBOX_WEB_SEARCH_PROVIDER:-}" ]]; then
  WEB_SEARCH_PROVIDER="${KCLAWBOX_WEB_SEARCH_PROVIDER}"
elif [[ -n "${SEARXNG_BASE_URL:-}" ]]; then
  WEB_SEARCH_PROVIDER="searxng"
elif [[ -n "${BRAVE_API_KEY:-}" ]]; then
  WEB_SEARCH_PROVIDER="brave"
else
  WEB_SEARCH_PROVIDER="duckduckgo"
fi
echo "[kclawbox] web_search provider=${WEB_SEARCH_PROVIDER} + local web_fetch"
"${OPENCLAW_BIN}" config set tools.web.search.provider "${WEB_SEARCH_PROVIDER}"

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

# Deterministic raw-conversation capture loop (fox workspace). Runs the capture
# script on an interval WITHOUT spinning an OpenClaw agent/LLM turn — replaces the
# old `raw-data-auto-save` cron job that ran an agentTurn just to invoke a shell
# script (and spammed the chat). Launched only when the workspace provides it.
RAW_CAPTURE_LOOP="${HOME}/memory/scripts/raw-capture-loop.sh"
if [[ -f "${RAW_CAPTURE_LOOP}" ]]; then
  echo "[kclawbox] starting raw-capture loop"
  MEMORY_ROOT="${HOME}/memory" bash "${RAW_CAPTURE_LOOP}" > /tmp/raw-capture-loop.out 2>&1 &
fi

# Operational verifier (HARNESS.md §0 — the harness's "verifier" leg). Reads
# environment state only (files/dbs/cron-state/HTTP probes), never the model, and
# emits ground-truth health. Seed it into the fox's script toolbox and expose a
# `fox-status` command so health comes from data, not the model's self-narration.
VERIFY_SRC="/opt/kclawbox/runtime/verify.mjs"
if [[ -f "${VERIFY_SRC}" ]]; then
  mkdir -p "${HOME}/memory/scripts"
  cp -f "${VERIFY_SRC}" "${HOME}/memory/scripts/verify.mjs" 2>/dev/null || true
  cat > /usr/local/bin/fox-status <<EOF
#!/usr/bin/env bash
exec /usr/local/node/bin/node "${VERIFY_SRC}" "\$@"
EOF
  chmod 755 /usr/local/bin/fox-status
  echo "[kclawbox] installed operational verifier (run: fox-status)"
fi

echo "[kclawbox] starting openclaw gateway"
exec "${OPENCLAW_BIN}" gateway run --allow-unconfigured --bind lan --auth token --token "${OPENCLAW_TOKEN}" --port 18789
