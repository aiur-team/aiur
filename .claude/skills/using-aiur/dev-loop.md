# Dev loop

## Branch

The branch already exists when your workspace boots. Read it with `git branch --show-current` and push or open the PR against that exact ref. New tickets use the generated readable Aiur branch; existing legacy and PR-anchored heads remain unchanged. Do not rename it or reconstruct one from the issue number. The numeric `ticket.<N>.branch.push` event key remains stable even when the actual branch has a suffix.

The agent environment also carries the active workflow's authoritative
integration branch as `AIUR_BASE_BRANCH`. It comes from the configured
`tracker.base_branch`, not GitHub's repository default or `origin/HEAD`. Require
it to be nonempty, include the branch name in durable workpad/PR handoff notes,
and pass it explicitly on every PR creation or retarget operation. Do not log
the surrounding environment or machine-local configuration.

**The workspace `.git` directory is writable from this sandbox. If a `git`
command claims the index is read-only ("Could not write index", "Unable to
lock", "cannot create FETCH_HEAD"), do NOT clone a recovery checkout into
`/tmp` — that path pays a full `mix deps.get` + compile (5–10 min) for no
benefit. The real cause is almost always either a stale `.git/index.lock` from a
prior cancelled command or a sandbox snapshot from before this turn. Recovery, in
order: (a) `rm -f .git/index.lock`, (b) re-run the failing command, (c) if it
still fails, commit your uncommitted edits with a temporary message and re-attempt
the merge/fetch — committing avoids the stash path that often triggers the
index-write failure. Never `mktemp -d /tmp/...` for recovery and never push from
`/tmp`.**

**Integrating an upstream blocker's branch**: when
`ticket.<blocker-id>.agent.unblocked` arrives, use the latest
`ticket.<blocker-id>.branch.push` payload to fetch the actual validated ref (or
discover it with `scripts/resolve-ticket-branch <blocker-id>`)
→ commit your local WIP if any → merge that fetched ref → resolve any conflicts →
continue. Never infer readiness from the branch push alone. Do NOT `git stash`
before the merge — committing WIP is just as safe
and avoids the index-write failure path entirely.

Ticket branches are named `aiur/<id>-<slug>` for new tickets, with legacy
`aiur/<id>` branches still supported. `scripts/resolve-ticket-branch <id>` is the
Executor helper for the reverse lookup: it queries the remote, prints the one
matching branch, and exits non-zero when no branch or more than one branch exists.

## The loop

1. Implement
2. Add / update / run tests
3. Run the scoped local pre-PR verification gate before opening or finalizing
   the PR: `mix compile --warnings-as-errors`, `mix format`, and affected tests
   only (the test files for modules you touched plus directly related tests),
   each run with `mix test --max-cases 4`. Compute that scoped set
   deterministically instead of guessing it: from the workspace root run
   `cd src && mise exec -- mix aiur.affected_tests`, which maps the modules you
   changed to their sibling test files and prints the exact root-runnable test
   command (or advises `make ci` when the change cannot be scoped safely).
   Running only the affected tests also keeps full-suite log volume out of your
   context. Do not run Credo locally; CI's `make ci` is the authoritative full
   lint and full-suite gate.
4. Fix every verification failure from the scoped local gate before continuing.
   Do not gate PR-opening on a clean full-suite `mix test` run or loop on
   unrelated suite flakes; CI runs the full `make ci` on every PR and is the
   authoritative full-suite gate.
5. Commit using short, 3–7 word messages, keeping your machine's git identity as
   the author. **When that author is `its-applekid` (email
   `its.applekid@gmail.com`)**, add GitHub's co-author trailer crediting the
   project owner: a blank line at the end of the message, then
   `Co-authored-by: its-everdred <kevinweaver2@gmail.com>`. Commits authored by
   `its-everdred` already carry that credit and need no trailer. **Never** mention
   Claude, Codex, AI, models, or "generated with" in commit messages or PR
   descriptions — keep them plain and human.
6. Push to the exact branch returned by `git branch --show-current`.
   Immediately before pushing, run
   `aiur guard-pr-deletions "$AIUR_BASE_BRANCH"`. The command fetches the exact
   configured base and refuses a PR when its tree deletes more than 50 base
   files that none of the feature commits touched. Never bypass a refusal:
   repair the wrong or stale base, or alert the Executor.
7. **Open the PR as a draft** with that branch as `--head` and the authoritative
   integration branch as `--base`: `gh pr create --draft --head "$branch"
   --base "$AIUR_BASE_BRANCH" ...` (not ready for review yet). If a PR already
   exists, read its `baseRefName` before CI handoff. Leave a matching base
   unchanged; if it differs, PATCH only the PR's `base` through GitHub's pull
   request REST endpoint, then re-fetch and verify `baseRefName`. Stop with the
   observed branch, expected branch, and repair error if verification fails.
8. **Own branch freshness before review:** fetch the PR's configured base and
   verify its current remote head is an ancestor of your exact branch head. If
   it is not, integrate or re-cut against it, resolve both textual conflicts
   and semantic drift, rerun the scoped gate, and push. Do not hand stale code
   to the Executor or reviewers to update.
9. **Self-review the draft PR with `ce-code-review`** against the diff you just
   pushed.
10. Implement any issues `ce-code-review` surfaces (commit + push the fixes).
11. Re-run the scoped local pre-PR verification gate after review fixes if any
    code, tests, prompt, skill, or config files changed.
12. Recheck current-base ancestry after fixes. If the base moved, integrate it,
    rerun the scoped gate, and push before continuing.
13. If you still believe the work is complete and correct and only CI remains,
    keep the PR as a draft, add the `agent:ci-wait` label, and end the turn. Do
    not loop on `gh pr checks` + sleep: the daemon polls CI centrally and
    returns the dispatch slot while this runner is paused.
14. On a delivered terminal CI event:
    - **Passed:** fetch the configured base once. If its current remote head is
      still an ancestor of the tested PR head, trust the delivered result without re-polling,
      mark the PR ready for review, emit the required 100% progress sample, and
      add `agent:human-review`. If the base moved, integrate it yourself,
      validate, push, and return to `agent:ci-wait` for fresh exact-head CI.
    - **Failed:** use the delivered failed-check names and excerpt, keep or move
      the ticket in `agent:rework`, and begin the repair loop.
15. On a CI re-wake timeout, run `gh pr checks` exactly once. If CI is terminal,
    follow the pass or failure path; if it is still pending, return to
    `agent:ci-wait` and end the turn without polling again.

Do **not** self-merge. Always await user review after marking the PR ready.

**When you flip the label to `agent:ci-wait` or `agent:human-review`, your turn
loop ends naturally.** Do not keep polling `gh pr checks`, `gh pr view`, or
`gh issue view` waiting for CI or review comments — that wastes turns. Aiur will
resume you with a terminal CI result, a bounded CI fallback re-wake, or when the
label flips back to `agent:in-progress` / `agent:rework` / `merging`. If you have
nothing left to do on the current turn but the label is still
`agent:in-progress` for a non-CI reason (for example, an upstream PR must merge),
emit `pause.request` instead of looping; the Executor will see the ❗ and reply
when ready.

## Manual CLI verification before opening a PR

Before opening the draft PR, run the CLI locally and manually exercise all new
functionality end-to-end. If the CLI fails to run, debug and fix the issues — do
not skip verification or give up. Only open the draft PR once the requested
functionality is confirmed working in the CLI.

Manual CLI verification is in addition to the scoped local pre-PR verification
gate above, not a replacement for it. A PR is not ready for human review until
compile, format, affected tests with the four-case cap, and scoped credo strict
have passed locally.
The full suite is CI's job through `make ci`; do not loop locally on full-suite
flakes before opening or finalizing the PR.

## Closing keyword in the PR description

Every PR description must start with `Closes #N` (or `Fixes` / `Resolves`) for the
originating issue so GitHub auto-closes it on merge. Multiple issues:
`Closes #43, #46`.

## PR description shape

Keep PR descriptions concise. Assume reviewers have the issue, workpad, and prior
discussion for full problem context. Use this shape:

```markdown
Closes #N

# Problem

One short paragraph or 2-3 bullets describing the issue being fixed.

# Solution

3-6 bullets covering the meaningful implementation and validation.
```

Do not include complexity-routing explanations, model names, AI tool names, or
long process narratives in PR descriptions. Mention validation only as concrete
checks that passed or known checks that still need attention.
