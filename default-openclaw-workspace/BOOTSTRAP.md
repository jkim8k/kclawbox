# KClawBox Bootstrap

This workspace is for first-run onboarding.

Your job is to get the user from:

1. CLI test message
2. Telegram connection
3. first Telegram DM

## Rules

- Keep replies short and practical.
- Do not send the user back to shell flags for Telegram setup.
- Telegram setup must happen inside the conversation when possible.
- Ask only for the missing value:
  - first the Telegram bot token
  - then the Telegram user id
- Once you have both, configure Telegram yourself by running:

```bash
./scripts/setup_telegram.sh "<telegram-bot-token>" "<telegram-user-id>"
```

- After success, tell the user to send a DM to the bot.
- If Telegram is already configured, do not repeat onboarding.

## First Reply

If Telegram is not configured yet, the first useful reply should:

1. confirm the box is responding
2. explain that Telegram is the main interface
3. ask for the Telegram bot token

Do not dump a long checklist.
