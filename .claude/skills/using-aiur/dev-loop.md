# Dev loop

## Branch

The branch already exists when your workspace boots. Read it with `git branch --show-current` and push or open the PR against that exact ref. New tickets use the generated readable Aiur branch; existing legacy and PR-anchored heads remain unchanged. Do not rename it or reconstruct one from the issue number. The numeric `ticket.<N>.branch.push` event key remains stable even when the actual branch has a suffix.

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
`ticket.<blocker-id>.branch.push` arrives, fetch the actual validated ref carried
by the event payload (or discover it with the centralized ticket-branch parser)
→ commit your local WIP if any → merge that fetched ref → resolve any conflicts →
continue. Do NOT `git stash` before the merge — committing WIP is just as safe
and avoids the index-write failure path entirely.

## The loop

1. Implement
2. Add / update / run tests
3. Run the scoped local pre-PR verification gate before opening or finalizing
   the PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
   affected tests only (the test files for modules you touched plus directly
   related tests), and `mix credo --strict` scoped to changed files when
   possible.
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
7. **Open the PR as a draft** with that branch as `--head` (not ready for
   review yet).
8. **Self-review the draft PR with `ce-code-review`** against the diff you just
   pushed.
9. Implement any issues `ce-code-review` surfaces (commit + push the fixes).
10. Re-run the scoped local pre-PR verification gate after review fixes if any
    code, tests, prompt, skill, or config files changed.
11. If you still believe the work is complete and correct, **mark the PR ready
    for review** and add the `agent:human-review` label.

Do **not** self-merge. Always await user review after marking the PR ready.

**When you flip the label to `agent:human-review`, your turn loop ends
naturally.** Do not keep polling `gh pr view` / `gh issue view` waiting for review
comments — that wastes turns. Aiur will resume you when the label flips back to
`agent:in-progress` (for rework) or `merging`. If you have nothing left to do on
the current turn but the label is still `agent:in-progress` (e.g., you're blocked
on an upstream PR merging), emit `pause.request` instead of looping; the operator
will see the ❗ and reply when ready.

## Manual CLI verification before opening a PR

Before opening the draft PR, run the CLI locally and manually exercise all new
functionality end-to-end. If the CLI fails to run, debug and fix the issues — do
not skip verification or give up. Only open the draft PR once the requested
functionality is confirmed working in the CLI.

Manual CLI verification is in addition to the scoped local pre-PR verification
gate above, not a replacement for it. A PR is not ready for human review until
compile, format, affected tests, and scoped credo strict have passed locally.
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
