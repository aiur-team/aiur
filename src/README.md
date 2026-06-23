# Aiur

Aiur runs autonomous coding agents against the work in your tracker, lands the resulting
PRs, and lets you watch and chat with each agent in real time.

> [!WARNING]
> Aiur is prototype software intended for evaluation only and is presented as-is.

## How it works

1. **Polls a tracker** (Linear, GitHub Issues, or in-memory) for candidate work.
2. **Creates an isolated workspace** per selected item and clones your repo into it.
3. **Launches a coding agent** (Codex or Claude) inside the workspace with your `.aiurconfig`
   YAML config and prompt template.
4. **Drives the run** through repeated turns until the item reaches a terminal state
   (`Done`, `Closed`, `Cancelled`, `Duplicate`), then cleans up the workspace.

**Warm base pre-warm (opt-in).** Instead of every agent cold-cloning and recompiling the
repo, aiur can build one shared, pre-compiled base of latest `main` once and materialize each
workspace from it via copy-on-write. `aiur init` offers to set it up and auto-detects the
build command (Elixir/Node/Go/Rust/Python) so you write no build shell; the base is built
eagerly before the first dispatch (the agent list shows a loading bar) and rebuilt whenever
`main` advances. Unconfigured or undetected repos fall back to the normal cold-clone path.
Enable via the `prewarm:` block in `.aiur/config`.

Aiur ships with a multi-pane CLI that shows every active agent at a glance, lets you open
any agent in an opencode-backed chat pane, and send messages directly into a running
session. A LiveView dashboard at `/` covers the same surface for browser-based operators.

In the CLI agent list, `Enter` opens the selected agent opencode pane and `Space`
pauses or resumes execution for the selected agent. Press `r` to open or close Remote
Control for the selected agent; a 📱 appears next to its identifier while Remote Control
is on, and you continue the session from the Claude app. Remote Control requires a Claude
subscription with remote-control access, works only with local Claude agents, and is
unavailable for Codex or remote-worker agents. Navigate above the first agent row
to focus the active-agent limit, then use `Left` / `Right` to decrease or increase the
session-only maximum. The config file remains unchanged; restarting Aiur reloads the
configured limit.

## Quickstart

```bash
git clone https://github.com/its-everdred/aiur
cd aiur
npm run setup                    # installs the toolchain (mise + erlang/elixir) and symlinks aiurdev
#   (or, if you already have mise:  mise run setup)
cd src && aiurdev init           # scaffolds .aiur/ (config, hooks, prompt.md) in the current repo
# Or copy a starter pair (the config's prompt_file: points at the sibling template):
#   cp examples/workflows/linear-codex.aiurconfig .aiurconfig
#   cp examples/workflows/linear-codex.prompt.md linear-codex.prompt.md
# Edit .aiur/config for your tracker, repo, credentials, and workspace.
aiurdev                          # discovers .aiur/config (or a legacy ./.aiurconfig) automatically
```

`aiurdev` is the local dev build, run from a repo clone; `aiur` is the
npm-installed product command. Both exec the same launcher engine and share one
runtime identity — `aiurdev` only differs by pointing `AIUR_RELEASE_DIR` at the
repo's `_build` release (and rebuilding it when stale). Because they share that
identity, run one at a time, not side by side.

