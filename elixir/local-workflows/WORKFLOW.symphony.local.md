---
tracker:
  kind: github
  active_states:
    - todo
    - in-progress
    - human-review
    - rework
    - merging
    # `error` is intentionally omitted; it is a human-triage holding state.
  terminal_states:
    - done
    - cancelled
    - canceled
github:
  repo: its-everdred/symphony
  label_prefix: agent
polling:
  interval_ms: 5000
server:
  host: 100.81.109.51
  port: 4000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone https://github.com/its-everdred/symphony.git .
    issue_id="$(basename "$PWD")"
    git checkout -b "symphony/${issue_id}" origin/main
  before_run: |
    if [ ! -d .git ] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      git clone https://github.com/its-everdred/symphony.git .
      issue_id="$(basename "$PWD")"
      git checkout -b "symphony/${issue_id}" origin/main
    fi
  before_remove: |
    git status --short
agent:
  max_concurrent_agents: 2
  max_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /home/applekid/code/symphony-workspaces
    networkAccess: true
---

You are working on tracker issue `{{ issue.identifier }}` for the Symphony repository.

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
- `agent:error`

## Workflow

1. Read the issue and current labels.
2. If state is `todo`, move it to `in-progress`.
3. Find or create one persistent issue comment titled `## Agent Workpad`.
4. Keep all progress, plan, validation, PR URL, blockers, and final notes in that single workpad comment.
5. Follow the issue instructions exactly.
6. Move the issue to `Human Review` when implementation work is ready for review.
7. Move the issue to `Done` only when the issue explicitly says the agent should close it out without human review.

## Error Handling

When an unrecoverable error occurs during work on an issue:

1. Move the issue label from `agent:in-progress` to `agent:error`.
2. Append or update a single issue comment titled `## Symphony Error Report`. Include:
   - Short summary of what failed.
   - The error message verbatim, after sanitization.
   - The step in the workflow where it occurred.
   - What you tried, if anything.
3. Do not auto-retry. Do not move the issue back to `agent:todo`.

Sanitization rules for the comment body:

- Replace absolute filesystem paths under `/home/`, `/Users/`, `/var/`, `/tmp/`, or workspace roots with `<workspace>` or `<path>`.
- Replace IP addresses (IPv4 and IPv6) with `<ip>` unless they are public service hostnames such as `api.github.com`.
- Replace any string matching common secret patterns (`gh[ps]_[A-Za-z0-9]{30,}`, `sk-[A-Za-z0-9]{20,}`, OAuth refresh-token shapes, JWTs) with `<redacted-token>`.
- Replace environment variable values where the variable name contains `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, or `AUTH` with `<redacted>`.
- Replace `HOME`, `USER`, and hostname values with `<home>`, `<user>`, and `<host>`.
- When in doubt, redact. The comment is a triage signal, not a debug dump.

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
