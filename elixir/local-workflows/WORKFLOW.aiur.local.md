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
  # 10 minutes per hook. Observed: cold clone + mise install + mix
  # deps.get + mix compile takes ~3:30 on a warm machine, longer on
  # a cold one. The previous 60s default silently killed every hook
  # at the deps.get step (output is swallowed by `>/dev/null 2>&1`),
  # so every agent paid 3-4 min for `mix deps.get` on first
  # productive turn instead of starting with warm caches.
  timeout_ms: 600000
  after_create: |
    git clone https://github.com/its-everdred/aiur.git .
    issue_id="$(basename "$PWD")"
    # Branch off the operator's current working branch instead of
    # `origin/main` so agent workspaces include the in-flight fixes
    # the operator has committed but not yet merged — specifically
    # the agent-workspace guards in scripts/aiur and
    # Aiur.TestReset.run/1. Without this, agents that recursively
    # invoke `./scripts/aiur --test` from inside the workspace bypass
    # both guards (the workspace ships a pre-guard snapshot from
    # main) and wipe the operator's sandbox tickets mid-run. Branch
    # name lives here so a workflow-only edit can re-target the
    # source once the fixes land on main.
    git fetch origin kevin/e2e-pubsub-test >/dev/null 2>&1 || true
    base_ref="$(git rev-parse --verify origin/kevin/e2e-pubsub-test 2>/dev/null || echo origin/main)"
    git checkout -b "aiur/${issue_id}" "$base_ref"
    mkdir -p ./.aiur-hex ./.aiur-mix
    if [ -f elixir/mise.toml ]; then
      mise trust elixir/mise.toml >/dev/null 2>&1 || true
      mise install >/dev/null 2>&1 || true
    fi
    # Warm Hex + dep compile caches so the agent's first `mix` call
    # doesn't waste 30-60s on cold deps.get + first-time-compile.
    # Failures are non-fatal: if the workspace can't fetch deps now
    # (network blip, dep change), the agent's first `mix deps.get`
    # will pick it up.
    if [ -f elixir/mix.exs ]; then
      # Output flows back to Workspace.run_hook via System.cmd
      # (stderr_to_stdout: true). Don't redirect to /dev/null — that
      # masks silent failures where mix exits cleanly but didn't
      # actually fetch deps (e.g. mise exec failing, hex install
      # erroring). The Elixir side logs a tail of the output on
      # success and the full output on non-zero exit. `|| true` is
      # retained so the hook is non-fatal for the agent boot path:
      # if deps prefetch fails, the agent picks it up on first
      # `mix` call, just slower.
      HEX_HOME="$PWD/.aiur-hex" MIX_HOME="$PWD/.aiur-mix" \
        MISE_TRUSTED_CONFIG_PATHS="$PWD/elixir/mise.toml" \
        bash -c 'cd elixir && mise exec -- mix local.hex --force --if-missing && mise exec -- mix local.rebar --force --if-missing && mise exec -- mix deps.get && mise exec -- mix compile' \
        2>&1 | tail -200 || true
    fi
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
      mise install >/dev/null 2>&1 || true
    fi
    # Idempotent deps + compile warm-up on every dispatch. Free when the
    # cache is warm (mix deps.get + mix compile no-op in seconds); pays
    # off when the workspace is a fresh clone, an aiur --debug resume
    # against an existing dir, or after a deps lockfile bump.
    if [ -f elixir/mix.exs ]; then
      # Output flows back to Workspace.run_hook via System.cmd
      # (stderr_to_stdout: true). Don't redirect to /dev/null — that
      # masks silent failures where mix exits cleanly but didn't
      # actually fetch deps (e.g. mise exec failing, hex install
      # erroring). The Elixir side logs a tail of the output on
      # success and the full output on non-zero exit. `|| true` is
      # retained so the hook is non-fatal for the agent boot path:
      # if deps prefetch fails, the agent picks it up on first
      # `mix` call, just slower.
      HEX_HOME="$PWD/.aiur-hex" MIX_HOME="$PWD/.aiur-mix" \
        MISE_TRUSTED_CONFIG_PATHS="$PWD/elixir/mise.toml" \
        bash -c 'cd elixir && mise exec -- mix local.hex --force --if-missing && mise exec -- mix local.rebar --force --if-missing && mise exec -- mix deps.get && mise exec -- mix compile' \
        2>&1 | tail -200 || true
    fi
  before_remove: |
    git status --short
agent:
  kind: codex
  max_concurrent_agents: 6
  max_turns: 12
  # Per-issue backend routing by `complexity:N` label. Unlisted levels and
  # unlabeled issues fall back to `kind`. A `model:<backend>` issue label
  # overrides both. Levels 4 and 5 route to Claude for stronger reasoning.
  routing:
    4: claude
    5: claude
claude:
  command: aiur-claude
  version: opus-4-8
  # `model` is omitted so the app-server / claude CLI uses its own default
  # model. Set it (e.g. model: claude-sonnet-4-6) to pin turns to a
  # specific model; the value is sent verbatim as `claude --model <value>`.
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /home/applekid/code/aiur-workspaces
      - /home/orangekid/code/aiur-workspaces
      - /tmp
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
- Work in the current workspace checkout. The `.git` directory IS writable here — do NOT copy it to `.git-writable` (that's a pattern from the GitHub Actions workflow, not this one). Use `git` directly with no `GIT_DIR=...` prefix.
- `mise exec -- mix` and `mise exec -- rg` work out of the box — `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` are pre-set per workspace and `mise trust` has already been run on the workspace `elixir/mise.toml`. Do not redeclare these env vars on individual commands.
- For module-only verification (pure function calls, no app supervision needed), use `mix run --no-start -e ...`. Plain `mix run -e ...` tries to start the full Aiur application and fails in agent workspaces (no local `WORKFLOW.md`).
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
