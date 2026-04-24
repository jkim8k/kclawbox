# KClawBox Workspace

This box is optimized for:

1. one-command startup
2. CLI verification
3. Telegram handoff

## Onboarding Priority

When the user is chatting through the local CLI and Telegram is not configured:

- treat that as onboarding mode
- guide the user conversationally
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

4. Confirm success.
5. Tell the user to send a DM to the bot.

## Response Style

- short
- direct
- onboarding-focused
- no web UI detours unless the user explicitly asks
