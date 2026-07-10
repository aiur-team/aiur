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
- For real implementation tickets, branch from `origin/v2`, keep changes small, add tests, and run the scoped local pre-PR gate before opening/finalizing a PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`, affected tests only (the test files for modules you touched plus directly related tests), and `mix credo --strict` scoped to changed files when possible. Fix failures in this scoped gate, then push to `origin` and open a PR against `v2`. Do not gate PR-opening on a clean full-suite `mix test` run or loop on unrelated suite flakes; CI runs the full `make ci` on every PR and is the authoritative full-suite gate.
- For test tickets that explicitly say not to change code, do not create commits or PRs.

## How to operate

Follow the **`using-aiur`** skill for how to run this ticket: the `agent:*` label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, milestone alerts (`emit_alert`), the Agent Workpad template, complexity routing, and the dev loop / commit / PR conventions. Load it before you start. Cross-ticket coordination and the operator-bar progress protocol are covered in the shared instructions above this template.

If a declared blocker pushes `ticket.N.branch.push`, treat it as an inspect-and-stack cue: load `/aiur-agent`, fetch and diff the actual validated ref supplied by the event payload (do not guess `origin/aiur/N`), adopt the real API when present, remove temporary stubs before pushing, and keep your PR stacked on the blocker branch while it remains unmerged. If the push is irrelevant or unusable, keep only that integration point blocked and record the concrete reason.
