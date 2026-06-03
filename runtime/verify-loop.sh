#!/usr/bin/env bash
# verify-loop.sh — periodic deterministic harness health check + Telegram alert.
#
# Runs the operational verifier (verify.mjs) on an interval and, on a transition
# into FAIL (or every 6h while still failing, or on recovery), alerts JK. There
# is NO model involvement: the alert is sent straight to the Telegram Bot API, so
# it still works when the gateway / agent itself is down (a gateway outage is
# exactly one of the FAIL conditions). See docs/HARNESS.md §0 (verifier leg).
set -uo pipefail

HOME="${HOME:-/data/home}"
export MEMORY_ROOT="${MEMORY_ROOT:-$HOME/memory}"
INTERVAL="${VERIFY_INTERVAL:-900}"        # 15 min
WARMUP="${VERIFY_WARMUP:-120}"            # let the gateway finish booting first
REMIND_SECS="${VERIFY_REMIND_SECS:-21600}" # re-remind every 6h while still FAIL
VERIFY="${HOME}/memory/scripts/verify.mjs"
[ -f "$VERIFY" ] || VERIFY="/opt/kclawbox/runtime/verify.mjs"
NODE="/usr/local/node/bin/node"
LOG="${MEMORY_ROOT}/logs/verify-loop.log"
STATEF="/tmp/verify-loop.state"           # "<overall> <lastAlertEpoch>"
PIDFILE="/tmp/verify-loop.pid"
CFG="${OPENCLAW_HOME:-/data/openclaw}/.openclaw/openclaw.json"
mkdir -p "$(dirname "$LOG")"

# Telegram creds — deterministic, no model. Prefer env, fall back to config.
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${KCLAWBOX_ALERT_CHATID:-}"
[ -z "$TG_TOKEN" ] && [ -f "$CFG" ] && TG_TOKEN=$("$NODE" -e "try{process.stdout.write((require('$CFG').channels.telegram.botToken)||'')}catch(e){}" 2>/dev/null)
[ -z "$TG_CHAT" ]  && [ -f "$CFG" ] && TG_CHAT=$("$NODE" -e "try{const a=require('$CFG').channels.telegram.allowFrom;process.stdout.write((a&&a[0])||'')}catch(e){}" 2>/dev/null)

# Single instance.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "[verify-loop] already running" >&2; exit 0
fi
echo $$ > "$PIDFILE"; trap 'rm -f "$PIDFILE"' EXIT

log(){ echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
send(){ # $1 = text
  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then log "WARN: no telegram creds; alert skipped"; return 1; fi
  curl -s -m 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$1" >/dev/null 2>&1
}

log "verify-loop started (pid $$, interval ${INTERVAL}s, verify=$VERIFY)"
sleep "$WARMUP"

while true; do
  out=$("$NODE" "$VERIFY" --json 2>/dev/null)
  overall=$(printf '%s' "$out" | "$NODE" -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{process.stdout.write(JSON.parse(d).overall)}catch(e){process.stdout.write('ERROR')}})" 2>/dev/null)
  read -r prevOverall prevAlertTs < "$STATEF" 2>/dev/null || { prevOverall=""; prevAlertTs=0; }
  prevAlertTs="${prevAlertTs:-0}"
  now=$(date +%s)

  if [ "$overall" = "FAIL" ]; then
    if [ "$prevOverall" != "FAIL" ] || [ $((now - prevAlertTs)) -ge "$REMIND_SECS" ]; then
      fails=$(printf '%s' "$out" | "$NODE" -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(j.checks.filter(c=>c.status==='FAIL').map(c=>'• '+c.name+' '+JSON.stringify(c.evidence)).join('\n'))}catch(e){}})" 2>/dev/null)
      send "🚨 [fox-status] 하네스 점검 FAIL
${fails}

자세히: fox-status (컨테이너에서)"
      prevAlertTs="$now"
      log "ALERT sent (FAIL): $(printf '%s' "$fails" | tr '\n' ';')"
    fi
  elif [ "$overall" = "PASS" ] && [ "$prevOverall" = "FAIL" ]; then
    send "✅ [fox-status] 복구됨 — 모든 점검 PASS."
    log "recovery alert sent"
  fi

  printf '%s %s\n' "${overall:-ERROR}" "$prevAlertTs" > "$STATEF"
  log "overall=${overall:-ERROR}"
  sleep "$INTERVAL"
done
