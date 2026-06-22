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
{% endif %}

## Workspace setup (this repo)

- Work in the current workspace checkout. The `.git` directory IS writable here — do NOT copy it to `.git-writable` (that's a pattern from the GitHub Actions workflow, not this one). Use `git` directly with no `GIT_DIR=...` prefix.
- `mise exec -- mix` and `mise exec -- rg` work out of the box — `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` are pre-set per workspace and `mise trust` has already been run on the workspace `mise.toml`. Do not redeclare these env vars on individual commands.
- For module-only verification (pure function calls, no app supervision needed), use `mix run --no-start -e ...`. Plain `mix run -e ...` tries to start the full Aiur application and fails in agent workspaces (no local `.aiurconfig`).
- For real implementation tickets, branch from `origin/main`, keep changes small, add tests, run compile and lint, push to `origin`, and open a PR.
- For test tickets that explicitly say not to change code, do not create commits or PRs.

## How to operate

Operate per the **`using-aiur`** skill (label lifecycle, the
brainstorm→plan→work→review loop, the dev loop and PR/commit rules, `emit_alert`
milestones and `progress` emits, the Agent Workpad template, and complexity
routing). For cross-ticket events, use the **`aiur-agent`** skill.
