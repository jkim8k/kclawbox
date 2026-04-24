#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${KCLAWBOX_REPO_URL:-https://github.com/jkim8k/kclawbox.git}"
TARGET_DIR="${1:-${HOME}/kclawbox}"

if [[ -e "${TARGET_DIR}" && ! -d "${TARGET_DIR}" ]]; then
  echo "error: target exists and is not a directory: ${TARGET_DIR}" >&2
  exit 1
fi

if [[ -d "${TARGET_DIR}/.git" ]]; then
  git -C "${TARGET_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${TARGET_DIR}"
fi

cd "${TARGET_DIR}"
exec ./onboard-kclawbox.sh
