# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Creates an isolated workspace for each selected work item
3. Launches the configured implementation backend inside the workspace
4. Sends the workflow prompt to that backend
5. Keeps the run active until the work item reaches a terminal state

During app-server sessions, Symphony can expose adapter-specific tools to repo workflows. For
example, Linear-backed deployments can use the client-side `linear_graphql` tool for raw Linear
GraphQL calls.

If a claimed work item moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active run for that item and cleans up matching workspaces.

## How to use it

1. Make sure your codebase has clear setup instructions, automated validation, and workflow
   conventions that autonomous implementation runs can follow.
2. Configure a tracker adapter. For example:
   - Linear reads a personal API token from `LINEAR_API_KEY` unless `linear.api_key` is set.
   - GitHub Issues reads auth from `GITHUB_TOKEN` and requires `github.repo` in `WORKFLOW.md`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy repo-local workflow skills such as `commit`, `push`, `pull`, and `land`.
   - Linear workflows can also use the `linear` skill, which expects Symphony's `linear_graphql`
     app-server tool for raw Linear GraphQL operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Configure tracker states, labels, prompts, hooks, and backend commands for your project.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/its-everdred/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
cp examples/workflows/linear-codex.md WORKFLOW.md
# Edit WORKFLOW.md for your tracker, repository, credentials, and workspace.
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Operating Symphony with `agents`

`scripts/agents` is a thin wrapper around `./bin/symphony` that adds named
profiles, foreground / background modes, and a `stop` verb. It works on Linux
(systemd `--user`) and macOS (`nohup` + PID file), autodetected from `uname`.

Put `scripts/` on your `PATH` so the command is reachable from anywhere:

```bash
cd symphony
export PATH="$PWD/scripts:$PATH"   # add to ~/.zshrc or ~/.bashrc to persist
agents list
```

The script reads its own location, so no environment variables are required for
a fresh clone — `AGENTS_REPO_ROOT` and `AGENTS_MISE_BIN` remain available as
overrides if your layout differs.

Command surface:

```text
agents                       # default profile, foreground, local-only bind
agents run [profile]         # named profile, foreground
agents --bg [profile|all]    # background mode (systemd on Linux, nohup on macOS)
agents stop [profile|all]    # stop foreground processes and any background service
agents list                  # show configured profiles
agents build                 # rebuild bin/symphony explicitly
agents --host [...]          # bind to the host configured in WORKFLOW.md (e.g. Tailscale IP)
agents <path-to-WORKFLOW.md> # ad-hoc workflow in the foreground
```

`agents` rebuilds `bin/symphony` automatically when it is missing or older
than any source file under `elixir/lib/`, `mix.exs`, or `mix.lock`, so a
`git pull` is all you need before invoking `agents` again.

By default `agents` injects `--host 127.0.0.1` so the Phoenix dashboard is
reachable only on the local machine, even when `WORKFLOW.md` configures a
non-loopback `server.host`. Pass `--host` anywhere in the argument list to
opt out of that injection and let the workflow's `server.host` value take
effect — useful when exposing the dashboard over Tailscale or a LAN.

### Environment variables

When `agents` launches a profile (foreground or background), it sources three
optional files in order — later files override earlier ones, and all of them
are skipped if not present:

1. `~/.config/symphony-dashboard.env` (set `AGENTS_ENV_FILE` to override path)
2. `<repo>/.env`
3. `<repo>/.env.local`

`.env`, `.env.local`, and `.env.*.local` are gitignored at the repo root, so
local secrets stay out of version control.

### Profiles

Define profiles in `~/.config/symphony/agents.profiles`. Each non-comment line
is six pipe-separated fields:

```text
name|symphony_root|workflow|port|logs_root|service
```

Example:

```text
ops|/Users/you/code/ops|WORKFLOW.ops.md|4102|/Users/you/logs/ops|symphony-ops
```

The built-in profiles always loaded are:

- `default` and `symphony` — `local-workflows/WORKFLOW.symphony.local.md`, service `symphony`. Running `agents` with no args dispatches this profile.
- `actions` — `local-workflows/WORKFLOW.actions.local.md`, service `symphony-actions`. Use `agents actions` to foreground this one.

The profile file extends or overrides them. `local-workflows/` is the
machine-local workflow directory (see `elixir/local-workflows/README.md`).

Running `agents` (no args) foregrounds only the `default` profile. Background
services are an explicit opt-in via `agents --bg [profile|all]`; bare `agents`
no longer touches other services. `service` names still dedupe background
work — two profiles sharing a `service` share one background process.

### Platform notes

| | Linux | macOS |
|---|---|---|
| Background driver | `systemctl --user` against a `<service>.service` user unit you maintain | `nohup` + PID file at `~/.local/state/symphony/<service>.pid` |
| Auto-restart on crash | Yes (via systemd unit) | No |
| Auto-start on login | Yes (if the user unit is enabled) | No |
| Stop command | `agents stop` → `systemctl --user stop` + `pkill` cleanup | `agents stop` → `SIGTERM` the PID from the PID file + `pkill` cleanup |

The macOS path is intentionally process-level only — no `launchd` plist
generation, no auto-restart. If you need a service-manager-grade deployment on
macOS, write your own `launchd` plist and use `agents` in the foreground or via
the plist's `ProgramArguments`.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

Optional local alert sounds config:

- Edit `../alerts.yaml`.
- Add URLs or absolute local file paths for the predefined alert names you want to enable.
- Keep the actual audio files outside the repo if you do not want to check them in.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
run prompt. The current implementation supports these adapters:

- Trackers: `linear`, `github`, `memory`
- Implementation backends: `codex`, `claude`

Minimal Linear plus Codex-compatible example:

```md
---
tracker:
  kind: linear
linear:
  api_key: $LINEAR_API_KEY
  project_slug: your-project-slug
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone "$SYMPHONY_REPOSITORY_URL" .
agent:
  kind: codex
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal GitHub Issues plus Claude example:

```md
---
tracker:
  kind: github
  active_states: ["todo", "in-progress"]
  terminal_states: ["done", "closed"]
github:
  repo: your-org/your-repo
  label_prefix: symphony
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone "$SYMPHONY_REPOSITORY_URL" .
agent:
  kind: claude
  max_concurrent_agents: 5
  max_turns: 20
claude:
  command: symphony-claude
---

You are working on a GitHub issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back backend turns Symphony will run in a single
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Keep portable examples free of machine-local hostnames, IPs, usernames, absolute home paths, and
  private repository defaults. Put those deployment-specific values in a copied `WORKFLOW.md` or in
  a clearly labeled file under `local-workflows/`.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.kind` selects the tracker adapter. Linear reads `linear.api_key` from `LINEAR_API_KEY`
  when unset or when value is `$LINEAR_API_KEY`. GitHub reads auth from `GITHUB_TOKEN`.
- `agent.kind` selects the app-server backend. Supported examples include `codex` for a
  Codex-compatible backend and `claude` for a Claude Code app-server command such as
  `symphony-claude`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- Per-agent log modal controls for sending a message to a running agent or pausing it at the next
  turn boundary
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local workflow skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real implementation turn, verifies the workspace side effect, requires the Codex backend to
comment on and close the Linear issue, then marks the project completed so the run remains visible
in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
active implementation runs, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch your configured implementation agent in your repo, give it the path or URL to the Symphony
repo, and ask it to set things up for you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
