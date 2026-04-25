#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

container_name="${OPENCLAW_CONTAINER_NAME:-kclawbox}"
ollama_host_port="${OLLAMA_HOST_PORT:-11434}"
openclaw_host_port="${OPENCLAW_HOST_PORT:-18789}"

if ! docker inspect "${container_name}" >/dev/null 2>&1; then
  echo "container: unavailable"
  exit 2
fi

service_state="$(docker inspect --format '{{.State.Status}}' "${container_name}" 2>/dev/null || true)"
service_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container_name}" 2>/dev/null || true)"
openclaw_config="$(docker exec "${container_name}" bash -lc 'test -f /data/home/.openclaw/openclaw.json && echo present || true' 2>/dev/null || true)"
srt_skill="$(docker exec "${container_name}" bash -lc 'test -f /data/openclaw/.openclaw/workspace/skills/srt-reservation/SKILL.md && echo present || true' 2>/dev/null || true)"
agent_browser_skill="$(docker exec "${container_name}" bash -lc 'test -f /data/openclaw/.openclaw/workspace/skills/agent-browser-clawdbot/SKILL.md && echo present || true' 2>/dev/null || true)"
memory_qdrant_skill="$(docker exec "${container_name}" bash -lc 'test -f /data/openclaw/.openclaw/workspace/skills/memory-qdrant/SKILL.md && echo present || true' 2>/dev/null || true)"
agent_browser_cli="$(docker exec "${container_name}" bash -lc 'command -v agent-browser >/dev/null 2>&1 && echo present || true' 2>/dev/null || true)"
openclaw_bin="$(docker exec "${container_name}" bash -lc 'test -x /usr/local/node/bin/openclaw && echo present || true' 2>/dev/null || true)"
telegram_channel="$(docker exec "${container_name}" bash -lc '/usr/local/node/bin/openclaw channels list --json 2>/dev/null | grep -q "\"telegram\"" && echo configured || true' 2>/dev/null || true)"
telegram_allow_from="$(docker exec "${container_name}" bash -lc '/usr/local/node/bin/openclaw config get channels.telegram.allowFrom 2>/dev/null || true' 2>/dev/null || true)"

echo "service_state=${service_state:-unknown}"
if [[ -n "${service_health}" && "${service_health}" != "null" ]]; then
  echo "service_health=${service_health}"
fi
if [[ -n "${openclaw_config}" ]]; then
  echo "openclaw_config=${openclaw_config}"
fi
if [[ -n "${srt_skill}" ]]; then
  echo "srt_skill=${srt_skill}"
fi
if [[ -n "${agent_browser_skill}" ]]; then
  echo "agent_browser_skill=${agent_browser_skill}"
fi
if [[ -n "${memory_qdrant_skill}" ]]; then
  echo "memory_qdrant_skill=${memory_qdrant_skill}"
fi
if [[ -n "${agent_browser_cli}" ]]; then
  echo "agent_browser_cli=${agent_browser_cli}"
fi
if [[ -n "${openclaw_bin}" ]]; then
  echo "openclaw_bin=${openclaw_bin}"
else
  echo "openclaw_bin=not_ready"
fi
if [[ -n "${telegram_channel}" ]]; then
  echo "telegram_channel=${telegram_channel}"
else
  echo "telegram_channel=not_configured"
fi
if [[ -n "${telegram_allow_from}" ]]; then
  echo "telegram_allow_from=${telegram_allow_from}"
fi

api_ok=0
if curl -fsS "http://127.0.0.1:${ollama_host_port}/api/tags" >/tmp/kclawbox-tags.json 2>/dev/null; then
  api_ok=1
  model_names="$(grep -o '"name":"[^"]*"' /tmp/kclawbox-tags.json | sed 's/"name":"//;s/"$//' || true)"
  if [[ -n "${model_names}" ]]; then
    echo "models:"
    printf '%s\n' "${model_names}"
  fi
else
  echo "ollama_api=down"
fi

gateway_ok=0
gateway_code="$(curl -s -o /tmp/kclawbox-gateway.out -w '%{http_code}' "http://127.0.0.1:${openclaw_host_port}/" 2>/dev/null || true)"
if [[ "${gateway_code}" =~ ^(200|302|401|403|404)$ ]]; then
  gateway_ok=1
  echo "gateway_http_code=${gateway_code}"
else
  echo "gateway_http_code=${gateway_code:-unreachable}"
fi

recent_logs="$(docker logs --tail 50 "${container_name}" 2>&1 || true)"
if grep -q "starting openclaw gateway" <<<"${recent_logs}"; then
  echo "gateway_log=seen"
fi
if grep -q "Error: failed to install openclaw" <<<"${recent_logs}"; then
  echo "install_error=present"
fi

if [[ "${service_state}" == "running" && -n "${openclaw_bin}" && "${api_ok}" -eq 1 && "${gateway_ok}" -eq 1 ]]; then
  echo "result=success"
  echo "next=run ./service.sh chat"
  if [[ -z "${telegram_channel}" ]]; then
    echo "next=then type /telegram inside chat"
  else
    echo "next=then send a DM to your Telegram bot"
  fi
  exit 0
fi

echo "result=not_ready"
exit 1
