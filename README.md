# KClawBox

One container that runs:

- Ollama server
- local model serving on GPU
- `ollama launch openclaw`
- optional Telegram channel auto-configuration during first boot
- bundled ClawHub/OpenClaw workspace skills for memory and `agent-browser`

## Fast Onboarding

Use [onboard-kclawbox.sh](./onboard-kclawbox.sh) to ask for an English one-word agent name, create a self-contained workspace directory at `./workspaces/<name>/` that holds the agent's Ollama model, OpenClaw state, and Codex home, wait until the box is actually ready, and jump straight into chat.

One-line install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jkim8k/kclawbox/main/install.sh)
```

The repository clones to `~/kclawbox`. To install elsewhere (for example on a larger partition), pass an absolute path:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jkim8k/kclawbox/main/install.sh) /data/kclawbox
```

Minimal setup:

```bash
cd kclawbox
./onboard-kclawbox.sh
```

The onboarding script should finish by dropping you into the CLI chat. Inside chat:

```bash
/telegram
```

The agent should then ask for the bot token and Telegram user id one at a time and configure Telegram from inside the conversation.

If the default name or ports are occupied, the script automatically chooses the next safe values. You can still override them manually if you want:

```bash
./onboard-kclawbox.sh \
  --container-name kclawbox-test \
  --ollama-port 21434 \
  --openclaw-port 28789
```

If you want service-style control after first setup:

```bash
./service.sh start
./service.sh stop
./service.sh status
./service.sh logs --follow
./service.sh chat
```

## What The Onboarding Script Does

- writes `.env`
- asks for the agent's English one-word name
- generates a random gateway token if one is not provided
- creates `./workspaces/<name>/{ollama,openclaw,home}` so the model and all state live inside the install directory
- prevents state sharing across agent names
- auto-picks a free container name if `kclawbox-{name}` is already taken
- auto-picks free host ports if the defaults are already occupied
- starts `docker compose up --build -d` by default
- waits until OpenClaw is really installed and the gateway is reachable
- opens the CLI chat automatically unless `--no-chat` is used

If a Telegram bot token and allowlist are provided, the container configures the Telegram channel automatically on boot.

The deployment image seeds OpenClaw workspace skills into `/data/openclaw/.openclaw/workspace/skills`, including `memory-qdrant`, `elite-longterm-memory-local`, `memory-tiering`, and `agent-browser-clawdbot`.
On first boot, `kclawbox` installs npm dependencies for the memory skills and installs the `agent-browser` CLI globally.
The Docker build downloads the Ollama runtime during image build. The model itself is still downloaded on first boot via `ollama pull`.

## Files

- [onboard-kclawbox.sh](./onboard-kclawbox.sh): first-run bootstrap
- [service.sh](./service.sh): service-style start/stop/status/logs/chat wrapper
- [chat-kclawbox.sh](./chat-kclawbox.sh): interactive CLI chat
- [install.sh](./install.sh): clone-or-update and start onboarding
- [entrypoint.sh](./entrypoint.sh): in-container bootstrap
- [dev/prepare-deploy-bundle.sh](./dev/prepare-deploy-bundle.sh): create a sanitized redistribution bundle
- [dev/check-kclawbox.sh](./dev/check-kclawbox.sh): debugging-only health check
- [docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md): development notes and non-user-facing tooling

## Redistribution

Create a clean deployment copy without your local `.env`, Telegram tokens, OpenClaw state, or Ollama credentials:

```bash
cd kclawbox
./dev/prepare-deploy-bundle.sh
```

The default output is `../kclawbox-deploy`.

## Notes

- The first start will pull the selected model inside the container.
- The first start also runs `ollama launch openclaw --model ... --yes`.
- Each agent gets its own `./workspaces/<name>/` directory so the model, OpenClaw state, and Codex home stay inside the install directory (files written from the container are root-owned; use `--force` on re-onboarding to clean).
- Plan for at least ~30 GB free on the partition that holds the install directory; the default `qwen3.6` model alone is ~23 GB.
- Default model is `qwen3.6:latest`.
- If Telegram is configured, `TELEGRAM_ALLOW_FROM` should contain one or more comma-separated Telegram user ids.
- Internet access is required at image build time to download the Ollama runtime.
