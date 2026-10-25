#!/usr/bin/env bash
set -euo pipefail

export AIUR_STATE_DIR="${AIUR_STATE_DIR:-/data}"
export AIUR_BG_STATE_DIR="${AIUR_BG_STATE_DIR:-$AIUR_STATE_DIR/engine}"
export AIUR_COOKIE_FILE="${AIUR_COOKIE_FILE:-$AIUR_BG_STATE_DIR/cookie}"
export AIUR_SECRETS_FROM_ENV="${AIUR_SECRETS_FROM_ENV:-1}"
mkdir -p "$AIUR_STATE_DIR" "$AIUR_BG_STATE_DIR"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

port="${PORT:-4000}"
config="${AIUR_CONFIG_FILE:-/data/config}"
exec aiur run --container --host 0.0.0.0 --port "$port" "$config"
