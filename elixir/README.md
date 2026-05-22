# Aiur

Aiur runs autonomous coding agents against the work in your tracker, lands the resulting
PRs, and lets you watch and chat with each agent in real time.

> [!WARNING]
> Aiur is prototype software intended for evaluation only and is presented as-is.

## How it works

1. **Polls a tracker** (Linear, GitHub Issues, or in-memory) for candidate work.
2. **Creates an isolated workspace** per selected item and clones your repo into it.
3. **Launches a coding agent** (Codex or Claude) inside the workspace with your `WORKFLOW.md`
   prompt and YAML config.
4. **Drives the run** through repeated turns until the item reaches a terminal state
   (`Done`, `Closed`, `Cancelled`, `Duplicate`), then cleans up the workspace.

Aiur ships with a multi-pane CLI that shows every active agent at a glance, lets you open
any agent in an opencode-backed chat pane, and send messages directly into a running
session. A LiveView dashboard at `/` covers the same surface for browser-based operators.

In the CLI agent list, `Enter` opens the selected agent opencode pane and `Space`
pauses or resumes execution for the selected agent. Navigate above the first agent row
to focus the active-agent limit, then use `Left` / `Right` to decrease or increase the
session-only maximum. The workflow file remains unchanged; restarting Aiur reloads the
configured limit.

## Quickstart

```bash
git clone https://github.com/its-everdred/aiur
cd aiur
mise install
cp elixir/examples/workflows/linear-codex.md elixir/WORKFLOW.md
# Edit elixir/WORKFLOW.md for your tracker, repo, credentials, and workspace.
export PATH="$PWD/scripts:$PATH"
aiur ./WORKFLOW.md
```

[mise](https://mise.jdx.dev/) is the recommended runtime manager — `mise.toml` pins
versions for you. On first run, the `aiur` wrapper fetches Hex dependencies,
compiles the Elixir app, and builds `bin/aiur`; later runs only rebuild when
sources change.

Install [opencode](https://opencode.ai) separately for CLI chat panes. Aiur starts
`opencode serve` lazily per pane and routes its OpenAI-compatible provider calls
back through Aiur on `opencode.bridge_host` / `opencode.bridge_port`.

## Workflows

A `WORKFLOW.md` file has YAML front matter for adapters, credentials, and run policy,
plus a Markdown body used as the prompt template. Supported adapters:

- **Trackers**: `linear`, `github`, `memory`
- **Agents**: `codex`, `claude`

Copy one of the starter workflows and edit it for your project:

- [examples/workflows/linear-codex.md](examples/workflows/linear-codex.md)
- [examples/workflows/github-codex.md](examples/workflows/github-codex.md)
- [examples/workflows/github-claude.md](examples/workflows/github-claude.md)

If `WORKFLOW.md` is missing or has invalid YAML at startup, Aiur won't boot. If a later
reload fails, Aiur keeps running with the last known good workflow and logs the error
until the file is fixed.

## Operating with `aiur`

`scripts/aiur` wraps `./bin/aiur` with named profiles, foreground/background modes, and
a `stop` verb. It autodetects Linux (systemd `--user`) vs macOS (`nohup` + PID file).
On a fresh clone it also runs `mix deps.get`, `mix compile`, and `mix escript.build`
before launching Aiur.
Put `scripts/` on your `PATH`:

```bash
export PATH="$PWD/scripts:$PATH"
aiur list
```

| Command | What it does |
|---|---|
| `aiur` | Attach to the default profile's existing tmux session, or start it in the foreground with a local-only bind |
| `aiur <profile>` | Attach to the profile's existing tmux session, or start it in the foreground |
| `aiur --fresh [profile]` | Start a fresh foreground session even when a tmux session already exists |
| `aiur run <profile>` | Named profile, fresh foreground session |
| `aiur --bg [profile\|all]` | Background mode |
| `aiur stop [profile\|all]` | Stop foreground processes and background services |
| `aiur list` | Show configured profiles |
| `aiur build` | Rebuild `bin/aiur` |
| `aiur <path-to-WORKFLOW.md>` | Ad-hoc workflow |

Profiles live at `~/.config/aiur/aiur.profiles` (six pipe-separated fields per line:
`name|root|workflow|port|logs_root|service`). Environment overrides come from
`~/.config/aiur-dashboard.env`, `.env`, and `.env.local` in that order. `.env*` are
gitignored at the repo root.

By default `aiur` injects `--host 127.0.0.1` so the dashboard stays local. Pass `--host`
explicitly to opt out.

Use `--port <N>` before the command/profile name to override the configured profile or
workflow port for one invocation:

```bash
aiur --port 4099
aiur --port 4099 --bg
aiur --port 4102 actions
```

When no `--port` override is present and the configured port is busy, the wrapper tries
the next 9 ports and prints the selected port. If none are free, a fast startup crash is
replayed in the host shell with the last pane output and a port-collision hint.

## Dashboard

When `server.port` (or CLI `--port`) is set, Aiur exposes:

- LiveView dashboard at `/` — active agents, logs, per-agent chat modal
- JSON API under `/api/v1/*` for operational debugging

## Configuration notes

- Path values support `~` for the home directory and `$VAR` for environment substitution.
- Codex defaults to safer policies when omitted (`approval_policy` rejects unprompted
  approvals, `thread_sandbox` is `workspace-write`).
- `agent.max_turns` caps how many back-to-back backend turns Aiur runs in a single
  invocation when a turn completes but the issue is still active. Default: `20`.
- `agent.max_concurrent_agents` caps active workers only. Paused agents remain visible
  and can keep their panes open without consuming an active slot.
- Use `hooks.after_create` to bootstrap a fresh workspace (typically a `git clone`).
- Set `workspace.bootstrap_image` to a prebuilt Aiur image to seed missing `deps/`
  and `_build/` directories from the image after `hooks.before_run` completes. Set
  `workspace.bootstrap_image_pull: true` when using a mutable tag such as `latest`.
- Optional local alert sounds: see `alerts.yaml` at the repo root.

## Testing

```bash
make all
```

`make e2e` runs a live end-to-end test against real Linear + Codex; it creates and tears
down disposable resources and requires `LINEAR_API_KEY`.

## Project layout

- `lib/` — application code
- `test/` — ExUnit suite
- `scripts/aiur` — operator wrapper
- `examples/workflows/` — starter workflow files
- `WORKFLOW.md` — local workflow contract for in-repo runs

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
