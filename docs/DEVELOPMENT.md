# Development Notes

This repository is intentionally split into two layers:

- user-facing entrypoints stay at the root
- development and packaging helpers live under `dev/` and `docs/`

## Root

The root should stay focused on the product path:

- `onboard-kclawbox.sh`
- `service.sh`
- `chat-kclawbox.sh`
- runtime files such as `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `default-*`, and `vendor/`

## Dev Helpers

Non-user-facing helpers live under `dev/`:

- `dev/check-kclawbox.sh`
- `dev/prepare-deploy-bundle.sh`

These are useful for debugging or packaging, but they are not part of the normal onboarding flow.

## Deploy Packaging

Deployment output is produced by `dev/prepare-deploy-bundle.sh`.
That script copies only the files needed for redistribution, so development-only files can stay in this repository without leaking into the deploy bundle.
