#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pre-handoff-ci-routing.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/repo"
mkdir -p "$fixture/scripts"
cp "$repo_root/scripts/run-pre-handoff-guards.sh" "$fixture/scripts/"
cp "$repo_root/scripts/pre-handoff-guards" "$fixture/scripts/"
cp "$repo_root/scripts/pre-handoff-guards.list" "$fixture/scripts/"
cat > "$fixture/scripts/run-pre-handoff-code-checks.sh" <<'CHECKS'
#!/usr/bin/env bash
echo "selected tests ran for $*" >> "$EVENT_LOG"
CHECKS
chmod +x "$fixture/scripts/run-pre-handoff-code-checks.sh"
for guard in check-agent-scratch.py check-on-exit-rm-rf.py check-bare-assert-receive.py check-browser-smoke-shards.mjs check-hot-list-format.py check-file-size.py run-quarantined-tests.py; do
  case "$guard" in
    *.py) printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' > "$fixture/scripts/$guard" ;;
    *.mjs) printf 'process.exit(0)\n' > "$fixture/scripts/$guard" ;;
  esac
  chmod +x "$fixture/scripts/$guard"
done
printf 'exit(0)\n' > "$fixture/scripts/check-config-docs.py"
printf 'process.exit(0)\n' > "$fixture/scripts/check-docs-prose.mjs"
base="$(printf 'a%.0s' {1..40})"
run_event() {
  local label="$1" full_ci="$2"
  : > "$tmp/$label.events"
  : > "$tmp/$label.summary"
  (cd "$fixture" && env \
    GITHUB_EVENT_NAME=pull_request \
    AIUR_PR_BASE_SHA="$base" \
    AIUR_CI_FULL_CI="$full_ci" \
    AIUR_PRE_HANDOFF_EVIDENCE_NOTE='deferred to the parallel coverage and dialyzer jobs' \
    GITHUB_STEP_SUMMARY="$tmp/$label.summary" \
    EVENT_LOG="$tmp/$label.events" \
    bash scripts/run-pre-handoff-guards.sh > "$tmp/$label.log")
}
run_event full true
run_event partial false
grep -F 'selected tests and Dialyzer skipped; deferred to the parallel coverage and dialyzer jobs' "$tmp/full.log" >/dev/null
grep -F 'deferred to the parallel coverage and dialyzer jobs' "$tmp/full.summary" >/dev/null
grep -F "selected tests ran for $base" "$tmp/partial.events" >/dev/null
if grep -F 'Pre-handoff code checks:' "$tmp/partial.summary" >/dev/null; then
  echo 'test-pre-handoff-ci-routing: partial-CI PR incorrectly skipped checks' >&2
  exit 1
fi
echo 'test-pre-handoff-ci-routing: full-CI PR defers checks; partial-CI PR keeps selected checks'
