#!/usr/bin/env bash
# Event selects fast/full CI; operator policy can force full CI on a PR.
set -euo pipefail
if [[ "$EVENT_NAME" != pull_request ]]; then
  printf 'full_ci=true\ndocs_only=false\n' >> "$GITHUB_OUTPUT"
  echo "event $EVENT_NAME: full CI" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
gh api "repos/$REPO/pulls/$PR_NUMBER" > "$scratch/pr.json"
gh api --paginate --slurp "repos/$REPO/pulls/$PR_NUMBER/files" \
  | jq 'add | map({filename, previous_filename})' > "$scratch/files.json"
# Read policy from the base: a PR cannot weaken its own full-CI requirement.
base="$(jq -er '.base.sha' "$scratch/pr.json")"
git -C "${GITHUB_WORKSPACE:-.}" show "$base:.aiur/config" > "$scratch/policy"
ruby scripts/ci-policy.rb "$scratch/policy" "$scratch/pr.json" "$scratch/files.json" > "$scratch/classification"
# Keep the full old check set until every open PR has the new aggregate.
branch="$(jq -er '.base.ref | @uri' "$scratch/pr.json")"
gh api "repos/$REPO/rules/branches/$branch" > "$scratch/rules.json"
if ! jq -e '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | length > 0 and all(. == "ci gate")' "$scratch/rules.json" >/dev/null; then
  sed -i 's/^full_ci=.*/full_ci=true/' "$scratch/classification"
fi
if grep -qx 'full_ci=false' "$scratch/classification" && ! grep -qx 'docs_only=true' "$scratch/classification"; then
  jq -r '.[] | .filename, (.previous_filename // empty)' "$scratch/files.json" > "$scratch/paths"
  selection="$(elixir -r src/lib/aiur/affected_tests.ex scripts/ci-test-selection.exs "$scratch/paths")"
  case "$selection" in
    full) printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification" ;;
    scoped:*)
      selected_tests="${selection#scoped:}"
      # A 525-file selection reached 7,840 tests; keep that size on full CI.
      if (( selected_tests > 400 )); then
        printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification"
      fi
      ;;
    *) echo "unsupported affected selection: $selection" >&2; exit 1 ;;
  esac
fi
if grep -qx 'full_ci=false' "$scratch/classification"; then
  paths_b64="$(jq -cj '[.[] | .filename, (.previous_filename | select(. != null))] | unique' "$scratch/files.json" | base64 -w0)"
  if (( ${#paths_b64} > 900000 )); then
    sed -i 's/^full_ci=.*/full_ci=true/' "$scratch/classification"
    paths_b64=''
  fi
  echo "affected_paths_b64=$paths_b64" >> "$GITHUB_OUTPUT"
else
  echo 'affected_paths_b64=' >> "$GITHUB_OUTPUT"
fi
cat "$scratch/classification" | tee -a "$GITHUB_OUTPUT" >> "$GITHUB_STEP_SUMMARY"
