---
tracker:
  kind: github
  active_states:
    - todo
    - in-progress
    - human-review
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
  interval_ms: 5000
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
  before_remove: |
    git status --short
agent:
  max_concurrent_agents: 10
  max_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /home/applekid/code/aiur-workspaces
    networkAccess: true
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
4. Keep all progress, plan, validation, PR URL, blockers, and final notes in that single workpad comment.
5. Follow the issue instructions exactly.
6. Use judgment based on feature size.
7. Large feature asks should usually follow the full loop `ce-brainstorm` -> `ce-plan` -> `ce-work` -> `ce-review`.
8. Smaller asks may skip brainstorm, plan, or review when the extra step would be overhead, but err on the side of using these skills when in doubt.
9. Move the issue to `Human Review` when implementation work is ready for review.
10. Move the issue to `Done` only when the issue explicitly says the agent should close it out without human review.

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

### Final Notes

- ...
````
