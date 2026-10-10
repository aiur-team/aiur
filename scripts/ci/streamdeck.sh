#!/usr/bin/env bash
# Stream Deck package install, lint, test and build. Runs from the repo root.
set -euo pipefail
cd packages/streamdeck
npm ci
npm run lint
npm test
npm run build