`npm run setup` (or `mise run setup`, or `./scripts/setup` directly) bootstraps the
contributor environment: it installs [mise](https://mise.jdx.dev/) if missing, runs
`mise install` for the pinned toolchain (`mise.toml`), and symlinks `aiurdev` onto
your `PATH`. On first run, the `aiurdev` shim then fetches Hex dependencies,
compiles the Elixir app, and builds the local release; later runs only rebuild when
sources change.

Install [opencode](https://opencode.ai) separately for CLI chat panes. Aiur starts
`opencode serve` lazily per pane and routes its OpenAI-compatible provider calls
back through Aiur on `opencode.bridge_host` / `opencode.bridge_port`.

## Setup wizard (`aiur init`)

`aiur init` is an interactive wizard that scaffolds your config and provisions the
repo. aiur keeps its files in a `.aiur/` folder — `.aiur/config`, `.aiur/hooks`, and
`.aiur/prompt.md`. On a re-run it detects an existing config,
prints your saved selections, and resumes — it never re-asks what you already
answered. If it finds a legacy root-level `.aiurconfig`, it offers to migrate it
into `.aiur/` (settings preserved); a declined migration keeps working unchanged. It
walks:

1. **Where to store config** — repo-local `./.aiur/` or global `~/.aiur/` (and, for
   repo-local, an optional prompt to add `.aiur/` to `.gitignore`).
2. **Tracker** — GitHub or Linear, plus the repo.
3. **Agents & routing** — Claude and/or Codex, optional per-complexity model
   routing, and the permission mode.
4. **Limits** — max concurrent agents, max turns, max duration, pre-warmed
   sessions, and the tracker polling interval.
5. **GitHub token** — used to create labels and act as the bot account. With no
   `GITHUB_TOKEN` yet, the wizard calmly explains the one next step instead of
   failing.
6. **Labels** — creates the lifecycle (`agent:*`), complexity, model, and
   remote-control labels the orchestrator routes on. Each stage creates only the
   labels that are missing; when a group already exists it reports
   `<group> tags: created.` and skips the prompt.

When it finishes, add `agent:todo` to the issues you want worked and run `aiur`.

## Config

The config file (`.aiur/config`, or a legacy root `.aiurconfig`) is pure YAML for
adapters, credentials, and run policy. Optional `prompt_file:` and `hooks_file:` keys
point at sibling files (`prompt.md`, `hooks`), resolved relative to the config's own
directory; when `prompt_file:` is omitted, a built-in default prompt is used.
Discovery precedence: `./.aiur/config` → `./.aiurconfig` → `~/.aiur/config` →
`~/.aiurconfig`. Supported adapters:

- **Trackers**: `linear`, `github`, `memory`
- **Agents**: `codex`, `claude`

Copy one of the starter pairs (config + prompt template) and edit it for your project:

- [examples/workflows/linear-codex.aiurconfig](examples/workflows/linear-codex.aiurconfig)
- [examples/workflows/github-codex.aiurconfig](examples/workflows/github-codex.aiurconfig)
- [examples/workflows/github-claude.aiurconfig](examples/workflows/github-claude.aiurconfig)

If `.aiurconfig` is missing or has invalid YAML at startup, Aiur won't boot. If a later
reload fails, Aiur keeps running with the last known good config and logs the error
until the file is fixed.

## Operating with `aiurdev`

`scripts/aiurdev` is a thin dev shim: it rebuilds the local release when sources
change (running `mix deps.get`, `mix compile`, and `mix release --overwrite` on a
fresh clone), then execs the shared launcher engine
(`packaging/npm/aiur-cli/libexec/aiur-engine.sh`) against `src/_build/dev/rel/aiur`.
The npm-installed `aiur` runs the same engine against the platform release, so every
command below works identically under `aiur`. After `mise run setup`, `aiurdev` is
on your `PATH`:

| Command | What it does |
|---|---|
| `aiurdev` | Start the workflow in the foreground with a local-only bind |
| `aiurdev <path-to-.aiurconfig>` | Run an explicit config in the foreground |
| `aiurdev --bg` | Start in a detached tmux session (background) |
| `aiurdev stop` | Stop the running session (BEAM + tmux) |
| `aiurdev status` | Show active agents and their running/paused/idle state |
| `aiurdev pause <id...>` / `pause --all` | Cooperatively pause agents by issue ID |
| `aiurdev resume <id...>` / `resume --all` | Resume paused agents by issue ID |
| `aiurdev init [--force]` | Scaffold `.aiurconfig` in the current repo |
| `aiurdev build` | Force-rebuild the local release (dev shim only) |

Pause and resume target issue IDs, not process IDs. Space-separated and
comma-separated forms are both accepted:

```bash
aiurdev pause 44
aiurdev pause 44 45 46
aiurdev pause 44,45,46
aiurdev resume 44
aiurdev status
```

Pause is cooperative: the running agent receives the same pause request used by the
dashboard and agent-list pane, then stops at its next safe turn boundary. Pausing an
already-paused agent is a no-op and exits successfully.

By default the engine injects `--host 127.0.0.1` on the run path so the dashboard
stays local. Pass `--host` explicitly to opt out.

Use `--port <N>` before the config path to override the dashboard/workflow port
for one invocation:

```bash
aiurdev --port 4099
aiurdev --port 4099 --bg
aiurdev --port 4102 ./.aiurconfig
```

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
- Optional alert sounds play when an agent gets stuck or needs input. Enable via the
  `alerts:` block in `.aiur/config` (offered during `aiur init`): `enabled` is the master
  switch; `use_os_default_sounds: true` plays built-in macOS/Linux system sounds out of the
  box (macOS via `afplay`, Linux via `paplay`/`canberra-gtk-play`/`aplay`); `sound_dir`
  points at a folder of custom clips that overrides the defaults; `alerts_file` overrides the
  topic→sound mapping (defaults to `alerts.yaml` at the repo root). Playback is fully gated by
  `enabled` and is a no-op when no player binary or sound file is available.

## Testing

```bash
make all
```

`make e2e` runs a live end-to-end test against real Linear + Codex; it creates and tears
down disposable resources and requires `LINEAR_API_KEY`.

## Project layout

- `lib/` — application code
- `test/` — ExUnit suite
- `scripts/aiurdev` — dev shim over the launcher engine (local dev build)
- `examples/workflows/` — starter config + prompt-template pairs
- `.aiurconfig` — the config contract for in-repo runs

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
