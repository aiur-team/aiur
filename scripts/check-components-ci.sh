#!/usr/bin/env bash
# CI supplies the PR base through an environment variable, never shell interpolation.
set -euo pipefail
args=(--require-elixir)
if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
  base="$(python3 -c 'import json,os; print(json.load(open(os.environ["GITHUB_EVENT_PATH"]))["pull_request"]["base"]["sha"])')"
  args+=(--growth-base "$base")
fi
python3 scripts/check-components.py "${args[@]}"
mise exec -- python3 scripts/test-component-ratchet.py
