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
- `mise exec -- mix` and `mise exec -- rg` work out of the box — `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` are pre-set per workspace and `mise trust` has already been run on the workspace `mise.toml`. Do not redeclare these env vars on individual commands.
- For module-only verification (pure function calls, no app supervision needed), use `mix run --no-start -e ...`. Plain `mix run -e ...` tries to start the full Aiur application and fails in agent workspaces (no local `.aiurconfig`).
- For real implementation tickets, before writing code read `src/.formatter.exs` and Credo's project settings in `src/mix.exs` so changes are lint-clean on the first pass. Keep changes small, add tests, and run the scoped local pre-PR gate before opening/finalizing a PR: `mix compile --warnings-as-errors`, `mix format`, and affected tests only (the test files for modules you touched plus directly related tests). From the workspace root, run `cd src && mise exec -- mix aiur.affected_tests` to compute that scoped set deterministically — it prints the exact root-runnable test command, or advises `make ci` when the change cannot be scoped safely. Run every affected-test invocation with `mix test --max-cases 4` so one agent cannot monopolize the host. Fix failures in this scoped gate, then push to `origin` and open a PR against the configured `tracker.base_branch` (`main` in this repository). Do not run Credo locally. Do not gate PR-opening on a clean full-suite `mix test` run or loop on unrelated suite flakes; CI runs the authoritative full lint and full test suite through `make ci` on every PR.
- For GitHub implementation tickets, once the draft PR is open, self-reviewed, and no code work remains, move to `agent:ci-wait` and end the turn. Do not loop on `gh pr checks`; the daemon delivers CI pass/fail context. On pass, mark the draft ready and move to `agent:human-review`; on failure, use the delivered checks and begin rework. A timeout re-wake permits exactly one check, followed by terminal handling or another `agent:ci-wait` pause.
- For test tickets that explicitly say not to change code, do not create commits or PRs.

## How to operate

Follow the **`using-aiur`** skill for how to run this ticket: the `agent:*` label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, milestone alerts (`emit_alert`), the Agent Workpad template, complexity routing, and the dev loop / commit / PR conventions. Load it before you start. Cross-ticket coordination and the Executor-bar progress protocol are covered in the shared instructions above this template.

### Large design imports

Load the `design-import` skill before a frontend/design skill imports a design
artifact that may exceed 100 KiB. It uses an authenticated writable
`claude --print` session to fetch the artifact directly into a ticket-local
directory, verify it, and inspect it from disk in bounded chunks. If a tool
result reports that Aiur spilled its output to `.aiur-runtime/tool-results/`, continue
from that file path instead of retrying the tool call. This disk-first path is
the recovery path for large HTML design exports and does not require restarting
the agent thread.

When a declared blocker emits `ticket.N.agent.unblocked`, treat that explicit signal as readiness to consume. Load `/aiur-agent`, then use the latest `ticket.N.branch.push` payload only to fetch and diff the actual validated ref (do not guess `origin/aiur/N`), adopt the real API, remove temporary stubs, and keep your PR stacked on the blocker branch while it remains unmerged. Never infer readiness from `branch.push` alone; if the explicitly-unblocked dependency is unusable, keep only that integration point blocked and record the concrete reason.
