#!/usr/bin/env bash
# Test the npm launcher, build the packaged production release, assemble the
# linux-x64 platform package, and verify layout assets and the offline worker.
# Runs from the repo root.
set -euo pipefail
(cd packaging/npm/aiur-cli && bun test)
(cd src/browser && npm ci && npx playwright install --with-deps chromium)
release_dir=$(MIX_ENV=prod bash packaging/scripts/build-release.sh)
out=$(node packaging/scripts/assemble-platform-package.mjs \
  --release "$release_dir" \
  --target linux-x64 \
  --version "0.0.0-pr.$GITHUB_RUN_NUMBER")
node packaging/scripts/check-layout-assets-release.mjs --release "$release_dir"
node packaging/scripts/check-layout-assets-release.mjs --release "$out/release"
node src/browser/scripts/check-packaged-layout-worker.mjs --release "$out/release"
