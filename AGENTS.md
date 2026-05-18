# Operating Notes

Context for engineers and coding agents working in this repository. Setup
lives in [`elixir/README.md`](elixir/README.md); this file captures the
operational practices that aren't in the main README.

## Layout

- `elixir/WORKFLOW.md` — generic template. Customize it for the project you
  point Aiur at.
- `elixir/examples/workflows/` — portable example workflows (Linear+Codex,
  GitHub+Codex, GitHub+Claude). Copy one when starting fresh.
- `elixir/local-workflows/` — machine-local operational workflows that are
  checked in but are **not** portable defaults. Used by the built-in `aiur`
  profiles.
- `scripts/aiur` — thin wrapper around `bin/aiur`. Auto-detects OS
  (systemd on Linux, `nohup`+PID on macOS) and rebuilds the escript when
  sources are newer than the binary. See the README for the command surface.

## Running

`aiur` is the entry point for everything. Don't `mise exec -- mix …` by
hand unless something is broken.

```text
aiur                       # default profile, foreground, local-only bind
aiur <profile>             # named profile, foreground
aiur --bg [profile|all]    # background mode
aiur stop [profile|all]    # stop tracked services + foreground processes
aiur build                 # explicit rebuild of bin/aiur
aiur --host …              # opt out of the local-only --host injection
```

`aiur` injects `--host 127.0.0.1` unless you pass `--host` somewhere in
the args. Pass `--host` when you want to expose the dashboard over the
network (e.g. Tailscale, LAN).

## Per-issue workspaces

Each issue gets an isolated workspace at:

```text
<workspace.root>/<issue-id>/
```

where `workspace.root` is the value from the active workflow. Two log files
are written inside each workspace:

- `logs/agent.md` — human-readable chat-style log
- `logs/agent.ndjson` — newline-delimited JSON event stream

When resuming an issue that was already in progress, inspect both logs and
the workpad comment on the issue before changing code. Don't repeat work
the previous run already finished.

## Tracker label slugs

The GitHub tracker emits states as label slugs (`todo`, `in-progress`,
`human-review`, `rework`, `merging`, `done`), not their display names.
Configuring `active_states:` with display names (`"In Progress"`) makes
Aiur treat the issue as non-active and stop the worker. Always use the
slug form in workflow YAML.

## Workflow bootstrap and `.git-writable`

Workflow `after_create` and `before_run` hooks bootstrap the issue
workspace. Two practices that matter:

- **Guard `before_run`** so it reclones only when the workspace is not a
  valid git worktree. Without the guard, every retry wipes the workspace.
- **Prepare `.git-writable`** alongside `.git` so Codex's read-only `.git`
  mount has a writable copy of `FETCH_HEAD` etc. for `git fetch` /
  `git merge` to succeed. See the existing local workflows for the pattern.

Prefer HTTPS remotes over SSH for workflow git operations — SSH agent
forwarding is fragile under service-account contexts and `gh auth setup-git`
makes HTTPS Just Work.

## Auth

The dashboard reads `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`
from the environment. Set them empty (or unset) to disable basic auth
locally. Source these from a gitignored file — `.env`, `.env.local`, or
`~/.config/aiur-dashboard.env` are all loaded automatically by
`scripts/aiur` if present.

GitHub tracker auth uses `GITHUB_TOKEN` for polling and `gh auth setup-git`
for git pushes/PRs. Verify with `gh auth status` in the same shell that
will run the agent.

## Compound Engineering

Repo-local CE settings live at `.compound-engineering/config.local.yaml`
(gitignored). The committed example is `config.local.example.yaml`. Run
`/ce-setup` to install the supporting CLI tools and skills.

## Local notes

`AGENTS.local.md` is gitignored. Use it for per-machine runbook notes,
operational reminders, secrets-adjacent shorthand — anything that shouldn't
be in version control.

Do not commit:

- secrets, tokens, or basic-auth credentials
- per-machine paths, Tailscale IPs, or hostnames in this file
- credentials embedded in YAML or log output

## Sibling: `aiur-claude`

Claude support is provided by a sibling repository (a Node-based JSON-RPC
2.0 app server that adapts Claude Code to the Codex app-server protocol).
Auth is via the Claude CLI (`claude auth`), not an API key. See that repo's
README for setup details.
