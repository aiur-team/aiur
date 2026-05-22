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
  repo: your-org/your-repo
  label_prefix: agent
polling:
  interval_ms: 30000
max_vertical_panes: 3
server:
  host: 127.0.0.1
  port: 4000
workspace:
  root: ~/code/aiur-workspaces
hooks:
  after_create: |
    git clone "$AIUR_REPOSITORY_URL" .
    issue_id="$(basename "$PWD")"
    git checkout -b "aiur/${issue_id}" origin/main
  before_remove: |
    git status --short
agent:
  max_concurrent_agents: 10
  max_turns: 12
codex:
  command: codex app-server
opencode:
  command: opencode
  bridge_host: 127.0.0.1
  bridge_port: 4097
  serve_args: []
  model_prefix: aiur
---

You are working on tracker issue `{{ issue.identifier }}`.

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

- Work in the current workspace checkout.
- Use the repository authentication configured for this environment.
- Keep changes small, validate them, push to the configured fork or origin, and open a PR when the work is ready for review.

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
4. Keep progress, plan, validation, PR URL, blockers, final notes, and the current handoff in that single workpad comment.
5. Follow the issue instructions exactly.
6. Move the issue to `Human Review` when implementation work is ready for review.
7. Move the issue to `Done` only when the issue explicitly says the agent should close it out without human review.
8. Before ending a turn while the issue remains active, update the handoff with current phase, key decisions, validation completed, and remaining next steps.

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
