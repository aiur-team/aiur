# Dev loop

## Branch

The branch already exists when your workspace boots. Read it with `git -C "$workspace" branch --show-current` and push or open the PR against that exact ref. New tickets use the generated readable Aiur branch; existing legacy and PR-anchored heads remain unchanged. Do not rename it or reconstruct one from the issue number. The numeric `ticket.<N>.branch.push` event key remains stable even when the actual branch has a suffix.

## Repository command safety

Never `cd` into a repository to run Git. Set `workspace` from the absolute path
in the ticket's workspace context, verify that `git -C "$workspace"
rev-parse --show-toplevel` resolves to that same absolute path, and use
`git -C "$workspace"` for every repository operation. A relative path or a
path merely nested inside some other repository is not an acceptable target.

Destructive forms — including `reset --hard`, `clean -fd`, `checkout -- .`,
`restore -- .`, and `worktree remove` — must always carry the explicit `-C`
target. Prefer absolute paths for every command that configures or mutates
state. If the expected path is missing or no longer resolves to the expected
worktree, stop rather than fall back to the current directory. Do not join a
directory change and a Git command with `;`, `&&`, a pipeline, or a subshell.
This is a cross-skill override: while working an Aiur ticket, translate Git
examples from every other installed skill to `git -C "$workspace"` and never
use their `cd`-based or ambient repository context.

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
order: (a) `rm -f "$(git -C "$workspace" rev-parse --path-format=absolute --git-path index.lock)"`,
(b) re-run the failing command with `git -C "$workspace"`, (c) if it
still fails, commit your uncommitted edits with a temporary message and re-attempt
the merge/fetch — committing avoids the stash path that often triggers the
index-write failure. Never `mktemp -d /tmp/...` for recovery and never push from
`/tmp`.**

**Integrating an upstream blocker's branch**: when
`ticket.<blocker-id>.agent.unblocked` arrives, use the latest
`ticket.<blocker-id>.branch.push` payload to fetch the actual validated ref (or
discover it with `scripts/resolve-ticket-branch <blocker-id>`)
→ commit your local WIP if any → merge that fetched ref → resolve any conflicts →
continue. Never infer readiness from the branch push alone. Do NOT run
`git -C "$workspace" stash`
before the merge — committing WIP is just as safe
and avoids the index-write failure path entirely.

Ticket branches are named `aiur/<id>-<slug>` for new tickets, with legacy
`aiur/<id>` branches still supported. `scripts/resolve-ticket-branch <id>` is the
Executor helper for the reverse lookup: it queries the remote, prints the one
matching branch, and exits non-zero when no branch or more than one branch exists.

## Collision-proof worktrees

Concurrent agents on one box share a scratchpad root, and left to choose for
themselves they pick the same obvious worktree name — `wt`, `worktree`, `pr`,
`build`. When two collide, the second silently repoints the checkout at a
different branch *mid-run*, and the first agent's mutation test then runs
against a tree that never contained the change it just reverted — a confident
wrong verdict that gates a merge (#2362). This is a cross-skill override: it
applies to every worktree you create, however the CE skills frame it.

- **Every agent-created worktree path carries the PR number AND a per-agent
  unique component**, never a generic name. Two agents can legitimately review
  the same PR, so the PR number alone is not enough. When the repo ships
  `scripts/agent-worktree`, use it: `scripts/agent-worktree create <n>` fetches
  the PR head onto a unique local branch and creates
  `.worktrees/pr-<n>-<unique>`, refusing on collision. Without it, use the same
  scheme by hand: `git fetch origin pull/<n>/head:pr-<n>-<unique>` then
  `git worktree add .worktrees/pr-<n>-<unique> pr-<n>-<unique>`, deriving
  `<unique>` per agent run (hostname + pid + random, or the agent's session id).
- **An existing path is an error, not a reuse opportunity.** If worktree
  creation reports the target path already exists, stop and pick a fresh unique
  path. Never `git -C <existing-worktree> checkout <other-branch>` or
  `gh pr checkout <n>` inside an existing worktree to "reuse" it — that is the
  exact repoint that corrupts another agent's run.
- **Prune stale worktrees before creating.** `git worktree prune` (or
  `scripts/agent-worktree prune` when available) clears registrations from
  merged branches so a real collision is visible instead of hidden. Never
  remove a worktree another live agent is using.

## Docs ship in the same PR

Documentation is part of the change, not a follow-up ticket. Update
`website/docs-app/` **in this PR** when your work:

- adds or changes a **config key** (`.aiur/config`, `Aiur.Config.Schema.*`) →
  `reference/configuration.md`, plus the `.aiur/examples/` and
  `src/examples/workflows/` templates
- adds or changes a **CLI command or flag** (`aiur`, `aiurdev`) →
  `reference/cli.md`
- adds or changes an **environment variable an operator would set**
- adds a **new user-facing surface** — a dashboard page, a TUI view, a Stream
  Deck mode, a new panel → `guide/`
- **changes documented behavior**, so an existing page is now wrong → that page

Skip docs for internal refactors, bug fixes that restore already-documented
behavior, test-only changes, and performance work with no interface change.
Don't pad a small change with prose.

**Prefer editing an existing page over adding a new one.** Concise and correct
beats comprehensive — a wrong doc is worse than a missing one, so fix every page
your change falsifies first. A genuinely new page also needs a sidebar entry in
`website/docs-app/.vitepress/config.ts`.

Only config keys are machine-checked: `scripts/check-config-docs.py` fails the
required `lint` job when a key has no entry in the configuration reference.
Nothing checks the other cases, so `ce-code-review` treating a missing doc as a
blocking finding is the only enforcement they have.

## The loop

1. Implement
2. Add / update / run tests
3. Update `website/docs-app/` if the change crossed the threshold above
4. Run the scoped local pre-PR verification gate before opening or finalizing
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

   **Renames and signature changes need an exhaustive test-tree audit before
   push.** For every old function name, option key, or changed identifier, run
   `mise exec -- rg -n --fixed-strings -- '<old-name>' src/test/` from the
   repository root and account for every hit. This is separate from selecting
   affected tests, though `mix aiur.affected_tests` also mines deleted source
   references and adds every matching test file. `src/test/aiur/` contains both
   topic directories and files directly, so `test/aiur/github/` does not
   collect the sibling `test/aiur/github_client_test.exs`. A large green
   directory-scoped run does not prove those root-level files ran.
5. Fix every verification failure from the scoped local gate before continuing.
   Do not gate PR-opening on a clean full-suite `mix test` run or loop on
   unrelated suite flakes; CI runs the full `make ci` on every PR and is the
   authoritative full-suite gate.

   **Before you diagnose a failure that looks impossible, rule out a stale test
   build.** `mix compile --force` rebuilds `dev`, **not** `test`, so a stale
   artifact in `_build/test` survives it. Use:

   ```bash
   cd src && MIX_ENV=test mix compile --force
   ```

   This bites hardest after integrating a base that changed a schema, because
   `Aiur.Config.Schema` bakes structs such as `%BuildOrder{}` in at compile time.
   The signature is a failure that contradicts the source you are reading — most
   often `KeyError` for a config key that is plainly defined, or assertions
   passing against defaults that no longer exist. Four agents lost time to this in
   a single run, and one nearly filed a false bug report against a healthy base.
   If a failure disagrees with the code in front of you, force the **test** env
   before believing it.
6. Commit using short, 3–7 word messages, keeping your machine's git identity as
   the author. **When that author is `its-applekid` (email
   `its.applekid@gmail.com`)**, add GitHub's co-author trailer crediting the
   project owner: a blank line at the end of the message, then
   `Co-authored-by: its-everdred <kevinweaver2@gmail.com>`. Commits authored by
   `its-everdred` already carry that credit and need no trailer. **Never** mention
   Claude, Codex, AI, models, or "generated with" in commit messages or PR
   descriptions — keep them plain and human.
7. Push to the exact branch returned by `git -C "$workspace" branch --show-current`. On GitHub,
   `GITHUB_TOKEN` is the push identity: verify that exact token resolves to the
   configured `tracker.github.bot_account` before the first push, without
   printing the token:

   ```bash
   test "$(GH_TOKEN="$GITHUB_TOKEN" gh api user --jq .login)" = "<bot_account>"
   ```

   Aiur's command sandbox passes that token through a fail-closed Git helper;
   it never falls through to the Executor's cached `gh` account. If a manual
   recovery push runs outside that sandbox, reset the helper list explicitly
   and install a helper that reads only `GITHUB_TOKEN`:

   ```bash
   agent_helper='!f() { if test "$1" = get; then if test -z "${GITHUB_TOKEN:-}"; then printf "quit=true\n"; else printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; fi; fi; }; f'
   GIT_TERMINAL_PROMPT=0 git -C "$workspace" -c credential.helper= -c credential.helper="$agent_helper" push origin HEAD
   ```

   Do not put a token in a remote URL or rely on a lone inline helper override:
   token URLs leak credentials, and helper lists are additive unless an empty
   entry resets inherited helpers first. GitHub attributes the push to the
   account owning the token, regardless of the URL username. If the token is
   missing, invalid, or rate-limited, stop on the authentication failure; never
   retry through the Executor keyring. An empty commit or API ref update does
   not repair a prior attribution error because it contributes no reviewable
   file change; the next real content push must use the correct identity.

   A guard refusal reading `aiur: github budget hold resource=<resource>
   reset_at_ms=<milliseconds>` is not an authentication failure. Do not emit a
   credential attention. Emit `pause.request` once with payload
   `{reason: "github_budget_hold", resource: <resource>, reset_at_ms:
   <milliseconds>}`; Aiur resumes that pause automatically when the advertised
   hold clears. Any other broker diagnostic remains fail-closed and must not be
   relabelled as this self-clearing condition.

   Immediately before pushing, run
   `aiur guard-pr-deletions "$AIUR_BASE_BRANCH"`. The command fetches the exact
   configured base and refuses a PR when its tree deletes more than 50 base
   files that none of the feature commits touched. Never bypass a refusal:
   repair the wrong or stale base, or alert the Executor.
8. **Open the PR as a draft** with that branch as `--head` and the authoritative
   integration branch as `--base`: `gh pr create --draft --head "$branch"
   --base "$AIUR_BASE_BRANCH" ...` (not ready for review yet). If a PR already
   exists, read its `baseRefName` before CI handoff. Leave a matching base
   unchanged; if it differs, PATCH only the PR's `base` through GitHub's pull
   request REST endpoint, then re-fetch and verify `baseRefName`. Stop with the
   observed branch, expected branch, and repair error if verification fails.
9. **Own branch freshness before review:** fetch the PR's configured base and
   verify its current remote head is an ancestor of your exact branch head. If
   it is not, integrate or re-cut against it, resolve both textual conflicts
   and semantic drift, rerun the scoped gate, and push. Do not hand stale code
   to the Executor or reviewers to update.
10. **Self-review the draft PR with `ce-code-review`** against the diff you just
    pushed. A missing doc that the threshold above required is a review finding —
    fix it here, not in a follow-up ticket.
11. Implement any issues `ce-code-review` surfaces (commit + push the fixes).
12. Re-run the scoped local pre-PR verification gate after review fixes if any
    code, tests, prompt, skill, or config files changed.
13. Recheck current-base ancestry after fixes. If the base moved, integrate it,
    rerun the scoped gate, and push before continuing.
14. If you still believe the work is complete and correct and only CI remains,
    keep the PR as a draft, add the `agent:ci-wait` label, and end the turn. Do
    not loop on `gh pr checks` + sleep: the daemon polls CI centrally and
    returns the dispatch slot while this runner is paused.
15. On a delivered terminal CI event:
    - **Passed:** fetch the configured base once. If its current remote head is
      still an ancestor of the tested PR head, trust the delivered result without re-polling,
      mark the PR ready for review, emit the required 100% progress sample, and
      add `agent:human-review`. If the base moved, integrate it yourself,
      validate, push, and return to `agent:ci-wait` for fresh exact-head CI.
    - **Failed:** use the delivered failed-check names and excerpt, keep or move
      the ticket in `agent:rework`, and begin the repair loop.
16. On a CI re-wake timeout, run `gh pr checks` exactly once. If CI is terminal,
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
