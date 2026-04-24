#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_BIN="/usr/local/node/bin/openclaw"
token="${1:-}"
allow_from="${2:-}"

if [[ -z "${token}" ]]; then
  echo "error: missing telegram bot token" >&2
  exit 1
fi

if [[ -z "${allow_from}" ]]; then
  echo "error: missing telegram user id" >&2
  exit 1
fi

allow_from_json="$(
  TELEGRAM_ALLOW_FROM="${allow_from}" node -e '
    const ids = (process.env.TELEGRAM_ALLOW_FROM || "")
      .split(",")
      .map((v) => v.trim())
      .filter(Boolean);
    process.stdout.write(JSON.stringify(ids));
  '
)"

"${OPENCLAW_BIN}" channels add --channel telegram --token "${token}" --name "Telegram default"
"${OPENCLAW_BIN}" config set channels.telegram.dmPolicy allowlist
"${OPENCLAW_BIN}" config set channels.telegram.allowFrom "${allow_from_json}" --strict-json
"${OPENCLAW_BIN}" channels list --json
