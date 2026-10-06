#!/usr/bin/env bash
#
# Guards `scripts/check-test-shard-parity.py`. The parity check exists because
# the coverage-shard rule is implemented twice, so a parity check that silently
# passes restores exactly the divergence it was added to prevent: every case
# below asserts it actually fails when the two tables drift.
#
# Usage: bash scripts/test-check-test-shard-parity.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/check-test-shard-parity.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# `test/f_test.exs` really is shard 1 and `test/t_test.exs` really is shard 2
# under sha256(path) % 4 + 1; the real suites assert the same pair.
scaffold() {
  local root="$1" elixir_shard="$2" python_shard="$3"
  rm -rf "$root"
  mkdir -p "$root/scripts" "$root/src/test/aiur"
  cp "$checker" "$root/scripts/check-test-shard-parity.py"

  cat >"$root/src/test/aiur/test_shard_test.exs" <<EOF
defmodule Aiur.TestShardTest do
  @golden %{
    "test/f_test.exs" => 1,
    "test/t_test.exs" => $elixir_shard
  }
end
EOF

  cat >"$root/scripts/test_rename_preflight.py" <<EOF
class ShardOfTest(unittest.TestCase):
    GOLDEN = {
        "test/f_test.exs": 1,
        "test/t_test.exs": $python_shard,
    }
EOF
}

run_check() {
  python3 "$1/scripts/check-test-shard-parity.py" 2>&1
}

# --- Case 1: both tables agree and match the documented rule -> pass --------
root="$work/pass"
scaffold "$root" 2 2
if ! output="$(run_check "$root")"; then
  fail "agreeing, correct tables should pass, got: $output"
fi
grep -q "2 golden shard assignments agree" <<<"$output" ||
  fail "expected the count of checked assignments, got: $output"

# --- Case 2: the two implementations disagree -> fail -----------------------
root="$work/disagree"
scaffold "$root" 2 3
if output="$(run_check "$root")"; then
  fail "diverging golden tables must fail the check, got: $output"
fi
grep -q "golden shard tables disagree" <<<"$output" ||
  fail "the failure must say the tables disagree, got: $output"

# --- Case 3: both agree but both are wrong -> fail --------------------------
# The whole point of recomputing from the rule: two copies of the same wrong
# number are exactly what a copy-paste update produces.
root="$work/both-wrong"
scaffold "$root" 4 4
if output="$(run_check "$root")"; then
  fail "a matching pair of wrong tables must fail the check, got: $output"
fi
grep -q "documented rule says 2" <<<"$output" ||
  fail "the failure must name the shard the rule requires, got: $output"

# --- Case 4: an empty table is not a pass -----------------------------------
root="$work/empty"
scaffold "$root" 2 2
cat >"$root/src/test/aiur/test_shard_test.exs" <<'EOF'
defmodule Aiur.TestShardTest do
  @golden %{
  }
end
EOF
if output="$(run_check "$root")"; then
  fail "an empty golden table must not pass, got: $output"
fi
grep -q "no @golden entries found" <<<"$output" ||
  fail "an empty table must say so, got: $output"

echo "check-test-shard-parity guard: all cases passed"
