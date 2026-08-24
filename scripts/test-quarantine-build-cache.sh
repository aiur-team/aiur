#!/usr/bin/env bash
#
# Guards the quarantine job's `_build` cache (#2454). The cache must never
# serve first-party beams predating a source change, and must never restore a
# dependency set that no longer matches `mix.lock`/`mix.exs`.
#
# The invariants this test pins down:
#   1. The `_build` cache path is dependency-only (`src/_build/test/lib`), not
#      the whole `src/_build` directory — so first-party `aiur` beams cannot be
#      restored.
#   2. A step prunes the first-party `aiur` app dir before running tests, so the
#      app always recompiles against the current source even if the cache path
#      somehow carried it.
#   3. No `restore-keys` prefix — a stale `_build` from a different `mix.lock`
#      restores compiled deps whose versions no longer match `mix.exs`, which
#      fails with "Unchecked dependencies for environment test". Exact-key only.
#   4. The key includes `mix.lock` and `mix.exs`, so a lock/dep bump recompiles
#      fresh.
#
# Usage: bash scripts/test-quarantine-build-cache.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/ci.yml"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Print a violation (returns 0 so callers stay under `set -e`); the caller
# returns 1 explicitly so negative fixtures can assert a broken workflow is
# rejected without exiting the script.
violation() {
  echo "violation: $1" >&2
}

# Run every invariant against a workflow file. Returns nonzero on the first
# violation.
check_workflow() {
  local path="$1"
  local quarantine_job
  quarantine_job="$(sed -n '/^  quarantine:$/,/^  test:$/p' "$path")"

  if [[ -z "$quarantine_job" ]]; then
    violation "workflow $path has no quarantine job to guard"
    return 1
  fi

  if ! grep -Fq 'path: src/_build/test/lib' <<<"$quarantine_job"; then
    violation "quarantine job must cache only dependency apps (path: src/_build/test/lib)"
    return 1
  fi
  if grep -Fq 'path: src/_build$' <<<"$quarantine_job"; then
    violation "quarantine job must not cache the whole _build directory (path: src/_build)"
    return 1
  fi
  if grep -Fq 'restore-keys:' <<<"$quarantine_job"; then
    violation "quarantine job must not use restore-keys (the 'Unchecked dependencies for environment test' guard)"
    return 1
  fi
  if ! grep -Fq "hashFiles('src/mix.lock', 'src/mix.exs')" <<<"$quarantine_job"; then
    violation "quarantine cache key must cover mix.lock and mix.exs"
    return 1
  fi
  if ! grep -Fq 'rm -rf src/_build/test/lib/aiur' <<<"$quarantine_job"; then
    violation "quarantine job must prune the first-party aiur app dir so it recompiles fresh"
    return 1
  fi
  # Both prunes are load-bearing: the pre-test drop is what forces the fresh
  # first-party compile, and the post-test prune keeps the saved cache
  # dependency-only.
  grep -Fq 'Drop first-party beams' <<<"$quarantine_job" ||
    { violation "quarantine job must drop the first-party app dir before running tests"; return 1; }
  grep -Fq 'Prune first-party beams before the cache save' <<<"$quarantine_job" ||
    { violation "quarantine job must prune the first-party app dir before the cache save"; return 1; }

  # The dialyzer PLT cache (`src/_build/dev/*.plt*`) is a data file, not app
  # beams, and is the only other _build cache in the workflow.
  if grep -Fq 'path: src/_build$' "$path"; then
    violation "no job may cache the whole _build directory; cache dependency apps only"
    return 1
  fi
}

check_workflow "$workflow"

# The guard must actually run in CI, not just exist on disk.
workflow_security_job="$(sed -n '/^  workflow-security:$/,/^  merge-ruleset-drift:$/p' "$workflow")"
grep -Fq 'Test quarantine _build cache invariants' <<<"$workflow_security_job" ||
  fail "the workflow-security job must run scripts/test-quarantine-build-cache.sh"
grep -Fq 'bash scripts/test-quarantine-build-cache.sh' <<<"$workflow_security_job" ||
  fail "the workflow-security job must run scripts/test-quarantine-build-cache.sh"

# Negative fixtures: each broken shape must be rejected, so the guard cannot
# silently go green on a trivially wrong workflow.
work="$(mktemp -d "${TMPDIR:-/tmp}/aiur-quarantine-cache.XXXXXX")"
trap 'rm -rf "$work"' EXIT

make_fixture() {
  # Start from the real workflow and apply a sed mutation, so the fixture always
  # reflects the current quarantine job structure.
  local out="$1"
  local mutation="$2"
  cp "$workflow" "$out"
  sed -i "$mutation" "$out"
}

expect_rejection() {
  local fixture="$1"
  local reason="$2"
  if check_workflow "$fixture" >/dev/null 2>&1; then
    fail "guard accepted a workflow that $reason"
  fi
}

make_fixture "$work/whole-build.yml" \
  's|path: src/_build/test/lib|path: src/_build|'
expect_rejection "$work/whole-build.yml" "restores the whole _build directory"

make_fixture "$work/restore-keys.yml" \
  '/^          key: ${{ runner.os }}-quarantine-build-deps-/i\          restore-keys: ${{ runner.os }}-quarantine-build-'
expect_rejection "$work/restore-keys.yml" "adds a restore-keys fallback"

# Replace every first-party prune command with a no-op, so the guard must
# reject a job that no longer prunes the `aiur` app dir.
make_fixture "$work/no-prune.yml" \
  's|run: rm -rf src/_build/test/lib/aiur|run: true|g'
expect_rejection "$work/no-prune.yml" "drops the first-party prune"

# Delete the pre-test "Drop first-party beams" step block entirely.
cp "$workflow" "$work/no-pre-prune.yml"
python3 - "$work/no-pre-prune.yml" <<'PY'
import sys
path = sys.argv[1]
out = []
skip = False
for line in open(path):
    if "- name: Drop first-party beams" in line:
        skip = True
        continue
    if skip and line.strip().startswith("- name:"):
        skip = False
    if not skip:
        out.append(line)
open(path, "w").write("".join(out))
PY
expect_rejection "$work/no-pre-prune.yml" "drops only the pre-test first-party prune"

echo "quarantine _build cache guard tests passed"
