You are working on tracker issue `{{ issue.identifier }}` for the Aiur repository.

Issue:

- Number: `{{ issue.identifier }}`
- Title: {{ issue.title }}
- State label: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

{% if attempt %}
Continuation context:

- Retry attempt #{{ attempt }}.
- Read the existing `## Agent Workpad`, local agent logs, and git state before choosing a phase.
- Resume from the workpad handoff instead of restarting brainstorm or repeating completed work.
- Treat the handoff as the source of truth for current phase, decisions, validation already run, and next steps.
{% endif %}

## Workspace setup

- Use the local tracker and repository auth already configured for this environment.
- Work in the current workspace checkout on its generated canonical branch. Read it with `git branch --show-current`; never reconstruct a bare `aiur/{{ issue.identifier }}` ref. The `.git` directory IS writable here — do NOT copy it to `.git-writable` (that's a pattern from the GitHub Actions workflow, not this one). Use `git` directly with no `GIT_DIR=...` prefix.
- Before integrating the configured base into an existing feature branch, record the exact pre-integration head and create a rescue ref for it; push that rescue ref before resolving any nontrivial conflict. Resolve conflicts hunk-by-hunk while preserving both the feature contract and the new base intent. Never resolve a conflicted file wholesale with `--ours`, `--theirs`, `git checkout <base> -- <file>`, or by resetting the feature branch to the base. Before pushing the refreshed feature branch, compare `git diff --stat origin/$AIUR_BASE_BRANCH...HEAD` with the prior PR scope and prove the intended feature diff remains. If the diff disappears or shrinks unexpectedly, stop, restore from the rescue ref, and alert the Executor instead of pushing.
- `mise exec -- mix` and `mise exec -- rg` work out of the box — `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` are pre-set per workspace and `mise trust` has already been run on the workspace `mise.toml`. Do not redeclare these env vars on individual commands.
- For module-only verification (pure function calls, no app supervision needed), use `mix run --no-start -e ...`. Plain `mix run -e ...` tries to start the full Aiur application and fails in agent workspaces (no local `.aiurconfig`).
- For real implementation tickets, before writing code read `src/.formatter.exs` and Credo's project settings in `src/mix.exs` so changes are lint-clean on the first pass. Keep changes small, add tests, and run the scoped local pre-PR gate before opening/finalizing a PR: `mix compile --warnings-as-errors`, `mix format`, and affected tests only (the test files for modules you touched plus directly related tests). From the workspace root, run `cd src && mise exec -- mix aiur.affected_tests` to compute that scoped set deterministically — it prints the exact root-runnable test command, or advises `make ci` when the change cannot be scoped safely. Run every affected-test invocation with `mix test --max-cases 4` so one agent cannot monopolize the host. Fix failures in this scoped gate, then push to `origin` and open a PR with `--base "$AIUR_BASE_BRANCH"`; this environment value is the authoritative configured `tracker.base_branch` (`main` in this repository), even when GitHub's default differs. Never infer it from `origin/HEAD`. Before CI handoff, verify an existing PR's `baseRefName`; leave a correct base unchanged, or retarget only its `base` and re-fetch to verify the repair. Record the authoritative branch in the durable workpad/PR handoff without logging the surrounding environment or machine-local configuration. Do not run Credo locally. Do not gate PR-opening on a clean full-suite `mix test` run or loop on unrelated suite flakes; CI runs the authoritative full lint and full test suite through `make ci` on every PR.
- After committing and immediately before pushing or opening a PR, run `aiur guard-pr-deletions "$AIUR_BASE_BRANCH"`. It fetches the exact remote base, uses Aiur's recorded workspace branch start, and refuses the PR when more than 50 untouched files would be deleted. Treat a refusal as a wrong-base or stale-base incident: do not bypass it; repair the branch or alert the Executor.
- Author foundation files from the ticket's own description and linked docs, never from a decomposition summary or a plan digest. When a manifest, lockfile, config, or fixture is frozen for downstream tickets, completeness is a correctness property and not a nicety: a later ticket cannot add the dependency your `package.json` omitted or the paths your test glob excluded. Read that ticket's Risk and Notes lines before writing the file — they routinely name the exact omission a summary elides — and enumerate the file's required entries against those docs rather than against whatever the code you happen to have written so far needs.
- Self-review the draft PR as an adversarial reviewer, not as its author. Diff the PR body's claims against the diff you actually pushed: any sentence the diff does not support is a P1 on your own work, not a nitpick, and the repair is to make the diff true or to withdraw the claim — quietly retitling the PR so a thinner change reads as finished is the failure itself, not a fix for it. Ask two questions of every test you added: **does this test execute at all** — is its file inside the runner's configured pattern, and did you see the runner name it in the output — and **would it still pass against a trivially wrong implementation?** A test the runner never collects reports no failure; neither does `f(x) === f(x)`, a test that hand-pokes the very state the wiring under test was supposed to set, or a test asserting against an inlined copy of the code under test.
- For GitHub implementation tickets, once the draft PR is open, self-reviewed, and no code work remains, move to `agent:ci-wait` and end the turn. Do not loop on `gh pr checks`; the daemon delivers CI pass/fail context. On pass, mark the draft ready and move to `agent:human-review`; on failure, use the delivered checks and begin rework. A timeout re-wake permits exactly one check, followed by terminal handling or another `agent:ci-wait` pause.
- A stub standing where an acceptance criterion should be means code work remains — that ticket is not complete. When a criterion cannot be satisfied because a dependency is unavailable, call `aiur_declare_blocker` naming that dependency instead of progressing to `agent:ci-wait`/`agent:human-review` as though the work were done. Stubbing to keep moving is legitimate only when paired with a declared blocker: the declaration is what routes `ticket.N.agent.unblocked` back to you to remove the stub. An undeclared stub — even one labelled with a follow-up comment — silently converts an acceptance criterion into a fiction that outlives your turn.
- Stage every temporary file in a workspace-local path — `$TMPDIR` already points at this workspace's private scratch directory. Never write a GitHub comment or PR body to a bare `/tmp/<generic-name>`: concurrent agents share the host's `/tmp`, and a second agent staging at the same obvious path silently overwrites yours, so you publish that ticket's content under your comment id.
- Posted is not verified. A review, comment, label change, or thread reply issued as your turn ends can be lost with the request still in flight, and nothing reports the loss. After every GitHub mutation, re-read the state it was supposed to change — `reviewDecision` for a review, the thread's latest comment for a reply, the issue's label set for a transition — and end the turn only once the observable state matches what you intended. For a comment body this means diffing, not checking the status code: a `200` with a fresh `updated_at` says *a* write landed, not that *yours* did, so compare the re-read body against the exact body you intended to publish.
- For test tickets that explicitly say not to change code, do not create commits or PRs.

## How to operate

Follow the **`aiur-agent`** skill for how to run this ticket: the `agent:*` label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, milestone alerts (`emit_alert`), the Agent Workpad template, complexity routing, the dev loop / commit / PR conventions, and cross-ticket events. Load it before you start. Cross-ticket coordination and the Executor-bar progress protocol are covered in the shared instructions above this template.

### Large design imports

Load the `design-import` skill before a frontend/design skill imports a design
artifact that may exceed 100 KiB. It uses an authenticated writable
`claude --print` session to fetch the artifact directly into a ticket-local
directory, verify it, and inspect it from disk in bounded chunks. If a tool
result reports that Aiur spilled its output to `.aiur-runtime/tool-results/`, continue
from that file path instead of retrying the tool call. This disk-first path is
the recovery path for large HTML design exports and does not require restarting
the agent thread.

When a declared blocker emits `ticket.N.agent.unblocked`, treat that explicit signal as readiness to consume. Load `aiur-agent`, then use the latest `ticket.N.branch.push` payload only to fetch and diff the actual validated ref (do not guess `origin/aiur/N`), adopt the real API, remove temporary stubs, and keep your PR stacked on the blocker branch while it remains unmerged. Never infer readiness from `branch.push` alone; if the explicitly-unblocked dependency is unusable, keep only that integration point blocked and record the concrete reason.
