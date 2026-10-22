#!/usr/bin/env bash
set -euo pipefail

partition="${1:?usage: retry-coverage-tests.sh <partition> <evidence-dir>}"
evidence_dir="${2:?usage: retry-coverage-tests.sh <partition> <evidence-dir>}"
mapfile -t tests < "$evidence_dir/retry-tests.txt"
if [ "${#tests[@]}" -eq 0 ]; then
  echo "retry plan contains no selected tests" >&2
  exit 1
fi

args=()
for test in "${tests[@]}"; do args+=("$test"); done
log="$evidence_dir/retry.log"
status=0
timeout --signal=TERM --kill-after=60s 10m \
  env AIUR_TEST_PROGRESS=1 MIX_ENV=test mix test "${args[@]}" > "$log" 2>&1 || status=$?
cat "$log"
python3 - "$evidence_dir/retry-plan.json" "$status" <<'PY'
import json, pathlib, sys
plan_path = pathlib.Path(sys.argv[1])
plan = json.loads(plan_path.read_text())
outcome = "success" if sys.argv[2] == "0" else "failure"
plan.update({"outcome": outcome, "exit_status": int(sys.argv[2])})
plan_path.write_text(json.dumps(plan, indent=2) + "\n")
PY
if [ "$status" -ne 0 ]; then exit "$status"; fi
echo "Retried known flakes: all selected tests passed on the single retry." >> "$GITHUB_STEP_SUMMARY"
echo "Coverage partition passed after retrying known flakes."
