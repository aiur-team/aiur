#!/usr/bin/env bash
# Merge groups and v2/main pushes run full CI; main schedule pushes are quarantine-only.
set -euo pipefail
if [[ "$EVENT_NAME" != pull_request ]]; then
  if [[ "$EVENT_NAME" == merge_group || "$EVENT_NAME" == workflow_dispatch || "${GITHUB_REF:-}" == refs/heads/v2 || ("$EVENT_NAME" == push && "${GITHUB_REF:-}" == refs/heads/main) ]]; then
    printf 'full_ci=true\ndocs_only=false\nbrowser_smoke=true\n' >> "$GITHUB_OUTPUT"
    echo "event $EVENT_NAME: full CI" >> "$GITHUB_STEP_SUMMARY"
  else
    printf 'full_ci=false\ndocs_only=false\nbrowser_smoke=false\n' >> "$GITHUB_OUTPUT"
    echo "event $EVENT_NAME: quarantine only" >> "$GITHUB_STEP_SUMMARY"
  fi
  printf 'affected_paths_b64=\ndialyzer=false\n' >> "$GITHUB_OUTPUT"
  exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
gh api "repos/$REPO/pulls/$PR_NUMBER" > "$scratch/pr.json"
review="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json reviewDecision --jq .reviewDecision)"
jq --arg review "$review" '.review_decision = $review' "$scratch/pr.json" > "$scratch/pr-review.json"
mv "$scratch/pr-review.json" "$scratch/pr.json"
gh api --paginate --slurp "repos/$REPO/pulls/$PR_NUMBER/files" \
  | jq 'add | map({filename, previous_filename})' > "$scratch/files.json"
# Read opt-in labels from the base: a PR cannot alter its own selection policy.
base="$(jq -er '.base.sha' "$scratch/pr.json")"
git -C "${GITHUB_WORKSPACE:-.}" show "$base:.aiur/config" > "$scratch/policy"
ruby scripts/ci-policy.rb "$scratch/policy" "$scratch/pr.json" "$scratch/files.json" > "$scratch/classification"
browser_smoke="$(sed -n 's/^browser_smoke=//p' "$scratch/classification")"
sed -i '/^browser_smoke=/d' "$scratch/classification"
approval_gated="$(sed -n 's/^approval_gated=//p' "$scratch/classification")"
sed -i '/^approval_gated=/d' "$scratch/classification"
# Keep the old required-check set until all open PRs require the new aggregate.
branch="$(jq -er '.base.ref | @uri' "$scratch/pr.json")"
gh api "repos/$REPO/rules/branches/$branch" > "$scratch/rules.json"
if ! jq -e '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | length > 0 and all(. == "ci gate")' "$scratch/rules.json" >/dev/null; then
  sed -i 's/^full_ci=.*/full_ci=true/' "$scratch/classification"
  sed -i 's/^docs_only=.*/docs_only=false/' "$scratch/classification"
  approval_gated=false
fi
if [[ "$approval_gated" == true ]]; then
  echo 'Unapproved head without `ci:full`: fast checks only; the merge queue runs the full suite.' >> "$GITHUB_STEP_SUMMARY"
fi
if [[ "${EVENT_NAME}" == pull_request ]] && grep -qx 'full_ci=false' "$scratch/classification" && ! grep -qx 'docs_only=true' "$scratch/classification"; then
  jq -r '.[] | .filename, (.previous_filename // empty)' "$scratch/files.json" > "$scratch/paths"
  base_sha="$(jq -er '.base.sha' "$scratch/pr.json")"
  if ! selection="$(cd "${GITHUB_WORKSPACE:-.}/src" && AIUR_CI_CHANGED_PATHS_B64="$(jq -cj '[.[] | .filename, (.previous_filename | select(. != null))] | unique' "$scratch/files.json" | base64 -w0)" AIUR_BASE_SHA="$base_sha" "${MIX_BIN:-mix}" run --no-start ../scripts/ci-test-selection.exs "$scratch/paths" 2>"$scratch/selection-error")"; then
    error="$(cat "$scratch/selection-error")"
    [[ -n "$error" ]] || error='selector exited unsuccessfully without diagnostic output'
    error="${error//$'\n'/; }"
    printf '::warning::affected test selection failed; forcing full CI: %s\n' "$error" >&2
    printf '\n### Affected-test selection warning\n\nAffected-test selection failed; full CI is enabled.\n\n```text\n%s\n```\n' "$error" >> "$GITHUB_STEP_SUMMARY"
    printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification"
    selection=full
  fi
  # Keep only selector result lines; Mix output may appear before or after them.
  result_lines="$(grep -E '^(full|scoped:[0-9]+)$' <<< "$selection" || true)"
  if [[ -z "$result_lines" ]]; then
    echo '::warning::affected test selector produced no valid result; forcing full CI' >&2
    printf '\n### Affected-test selection warning\n\nAffected-test selection produced no valid result; full CI is enabled.\n' >> "$GITHUB_STEP_SUMMARY"
    printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification"
    selection=full
  else
    selection="$(tail -n 1 <<< "$result_lines")"
  fi
  case "$selection" in
    # The affected-tests job defers an unsafe selection to the merge queue.
    full) [[ "$approval_gated" == true ]] || printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification" ;;
    scoped:*)
      selected_count="${selection#scoped:}"
      if [[ ! "$selected_count" =~ ^[0-9]+$ ]]; then
        echo "unsupported affected selection count: $selection" >&2
        exit 1
      fi
      if (( selected_count > 400 )) && [[ "$approval_gated" != true ]]; then
        echo "affected test selection exceeded 400 files ($selected_count); forcing full CI" >&2
        printf 'full_ci=true\ndocs_only=false\n' > "$scratch/classification"
      fi
      ;;
    *) echo "unsupported affected selection: $selection" >&2; exit 1 ;;
  esac
fi
if grep -qx 'full_ci=false' "$scratch/classification"; then
  if [[ "$approval_gated" != true ]] && jq -e '[.[] | .filename, (.previous_filename | select(. != null))] | any(test("^src/lib/.*\\.ex$"))' "$scratch/files.json" >/dev/null; then
    echo 'dialyzer=true' >> "$scratch/classification"
  else
    echo 'dialyzer=false' >> "$scratch/classification"
  fi
  paths_b64="$(jq -cj '[.[] | .filename, (.previous_filename | select(. != null))] | unique' "$scratch/files.json" | base64 -w0)"
  if (( ${#paths_b64} > 900000 )); then
    sed -i 's/^full_ci=.*/full_ci=true/' "$scratch/classification"
    sed -i 's/^docs_only=.*/docs_only=false/' "$scratch/classification"
    paths_b64=''
  fi
  echo "affected_paths_b64=$paths_b64" >> "$GITHUB_OUTPUT"
else
  echo 'dialyzer=false' >> "$scratch/classification"
  echo 'affected_paths_b64=' >> "$GITHUB_OUTPUT"
fi
echo "browser_smoke=$browser_smoke" >> "$scratch/classification"
cat "$scratch/classification" | tee -a "$GITHUB_OUTPUT" >> "$GITHUB_STEP_SUMMARY"
