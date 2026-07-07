# T-005: Tripwire CI guard for regression tests

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2`

## Problem / context

`docs/refactor/regression-safety.md` §2 ("Read-only mechanics") mandates that the
characterization suite under `src/test/aiur/regression/` (19 existing test files
today, growing via T-007..T-013) is read-only to executor agents: a CI check must
fail any PR whose diff touches that directory unless the PR carries the
operator-applied override label `regression-suite-change`. CODEOWNERS cannot
enforce this (the repo-wide wildcard rule makes it a no-op as an edit guard), so
enforcement must be a CI job.

The existing `.github/workflows/ci.yml` must NOT be modified (T-001 owns its only
planned change). This ticket adds a separate, self-contained workflow file that
runs on every PR and re-runs when labels change, so applying the override label
un-blocks a legitimately-flagged PR without a new push.

## Scope (exact)

1. Create the override label on the repository. Run exactly:

   ```
   gh label create regression-suite-change --color D93F0B --description "Operator-approved change to characterization tests" || true
   ```

   The `|| true` makes the step idempotent if the label already exists. Do not
   apply this label to any PR — creating it is the whole step.

2. Create the file `.github/workflows/regression-guard.yml` with EXACTLY this
   content (copy verbatim; the checkout action SHA matches the pin already used
   in `.github/workflows/ci.yml` line 17):

   ```yaml
   name: regression-guard

   on:
     pull_request:
       types: [opened, synchronize, reopened, labeled, unlabeled]

   jobs:
     guard:
       runs-on: ubuntu-latest
       steps:
         - name: Checkout
           uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
           with:
             fetch-depth: 0
         - name: Fail if regression suite changed without override label
           env:
             HAS_OVERRIDE_LABEL: ${{ contains(github.event.pull_request.labels.*.name, 'regression-suite-change') }}
           run: |
             set -euo pipefail
             if git diff --name-only "origin/${{ github.base_ref }}...HEAD" | grep '^src/test/aiur/regression/'; then
               if [ "$HAS_OVERRIDE_LABEL" = "true" ]; then
                 echo "PR touches src/test/aiur/regression/ and carries the regression-suite-change label. Allowed."
               else
                 echo "::error::This PR modifies files under src/test/aiur/regression/ without the operator-applied regression-suite-change label. Characterization tests are read-only: a failing characterization test means your change is wrong. Revert the test edits, or have the operator apply the regression-suite-change label."
                 exit 1
               fi
             else
               echo "No files under src/test/aiur/regression/ changed. Guard passes."
             fi
   ```

3. Make no other changes. In particular, do not edit `.github/workflows/ci.yml`
   and do not add any file under `src/`.

## Files

- Create: `.github/workflows/regression-guard.yml`
- Modify: None
- Test: None (a CI workflow has no Elixir test surface; behavior is verified by
  the at-merge probe below)

## Out of scope

- `.github/workflows/ci.yml` — do not touch (its `push:` branches change belongs
  to T-001; this guard is deliberately a separate workflow file).
- `.github/workflows/publish-image.yml`, `release-npm.yml`, `bump-homebrew.yml`.
- `.github/CODEOWNERS` — advisory only here; do not add rules.
- Anything under `src/test/aiur/regression/` — the very directory this guard
  protects; do not create, edit, or move files there.
- Website CI (T-004 owns `website/` CI).
- Applying the `regression-suite-change` label to any PR (operator-only action).
- Branch filters, `push:` triggers, concurrency groups, or any workflow trigger
  beyond the five `pull_request` types listed.

## Inventory-IDs

This ticket creates new CI enforcement; no existing FI entry is implemented by
the new file. Adjacent inventory entries that constrain it (read, do not modify
their subjects):

- **FI-ENG-073** — Makefile targets / CI entry points; cites
  `.github/workflows/ci.yml:83-86`, which must remain byte-identical.
- **FI-ENG-074** — `mix lint` alias composition; cites
  `.github/workflows/ci.yml:58`, likewise untouched.
- **FI-ENG-079** — `publish-image.yml` [ci-workflow]; establishes the repo norm
  this workflow follows: all actions SHA-pinned (the checkout pin above).

## Characterization-tests

This ticket creates none; it is the enforcement layer that makes the entire
`src/test/aiur/regression/` suite (19 files today, e.g.
`instance_identity_test.exs`, `shutdown_cleanup_test.exs`,
`warm_state_transitions_test.exs`, plus everything T-007..T-013 add) read-only
without the `regression-suite-change` label, per `regression-safety.md` §2 and
the never-prune whitelist in §5.

## Acceptance criteria

- `.github/workflows/regression-guard.yml` exists and is <= 200 lines
  (`grep -c "" .github/workflows/regression-guard.yml` <= 200; expected ~34).
- `grep -F "types: [opened, synchronize, reopened, labeled, unlabeled]" .github/workflows/regression-guard.yml` matches.
- `grep -F "fetch-depth: 0" .github/workflows/regression-guard.yml` matches.
- `grep -F "^src/test/aiur/regression/" .github/workflows/regression-guard.yml` matches.
- `grep -c "regression-suite-change" .github/workflows/regression-guard.yml` >= 2
  (the `contains()` check and the error message).
- `grep -F "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd" .github/workflows/regression-guard.yml` matches (SHA-pinned, same pin as ci.yml).
- `git diff --name-only origin/v2...HEAD` outputs exactly one line:
  `.github/workflows/regression-guard.yml` (ci.yml and everything else untouched).
- `gh label list --json name,color --search regression-suite-change` includes
  `"name":"regression-suite-change"` with `"color":"D93F0B"`.
- The PR for this ticket itself shows a green `regression-guard / guard` check
  (it touches no regression files, so the guard passes trivially).

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- Check: `gh label list --search regression-suite-change` shows the label with
  color `D93F0B` and description "Operator-approved change to characterization
  tests".
- Check: on the ticket's PR, the `regression-guard / guard` check ran and passed
  (`gh pr checks <pr-number>` lists `guard` as pass).
- Probe (end-to-end, after merge to `v2`): create a throwaway branch off `v2`
  adding one trailing blank line to
  `src/test/aiur/regression/instance_identity_test.exs`; open a draft PR based
  on `v2`; confirm `regression-guard / guard` FAILS with the "without the
  operator-applied regression-suite-change label" error. Apply the
  `regression-suite-change` label to that draft PR; confirm the `labeled` event
  re-runs the guard and it PASSES. Then close the draft PR unmerged and delete
  the throwaway branch.
- Check: `git show v2:.github/workflows/ci.yml` is byte-identical to its
  pre-merge content (this ticket changed only the new workflow file).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
