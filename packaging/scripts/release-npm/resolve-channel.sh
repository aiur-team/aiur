#!/usr/bin/env bash
# Resolve the release channel and version for the run. Env: INPUT_CHANNEL.
set -euo pipefail
if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  channel=stable
elif [ "$GITHUB_EVENT_NAME" = "schedule" ]; then
  channel=nightly
else
  channel="${INPUT_CHANNEL:-dry-run}"
fi
echo "channel=$channel" >> "$GITHUB_OUTPUT"
node packaging/scripts/resolve-version.mjs \
  --channel "$([ "$channel" = "dry-run" ] && echo dev || echo "$channel")" \
  --tag "$GITHUB_REF" \
  --sha "$GITHUB_SHA" \
  --run "$GITHUB_RUN_NUMBER" >> "$GITHUB_OUTPUT"
