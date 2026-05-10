---
tracker:
  kind: github
  active_states:
    - Todo
    - In Progress
    - Human Review
    - Rework
    - Merging
  terminal_states:
    - Done
    - Cancelled
    - Canceled
github:
  repo: its-applekid/actions
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
    git clone git@github.com:its-applekid/actions.git .
    git remote add upstream git@github.com:ethereum-optimism/actions.git
    git fetch upstream main
    issue_id="$(basename "$PWD")"
    git checkout -b "symphony/${issue_id}" origin/main
    git merge upstream/main
  before_remove: |
    git status --short
agent:
  max_concurrent_agents: 1
  max_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on GitHub issue `{{ issue.identifier }}` in `its-applekid/actions`.

The working repository is a fork:

- Fork/origin: `its-applekid/actions`
- Upstream/base: `ethereum-optimism/actions`
- Open PRs from `its-applekid/actions` branches into `ethereum-optimism/actions:main`

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
- Resume from existing workspace state.
- Do not repeat completed investigation unless needed.
{% endif %}

## Required Setup

- Use the local `gh` auth already configured for `its-applekid`.
- If `gh auth status` fails, stop and record the blocker in the workpad.
- Never push to `ethereum-optimism/actions` directly.
- Always push branches to `origin` (`its-applekid/actions`).

GitHub issue state is label-based:

- `agent:todo`
- `agent:in-progress`
- `agent:human-review`
- `agent:rework`
- `agent:merging`
- `agent:done`

## Workflow

1. Read the issue and current labels.
2. If state is `Todo`, move it to `In Progress`.
3. Find or create one persistent issue comment titled `## Codex Workpad`.
4. Keep all progress, plan, validation, PR URL, blockers, and final notes in that single workpad comment.
5. Sync with upstream before editing:

   ```bash
   git fetch upstream main
   git merge upstream/main
   ```

6. Create or reuse a branch named `symphony/<issue-number>-short-title`.
7. Implement the smallest correct change for the issue.
8. Run validation appropriate to the changed files. If the issue specifies tests, run those exactly.
9. Commit with a short, concrete message.
10. Push to the fork:

    ```bash
    git push -u origin HEAD
    ```

11. Open or update a PR:

    ```bash
    gh pr create \
      --repo ethereum-optimism/actions \
      --head its-applekid:<branch> \
      --base main \
      --title "<issue-number>: <short title>" \
      --body-file /tmp/pr-body.md
    ```

12. Put the PR URL in the workpad.
13. Wait for PR checks/review when useful, but do not merge.
14. Move the issue to `Human Review` only when:
    - code is pushed,
    - PR is open,
    - validation is recorded,
    - no known blocker remains.

## PR Body Template

Use this shape:

```md
## Summary

- <what changed>

## Validation

- [x] `<command>` - <result>

## Issue

Closes/Fixes/Refs its-applekid/actions#{{ issue.identifier }}
```

## Workpad Template

Use and update this single issue comment:

````md
## Codex Workpad

```text
<hostname>:<abs-workdir>@<short-sha>
```

### Plan

- [ ] ...

### Validation

- [ ] ...

### PR

- <url once opened>

### Notes

- <timestamped concise progress notes>

### Blockers

- <only include real blockers>
````

## Guardrails

- Do not touch repositories outside the workspace.
- Do not push to upstream.
- Do not merge PRs.
- Do not create extra progress comments.
- Do not mark `Human Review` until a PR exists.
- If blocked by auth, missing secrets, or unclear requirements, update the workpad and leave the issue in `Human Review`.
