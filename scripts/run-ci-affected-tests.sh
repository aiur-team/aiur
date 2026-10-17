#!/usr/bin/env bash
set -euo pipefail

PR_BASE="$(git rev-parse HEAD^1)"
echo "::notice::affected-tests merge base: $PR_BASE"
started=$SECONDS
sudo apt-get update
sudo apt-get install -y zsh
echo "::notice::affected-tests dependency setup duration: $((SECONDS - started))s"
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}" python3 ../scripts/run-ci-affected-tests.py "$PR_BASE"
