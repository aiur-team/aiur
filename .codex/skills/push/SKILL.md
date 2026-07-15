---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and available in `PATH`.
- `gh auth status` succeeds for GitHub operations in this repo.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR against the authoritative configured integration branch if none
  exists, otherwise verify and safely repair the existing PR base.
- Keep branch history clean when remote has moved.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state. In an Aiur agent
   workspace, require the injected `AIUR_BASE_BRANCH` to be nonempty. It is the
   active workflow's configured `tracker.base_branch`; never infer the PR base
   from GitHub's repository default or `origin/HEAD`.
2. Run local validation (`make -C elixir all`) before pushing.
3. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
4. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull`
     skill to merge `origin/$AIUR_BASE_BRANCH`, resolve conflicts, and rerun
     validation. Never substitute the repository default branch.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

5. Ensure a PR exists for the branch:
   - If no PR exists, create one with the exact current branch as `--head` and
     `AIUR_BASE_BRANCH` as `--base`.
   - If a PR exists and is open, compare its `baseRefName` with
     `AIUR_BASE_BRANCH` before updating it. Leave a matching base unchanged.
     For a mismatch, PATCH only the PR's `base` through GitHub's pull request
     REST endpoint, then re-fetch and verify `baseRefName`. Stop with the
     observed branch, expected branch, and repair error if verification fails.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
   - Write a proper PR title that clearly describes the change outcome
   - For branch updates, explicitly reconsider whether current PR title still
     matches the latest scope; update it if it no longer does.
6. Write/update PR body explicitly using `.github/pull_request_template.md`:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - If PR already exists, refresh body content so it reflects the total PR
     scope (all intended work on the branch), not just the newest commits,
     including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.
7. Validate PR body with `mix pr_body.check` and fix all reported issues.
8. Reply with the PR URL from `gh pr view`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)
if [ -z "${AIUR_BASE_BRANCH:-}" ]; then
  echo "AIUR_BASE_BRANCH is required for an agent pull request." >&2
  exit 1
fi

# Minimal validation gate
make -C elixir all

# Initial push: respect the current origin remote.
git push -u origin HEAD

# If that failed because the remote moved, use the pull skill. After
# pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or workflow
# restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

# Ensure a PR exists (create only if missing, always with an explicit base)
pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Current branch is tied to a closed PR; create a new branch + PR." >&2
  exit 1
fi

# Write a clear, human-friendly title that summarizes the shipped change.
pr_title="<clear PR title written for this change>"
if [ -z "$pr_state" ]; then
  gh pr create --draft --head "$branch" --base "$AIUR_BASE_BRANCH" --title "$pr_title"
else
  pr_number=$(gh pr view --json number -q .number)
  actual_base=$(gh pr view --json baseRefName -q .baseRefName)

  if [ "$actual_base" != "$AIUR_BASE_BRANCH" ]; then
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
    gh api --method PATCH "repos/$repo/pulls/$pr_number" -f base="$AIUR_BASE_BRANCH"
    repaired_base=$(gh pr view "$pr_number" --json baseRefName -q .baseRefName)

    if [ "$repaired_base" != "$AIUR_BASE_BRANCH" ]; then
      echo "PR #$pr_number base repair failed: observed=$actual_base expected=$AIUR_BASE_BRANCH verified=$repaired_base" >&2
      exit 1
    fi
  fi

  # Reconsider title on every branch update; edit if scope shifted.
  gh pr edit --title "$pr_title"
fi

# Write/edit PR body to match .github/pull_request_template.md before validation.
# Example workflow:
# 1) open the template and draft body content for this PR
# 2) gh pr edit --body-file /tmp/pr_body.md
# 3) for branch updates, re-check that title/body still match current diff

tmp_pr_body=$(mktemp)
gh pr view --json body -q .body > "$tmp_pr_body"
(cd src && mix pr_body.check --file "$tmp_pr_body")
rm -f "$tmp_pr_body"

# Show PR URL for the reply
gh pr view --json url -q .url
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Log the authoritative integration branch in durable handoff notes, but never
  dump the surrounding environment or machine-local configuration.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
