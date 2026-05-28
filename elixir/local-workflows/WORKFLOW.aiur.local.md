---
tracker:
  kind: github
  # `human-review` is intentionally NOT in active_states: once the agent
  # flips the label after pushing a PR, its turn loop should end so it
  # doesn't burn turns polling `gh pr view` / `gh issue view` waiting
  # for a human review that may take hours. The issue stays open in
  # GitHub; the orchestrator picks the agent back up when the label
  # flips back to `agent:in-progress` (rework) or `merging`.
  active_states:
    - todo
    - in-progress
    - rework
    - merging
  terminal_states:
    - done
    - cancelled
    - canceled
github:
  repo: its-everdred/aiur
  label_prefix: agent
polling:
  interval_seconds: 5
max_vertical_panes: 3
pre_warmed_sessions: 3
server:
  host: 100.81.109.51
  port: 4000
workspace:
  root: ~/code/aiur-workspaces
hooks:
  after_create: |
    git clone https://github.com/its-everdred/aiur.git .
    issue_id="$(basename "$PWD")"
    git checkout -b "aiur/${issue_id}" origin/main
  before_run: |
    if [ ! -d .git ] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      git clone https://github.com/its-everdred/aiur.git .
      issue_id="$(basename "$PWD")"
      git checkout -b "aiur/${issue_id}" origin/main
    fi
    mkdir -p ./.aiur-hex ./.aiur-mix
    if [ -f elixir/mise.toml ]; then
      mise trust elixir/mise.toml >/dev/null 2>&1 || true
    fi
  before_remove: |
    git status --short
agent:
  max_concurrent_agents: 6
  max_turns: 12
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /home/applekid/code/aiur-workspaces
    networkAccess: true
opencode:
  command: opencode
  bridge_host: 127.0.0.1
  bridge_port: 4097
  serve_args: []
  model_prefix: aiur
---

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

## Required Setup

- Use the local tracker and repository auth already configured for this environment.
- Work in the current workspace checkout.
- For real implementation tickets, branch from `origin/main`, keep changes small, add tests, run compile and lint, push to `origin`, and open a PR.
- For test tickets that explicitly say not to change code, do not create commits or PRs.

GitHub issue state is label-based:

- `agent:todo`
- `agent:in-progress`
- `agent:human-review`
- `agent:rework`
- `agent:merging`
- `agent:done`
- `agent:cancelled`
- `agent:canceled`

## Workflow

1. Read the issue and current labels.
2. If state is `todo`, move it to `in-progress`.
3. Find or create one persistent issue comment titled `## Agent Workpad`.
4. Keep all progress, plan, validation, PR URL, blockers, final notes, and the current handoff in that single workpad comment.
5. Follow the issue instructions exactly.
6. Use judgment based on feature size.
7. Large feature asks should usually follow the full loop `ce-brainstorm` -> `ce-plan` -> `ce-work` -> `ce-review`.
8. Smaller asks may skip brainstorm, plan, or review when the extra step would be overhead, but err on the side of using these skills when in doubt.
9. Move the issue to `Human Review` when implementation work is ready for review.
10. Move the issue to `Done` only when the issue explicitly says the agent should close it out without human review.
11. Before ending a turn while the issue remains active, update the handoff with current phase, key decisions, validation completed, and remaining next steps.

## Alert Milestones

When the work naturally enters one of the standard delivery phases, emit these custom alerts through
the shared `emit_alert` function:

- `phase.brainstorm.start` and `phase.brainstorm.end` when using `ce-brainstorm`
- `phase.plan.start` and `phase.plan.end` when using `ce-plan`
- `phase.work.start` and `phase.work.end` when using `ce-work`
- `phase.review.start` and `phase.review.end` when using `ce-review`

Use concrete messages. Do not emit system-owned alerts under `task.*`, `agent.*`,
or `chat.*`.

## Workpad Template

Use and update this single issue comment:

````md
## Agent Workpad

```text
<hostname>:<abs-workdir>@<short-sha>
```

### Plan

- [ ] ...

### Validation

- [ ] ...

### Handoff

- Phase: ...
- Decisions: ...
- Completed validation: ...
- Next steps: ...

### Final Notes

- ...
````
