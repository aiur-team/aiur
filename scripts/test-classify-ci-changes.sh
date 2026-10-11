#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-classify-ci.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Stub `gh`: the files endpoint prints $FILES, the pull endpoint prints $DRAFT
# (or fails when DRAFT=fail). Every call is logged so a test can prove none ran.
mkdir "$test_dir/bin"
cat > "$test_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$*" in
  *"/files "*) printf '%s' "$FILES" ;;
  *) [ "$DRAFT" != fail ] || exit 1; echo "$DRAFT" ;;
esac
STUB
chmod +x "$test_dir/bin/gh"

# classify <event> <live draft> <files> -> prints the sorted outputs on one line
classify() {
  : > "$test_dir/out"; : > "$test_dir/calls"
  EVENT_NAME="$1" DRAFT="$2" FILES="$3" REPO=o/r PR_NUMBER=7 GH_CALLS="$test_dir/calls" \
    GITHUB_OUTPUT="$test_dir/out" GITHUB_STEP_SUMMARY="$test_dir/summary" \
    PATH="$test_dir/bin:$PATH" bash "$root/scripts/classify-ci-changes.sh" 2>/dev/null
  sort "$test_dir/out" | paste -sd' ' -
}

expect() {
  local want="$1" got; shift
  got="$(classify "$@")"
  if [ "$got" != "$want" ]; then
    echo "classify $*: expected '$want', got '$got'" >&2
    exit 1
  fi
}

lib=$'src/lib/aiur/config.ex\nwebsite/docs-app/reference/configuration.md'
docs=$'website/docs-app/guide/a.md\npackages/aiur-style/tokens.css'

expect 'docs_only=false draft=false' pull_request false "$lib"
expect 'docs_only=true draft=false' pull_request false "$docs"
expect 'docs_only=false draft=false' pull_request false ''
expect 'docs_only=false draft=false' pull_request false '{"message":"Server Error"}'
# The live draft state decides, and an unreadable one runs the full suite.
expect 'docs_only=false draft=true' pull_request true "$lib"
expect 'docs_only=false draft=false' pull_request fail "$lib"
for event in push merge_group workflow_dispatch; do
  expect 'docs_only=false draft=false' "$event" true "$docs"
  [ ! -s "$test_dir/calls" ] || { echo "$event must not call gh" >&2; exit 1; }
done

# Wiring: no job may gate on the event payload's draft flag (#4002), and every
# job outside the three draft-time jobs gates on the live output instead.
workflow="$root/.github/workflows/ci.yml"
if grep -n 'pull_request\.draft' "$workflow" >&2; then
  echo "ci.yml must not read draft state from the event payload" >&2
  exit 1
fi
grep -Fq 'draft: ${{ steps.classify.outputs.draft }}' "$workflow"
grep -Fq 'run: bash scripts/classify-ci-changes.sh' "$workflow"
grep -Fq 'run: bash scripts/test-classify-ci-changes.sh' "$workflow"

echo "CI change classifier tests passed"
