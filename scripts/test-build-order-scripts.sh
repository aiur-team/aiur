#!/usr/bin/env bash
# Run the Build Order publication script suites (stdlib unittest, no network).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -m unittest discover -s .claude/skills/aiur-build/scripts/tests
python3 -m unittest discover -s docs/build-order/scripts/tests
