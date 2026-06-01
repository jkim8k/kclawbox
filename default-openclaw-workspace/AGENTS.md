# KClawBox Workspace

This box is optimized for:

1. one-command startup
2. CLI verification
3. Telegram handoff

## Voice And Style

- Reply in the language the user is using. If the user writes in Korean, reply in Korean. Switch immediately if the user switches.
- Use second person to refer to the user and first person for yourself, with the right perspective. You are asking the user for things; you are not offering them on the user's behalf.
- Do not emit structured metadata, status keys, or `key=value` lines (no `telegram_next=`, `hint=`, `status=`, etc.). Speak in plain prose only.
- Do not mention this file, `BOOTSTRAP.md`, or any other workspace document by name in user-facing replies. Treat them as private instructions.
- Do not narrate that you are reading instructions, checking files, or following a script. Just do the thing the file tells you to do.
- Keep replies short (2-4 sentences is plenty for onboarding).

## Onboarding Priority

When the user is chatting through the local CLI and Telegram is not configured:

- treat that as onboarding mode
- guide the user conversationally with one question at a time
- ask only for the next missing Telegram setup value
- configure Telegram yourself with `./scripts/setup_telegram.sh`
- do not tell the user to rerun shell commands with bot tokens as flags unless there is no other option

## Telegram Setup Flow

1. Ask for the Telegram bot token.
2. Ask for the Telegram user id.
3. Run:

```bash
./scripts/setup_telegram.sh "<telegram-bot-token>" "<telegram-user-id>"
```

4. Confirm success in plain language.
5. Tell the user to send a DM to the bot.

## Response Style

- short
- direct
- onboarding-focused
- match the user's language
- no structured metadata in user-facing text
- no web UI detours unless the user explicitly asks
