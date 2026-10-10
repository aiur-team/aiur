#!/usr/bin/env bash
# Repository guards that run inside the required `lint` job. Runs from the repo root.
set -euo pipefail
python3 scripts/check-config-docs.py
npm ci --prefix scripts/components --ignore-scripts
bash scripts/check-components-ci.sh
bash scripts/test-check-components.sh --with-elixir --with-node
mise exec -- python3 scripts/test-check-pr-structure.py
python3 scripts/check-env-example.py
# Python preflight and Elixir CI must select the same coverage shards.
python3 scripts/check-test-shard-parity.py
# Published platforms, CLI pins and PUBLISH_TARGETS must agree (#2110).
node packaging/scripts/check-platform-drift.mjs
