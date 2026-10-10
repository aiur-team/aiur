#!/usr/bin/env bash
# Surface the shard-composition header of a coverage partition log. Env: PARTITION.
#
# Shard balance is not guaranteed by construction (#2568), so it has to be
# visible on green runs, not only in the failure log. `make coverage-partition`
# prints every shard's file count as its first lines, but the test step
# redirects all of its output to a file, so surface just that header here.
set -euo pipefail
log="$RUNNER_TEMP/coverage-partition-$PARTITION.log"
[ -s "$log" ] || exit 0
{
  echo "### coverage ($PARTITION/4) shard composition"
  echo
  echo '```'
  grep '^coverage-partition:' "$log" || echo "(no shard header; see the partition log)"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
