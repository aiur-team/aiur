#!/usr/bin/env bash
# Stamp the launcher version and pack it into $1. Env: VERSION.
set -euo pipefail
node packaging/scripts/stamp-versions.mjs "$VERSION"
mkdir -p "$1"
cd packaging/npm/aiur-cli
npm pack --pack-destination "$GITHUB_WORKSPACE/$1"
