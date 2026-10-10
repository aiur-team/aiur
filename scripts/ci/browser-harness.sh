#!/usr/bin/env bash
# Browser, accessibility, performance and visual harness. Runs from the repo root.
set -euo pipefail
cd src/browser
npm ci
npx playwright install --with-deps chromium
npm test
npm run test:visual
npm run test:visual
npm run verify:failure-artifacts
