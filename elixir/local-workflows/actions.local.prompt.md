You are working on GitHub issue `{{ issue.identifier }}` in `ethereum-optimism/actions`.

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
- Before taking new action, read the existing workpad, local agent logs, and git state.
- Do not repeat completed investigation, implementation, validation, pushes, or PR creation unless needed.
{% endif %}

## Required Setup

- Use the local `gh` auth already configured for pushing to `ethereum-optimism/actions`.
- If `gh auth status` fails, stop and record the blocker in the workpad.
- Push branches directly to `origin` (`ethereum-optimism/actions`); never force-push to `main`.
- Codex may mount `.git` read-only. If mutating Git commands fail on `.git/FETCH_HEAD`, use the prepared writable metadata copy:

  ```bash
  GIT_DIR=.git-writable GIT_WORK_TREE=. git fetch origin main
  GIT_DIR=.git-writable GIT_WORK_TREE=. git merge origin/main
  GIT_DIR=.git-writable GIT_WORK_TREE=. git status --short --branch
  ```

GitHub issue state is label-based:

- `agent:todo`
- `agent:in-progress`
- `agent:human-review`
- `agent:rework`
- `agent:merging`
- `agent:done`

## Continuation Checklist

If the issue is already `in-progress`, `rework`, or `merging`, or if this workspace already contains previous work, recover context before changing code:

1. Read the existing `## Codex Workpad` issue comment.
2. Read `logs/agent.md` if present. Start with the latest entries, then search earlier entries for blockers, validation results, branch names, PR URLs, and decisions.
3. Read `logs/agent.ndjson` if `logs/agent.md` is missing or unclear.
4. Inspect the current repository state before syncing or editing:

   ```bash
   GIT_DIR=.git-writable GIT_WORK_TREE=. git status --short --branch
   ```

   If `.git-writable` does not exist, use `git status --short --branch`.

5. Continue from the observed state. Do not repeat completed investigation, installs, validation, pushes, or PR creation unless the logs show the previous result is stale or invalid.

## Workflow

1. Read the issue and current labels.
2. Run the continuation checklist before taking new action when the issue is already active or the workspace has previous logs/work.
3. If state is `todo`, move it to `in-progress`.
4. Find or create one persistent issue comment titled `## Codex Workpad`.
5. Keep all progress, plan, validation, PR URL, blockers, final notes, and the current handoff in that single workpad comment.
   Before ending a turn while the issue remains active, update the handoff with current phase, key decisions, validation completed, and remaining next steps.
6. Sync with `main` before editing:

   ```bash
   git fetch origin main
   git merge origin/main
   ```

7. Create or reuse a branch named `aiur/<issue-number>-short-title`.
8. Implement the smallest correct change for the issue.
9. Run validation appropriate to the changed files. If the issue specifies tests, run those exactly.
10. Commit with a short, concrete message.
11. Push the branch to origin:

    ```bash
    git push -u origin HEAD
    ```

12. Open or update a PR:

    ```bash
    gh pr create \
      --repo ethereum-optimism/actions \
      --base main \
      --title "<issue-number>: <short title>" \
      --body-file /tmp/pr-body.md
    ```

13. Put the PR URL in the workpad.
14. Wait for PR checks/review when useful, but do not merge.
15. Move the issue to `Human Review` only when:
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

Closes/Fixes/Refs ethereum-optimism/actions#{{ issue.identifier }}
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

### Handoff

- Phase: ...
- Decisions: ...
- Completed validation: ...
- Next steps: ...

### Blockers

- <only include real blockers>
````

## Guardrails

- Do not touch repositories outside the workspace.
- Do not merge PRs.
- Do not create extra progress comments.
- Do not mark `Human Review` until a PR exists.
- If blocked by auth, missing secrets, or unclear requirements, update the workpad and leave the issue in `Human Review`.
