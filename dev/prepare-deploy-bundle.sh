#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT_DIR="${REPO_DIR}-deploy"

usage() {
  cat <<'EOF'
Usage:
  ./prepare-deploy-bundle.sh [output-dir]

Creates a sanitized deployment bundle with:

- no local `.env`
- no existing agent state under `data/`
- empty persistent directories ready for onboarding

Example:
  ./prepare-deploy-bundle.sh
  ./prepare-deploy-bundle.sh /tmp/kclawbox-release
EOF
}

output_dir="${1:-${DEFAULT_OUTPUT_DIR}}"

case "${output_dir}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

copy_file() {
  cp "${REPO_DIR}/$1" "${output_dir}/$1"
}

mkdir -p "${output_dir}/vendor"
cp -a "${REPO_DIR}/vendor/host-root" "${output_dir}/vendor/"
cp "${REPO_DIR}/vendor/node-v22.19.0-linux-x64.tar.gz" "${output_dir}/vendor/"
mkdir -p "${output_dir}/default-skills"
cp -a "${REPO_DIR}/default-skills/." "${output_dir}/default-skills/"
mkdir -p "${output_dir}/default-openclaw-skills"
cp -a "${REPO_DIR}/default-openclaw-skills/." "${output_dir}/default-openclaw-skills/"
mkdir -p "${output_dir}/default-openclaw-workspace/.clawhub"
cp -a "${REPO_DIR}/default-openclaw-workspace/." "${output_dir}/default-openclaw-workspace/"

copy_file ".dockerignore"
copy_file ".gitignore"
copy_file ".env.example"
copy_file "Dockerfile"
copy_file "README.md"
copy_file "docker-compose.yml"
copy_file "entrypoint.sh"
copy_file "chat-kclawbox.sh"
copy_file "install.sh"
copy_file "onboard-kclawbox.sh"
copy_file "service.sh"

mkdir -p \
  "${output_dir}/data/ollama" \
  "${output_dir}/data/openclaw" \
  "${output_dir}/data/home"

chmod 755 \
  "${output_dir}/chat-kclawbox.sh" \
  "${output_dir}/install.sh" \
  "${output_dir}/onboard-kclawbox.sh" \
  "${output_dir}/service.sh"

cat > "${output_dir}/DEPLOY.md" <<'EOF'
# Deployment Bundle

This directory is sanitized for redistribution:

- no copied `.env`
- no copied local agent state
- no copied Telegram tokens
- no copied Ollama keys or OpenClaw workspaces
- bundled default skills are included and installed on first boot

## First Run

```bash
./onboard-kclawbox.sh
```

The script waits for the box to become ready and then opens the local CLI chat automatically.
Inside chat, use:

```bash
/telegram
```

For service-style control after setup:

```bash
./service.sh start
./service.sh stop
./service.sh status
./service.sh logs --follow
./service.sh chat
```
EOF

echo "bundle_ready=${output_dir}"
echo "bundle_contents:"
find "${output_dir}" -maxdepth 2 | sort
