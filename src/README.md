# Aiur

Aiur runs autonomous coding agents against the work in your tracker, lands the resulting
PRs, and lets you watch and chat with each agent in real time.

> [!WARNING]
> Aiur is prototype software intended for evaluation only and is presented as-is.

## Who operates a run

Every run has an **Executor**: the operator of the run. That is either **you**, driving the
CLI directly, or **your coding agent**, operating Aiur on your behalf while you stay in
conversation with it. Both are first-class.

The control surface below — `message`, `pause`, `resume`, `watch --changes --interval`, the
machine-token Supervisor Decision API — is usable by a human at a terminal or by a
programmatic operator. Nothing here assumes a human is the one typing.

If you want your agent to be the Executor, ask it to "run aiur"; the repository bundles
[`aiur-run`](../.claude/skills/aiur-run/SKILL.md) and
[`aiur-monitor`](../.claude/skills/aiur-monitor/SKILL.md) for exactly that, and
[`aiur-intro`](../.claude/skills/aiur-intro/SKILL.md) to help you choose. See
[README § Who drives Aiur?](../README.md#who-drives-aiur) for the fuller picture.

## How it works

1. **Polls a tracker** (Linear, GitHub Issues, or in-memory) for candidate work.
2. **Creates an isolated workspace** per selected item and clones your repo into it.
3. **Launches a coding agent** (Codex or Claude) inside the workspace with your `.aiur/config`
   YAML config and prompt template.
4. **Drives the run** through repeated turns until the item reaches a terminal state
   (`Done`, `Closed`, `Cancelled`, `Duplicate`), then cleans up the workspace.

**Warm base pre-warm (opt-in).** Instead of every agent cold-cloning and recompiling the
repo, aiur can build one shared, pre-compiled base of latest `main` once and materialize each
workspace from it via copy-on-write. `aiur init` offers to set it up and auto-detects the
build command (Elixir/Node/Go/Rust/Python) so you write no build shell. Once you accept the
detected or edited command, init starts the one-time build immediately before continuing with
alert and scaffolding prompts. The base is ready before the first dispatch (the agent list shows
a loading bar) and rebuilt whenever `main` advances. Unconfigured or undetected repos fall back
to the normal cold-clone path.
Enable via the `prewarm:` block in `.aiur/config`.

**Bootstrap image cache seeding (opt-in).** Repos can also publish a warm Docker image and set
`workspace.bootstrap_image` to seed missing build caches into a checkout after `before_run`.
Aiur mounts the workspace at `/workspace`, copies cache directories such as `src/deps` and
`src/_build` from `/opt/aiur` when they are absent, and leaves existing caches untouched. The
image seeds the workspace only; agents and opencode still run on the host.

Aiur ships with a multi-pane CLI that shows every active agent at a glance, lets you open
any agent in an opencode-backed chat pane, and send messages directly into a running
session. A LiveView dashboard at `/` mirrors this surface read-only for browser-based Executors;
messaging and pausing agents stays in the CLI until a dashboard parity pass (set
`observability.dashboard_writable: true` to re-enable the browser write controls early).

In the CLI agent list, `Enter` opens the selected agent opencode pane and `Space`
pauses or resumes execution for the selected agent. Press `r` to open or close Remote
Control for the selected agent; a 📱 appears next to its identifier while Remote Control
is on, and you continue the session from the Claude app. Remote Control requires a Claude
subscription with remote-control access, works only with local Claude agents, and is
unavailable for Codex or remote-worker agents. Navigate above the first agent row
to focus the active-agent limit, then use `Left` / `Right` to decrease or increase the
session-only maximum. The config file remains unchanged; restarting Aiur reloads the
configured limit.

## Inspecting Build Orders

`aiur build-orders` prints the repository-scoped Build Order catalog with the
captured-source freshness. Pass a root identifier to inspect its members,
completion state, and directed dependency edges; `--json` returns the same read
as a versioned JSON envelope. Unknown completion remains `unresolved` rather
than being reported as zero.

```bash
aiur build-orders
aiur build-orders 1363 --json
```

On the dashboard, a selected root whose planning provider is unavailable or
whose fetched graph fails structural validation shows one page-level diagnostic
state, including a copyable agent debug prompt. Valid graphs, stale
last-known-good graphs, and valid empty graphs keep their normal selected-root
views.

## Quickstart

```bash
git clone https://github.com/aiur-team/aiur
cd aiur
npm run setup                    # installs the toolchain (mise + erlang/elixir) and symlinks aiurdev
#   (or, if you already have mise:  mise run setup)
cd src && aiurdev init           # scaffolds .aiur/ (config, hooks, prompt.md) in the current repo
# Or copy a starter pair (the config's prompt_file: points at the sibling template):
#   mkdir -p .aiur
#   cp examples/workflows/linear-codex.yaml .aiur/config
#   cp examples/workflows/linear-codex.prompt.md .aiur/linear-codex.prompt.md
# Edit .aiur/config for your tracker, repo, credentials, and workspace.
aiurdev                          # discovers .aiur/config automatically
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
back through Aiur on `opencode.bridge_host` / `opencode.bridge_port`. When
`opencode.bridge_port` and `AIUR_OPENCODE_BRIDGE_PORT` are unset, Aiur uses
`4097` if available and otherwise selects a nearby free local port; explicit
config or env ports are honored as pins.

## Setup wizard (`aiur init`)

`aiur init` is an interactive wizard that scaffolds your config and provisions the
repo. aiur keeps its files in a `.aiur/` folder — `.aiur/config`, `.aiur/hooks`, and
`.aiur/prompt.md`. On a re-run it detects an existing config,
prints your saved selections, and resumes — it never re-asks what you already
answered. It walks:

1. **Where to store config** — repo-local `./.aiur/` or global `~/.aiur/` (and, for
   repo-local, an optional prompt to add `.aiur/` to `.gitignore`).
2. **Tracker** — GitHub or Linear, plus the repo.
3. **Agents & routing** — Claude and/or Codex, optional per-complexity model
   routing, the permission mode, and an optional ordered rate-limit fallback.
4. **Limits** — max concurrent agents, max turns, max duration, pre-warmed
   sessions, and the tracker polling interval. The same polling interval is the
   debounce before Aiur raises a sustained fleet-capacity starvation alert.
5. **GitHub token** — used to create labels and act as the bot account. With no
   `GITHUB_TOKEN` yet, the wizard calmly explains the one next step instead of
   failing.
6. **CI readiness** — for GitHub repositories, verifies the configured base
   branch exists, a pull-request workflow targets it, branch protection or an
   applicable ruleset requires a check, and that a workflow produces that check.
   A gap stops setup with a clear error; when no pull-request workflow exists,
   the wizard offers a minimal `ci.yml` scaffold with a stable aggregator check
   name (`ci / required`).
7. **Labels** — creates the lifecycle (`agent:*`), pause/watch marker,
   complexity, model, and remote-control labels the orchestrator routes on.
   Each stage creates only the labels that are missing; when a group already exists it reports
   `<group> tags: created.` and skips the prompt.

When it finishes, add `agent:todo` to the issues you want worked and run `aiur`.
Add `agent:paused` alongside an existing `agent:*` state when you want Aiur to
skip or park that issue without losing the preserved state; remove only
`agent:paused` to resume normal behavior.

## Config

The config file (`.aiur/config`) is pure YAML for
adapters, credentials, and run policy. Optional `prompt_file:` and `hooks_file:` keys
point at sibling files (`prompt.md`, `hooks`), resolved relative to the config's own
directory; when `prompt_file:` is omitted, a built-in default prompt is used.
Discovery precedence: `./.aiur/config` → `~/.aiur/config`. If a legacy
`.aiurconfig` exists without the corresponding canonical config, Aiur refuses
to start and names the destination path instead of silently using defaults.
When moving a legacy config manually, also move referenced prompt or hooks files,
or rewrite their relative paths so they still resolve from the new config directory.
Supported adapters:

- **Trackers**: `linear`, `github`, `memory`
- **Agents**: `codex`, `claude`

For GitHub trackers, `github.trusted_accounts` can name Executor accounts whose
comments should reach agent event digests even when CODEOWNERS team expansion is
unavailable. Keep it separate from `github.bot_account`: bot-account authors are
filtered as self-loops, while trusted accounts are allowed human Executors.
`github.human_mergers` is a separate, explicit human-only allowlist used for
post-merge attribution. It never inherits CODEOWNERS, bot accounts, trusted
accounts, or dispatch `allowed_users`; an absent list treats every merger as
unallowlisted and raises a needs-attention alert without undoing terminal state.

Build Order planning reads use finite `github.planning_root_limit`,
`github.planning_page_budget`, and `github.planning_call_budget` safeguards.
They default to `100`, `4`, and `4`; all values must be positive and may not
exceed those hard limits, so a provider generation never silently truncates.

For local planning packs, the supervised PackStatus poller writes tracker
lifecycle facts to the sibling `status.json` projection in batches of 50
tickets. The projection survives run boundaries; failed or incomplete tracker
reads retain the last-known-good file and mark Build Order health stale or
unavailable until a later refresh succeeds.

The optional root-level `build_order` section configures three supervised,
in-memory configured-repository stores. Ticket detail retains 32 identities and
16,384 sanitized description bytes. Its freshness window is derived from
`polling.interval_seconds` (a quarter of it, floored at 5 seconds, so 30 seconds
at the default 120-second poll) rather than fixed, because Build Order shows
state the tracker produces and cannot be fresher than the tracker's own cycle.
It is not a cadence — nothing fires on it. It is the staleness a ticket-detail
reader accepts from the shared store before revalidating.
`ticket_detail_freshness_ms` accepts `1..300000`,
`ticket_detail_max_entries` accepts `1..100`, and
`ticket_detail_max_description_bytes` accepts `1..16384`.

Recent ticket history retains only allowlisted, sanitized event metadata from
the typed IssueLog and Exchange seams; it never stores agent transcripts or
workspace paths. `ticket_history_limit` defaults to `50` and accepts `1..100`;
`ticket_history_max_identities` defaults to `100` and accepts `1..100`; and
`ticket_history_stale_after_ms` defaults to `60000` and accepts `1..300000`.
History snapshots are in-memory and restart as unavailable until fresh typed
evidence is observed.

The planning graph projection owns provider polling independently of connected
browsers. Its public settings and inclusive bounds are:

Three settings have no fixed default: the two catalog cadences below, plus the
`ticket_detail_freshness_ms` window described above. They are derived from
`polling.interval_seconds` — see `Aiur.BuildOrder.Cadence` — and an explicit
value overrides the derivation. Fixed constants are what let the previous
defaults, chosen for a 5-second tracker poll, survive the move to 120 seconds.

- `graph_catalog_refresh_ms`: derived at 1x the poll interval, range `1..3600000`.
  This is daemon-owned catalog reconciliation — it runs whether or not anyone is
  watching, and it is what notices a root appearing or changing.
- `graph_catalog_labels_refresh_ms`: derived at 5x the poll interval with a
  600000 floor, never below `graph_catalog_refresh_ms`, range `1..3600000`.
  Epic and wave counts are label-derived, and the per-member label read costs
  roughly 26 GraphQL points against the 5000-points/hour budget versus 1
  without it, so it runs on this slower cadence. Resolved counts carry forward
  across the cheaper polls only while a root is provably unchanged.

`graph_selected_refresh_ms` and `graph_demand_refresh_ms` are gone — deleted from
the config schema, not retuned. They were the two settings by which *viewing*
bought GitHub reads: `graph_demand_refresh_ms` fired when an operator selected a
root, and `graph_selected_refresh_ms` repeated for as long as the page stayed
open. No value makes that correct, because it makes API cost track who is looking
rather than what changed. A selected root is now read only when a writer — a
webhook, an agent mutation, or the daemon's catalog reconciliation — or an
explicit `Aiur.BuildOrder.GraphProjection.refresh/2` asks for it, so opening the
Build Order page, selecting a root, and holding it open cost zero GitHub reads. A
configuration that still sets either key keeps loading: the schema ignores keys
outside its permitted list, so an upgrade yields the new behaviour rather than a
boot failure.

No GraphQL read behind Build Order can be revalidated: GitHub's GraphQL API
returns no `ETag`, so `AiurBuildOrderCatalog`, `AiurBuildOrderSelectedRoot` and
`AiurLinkedPullRequests` can never answer `304`, and cadence and connection size
are their only cost controls. The REST ticket-detail read is conditional and goes
through `Aiur.GitHub.ResourceStore`, so an unchanged refresh costs no primary
rate limit and a ticket the tracker poll already fetched costs nothing at all.

The remaining graph settings keep fixed defaults:

- `graph_refresh_timeout_ms`: default `30000`, range `1..120000`.
- `graph_max_selected_roots`: default `32`, range `1..100` retained
  last-known-good roots.
- `graph_max_inflight`: default `4`, range `1..16` provider refreshes shared by
  all consumers.

Restarting Aiur clears ticket detail and every catalog or selected-root graph
generation. Each store reports unavailable after restart until a new complete
provider read succeeds; no stale graph generation is reconstructed or exposed
as an empty graph.

Copy one of the starter pairs (config + prompt template) and edit it for your project:

- [examples/workflows/linear-codex.yaml](examples/workflows/linear-codex.yaml)
- [examples/workflows/github-codex.yaml](examples/workflows/github-codex.yaml)
- [examples/workflows/github-claude.yaml](examples/workflows/github-claude.yaml)

If `.aiur/config` is missing or has invalid YAML at startup, Aiur won't boot. If a later
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
| `aiurdev <config-path>` | Run an explicit YAML config in the foreground |
| `aiurdev --test` | Reset the first pinned sandbox ticket, then start an interactive smoke run |
| `aiurdev --test3` | Reset the pinned 3-ticket blocker-chain sandbox, then start an interactive smoke run |
| `aiurdev --bg` | Start a detached headless BEAM with the web dashboard enabled |
| `aiurdev --bg --no-dashboard` | Start a lean detached headless BEAM without the web dashboard |
| `aiurdev --no-dashboard` | Start the foreground terminal UI without the web dashboard |
| `aiurdev stop` | Stop the running session (BEAM + tmux) |
| `aiurdev restart [--no-build]` | Stop the session, rebuild the release when sources are newer, then start again detached; `--no-build` bounces on the release already on disk |
| `aiurdev status` | Show active agents and their running/paused/idle state, GitHub CI readiness, and `SUPERVISION N/N` liveness; a degraded or unavailable supervision tree returns nonzero |
| `aiurdev executor-answer <decision-id> --expected-version <n> (--option <id>\|--custom-response <text>) --rationale <text> --idempotency-key <key> [--executor-id <id>]` | Record a direct Command answer with an explicit Executor actor; version and idempotency fields make listener replay safe |
| `aiurdev executor-escalate <decision-id> --expected-version <n> --reason <text> [--executor-id <id>]` | Leave a Command open and raise one keyed operator notification when Executor judgment is insufficient |
| `aiurdev units [--scope live\|unfinished\|all\|none] [--condition active\|alert\|paused\|queued\|finished]... [--format auto\|table\|records] [--json]` | Render the dashboard's Units ticket view, including its filters and source freshness; `--format` picks the human layout (`auto` uses a table only on a wide terminal); `--json` emits the stable envelope |
| `aiurdev analytics [--range run\|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]` | Render the Analytics dashboard snapshot for an explicit chart window |
| `aiurdev pause <id...>` / `pause --all` | Cooperatively pause agents by issue ID |
| `aiurdev resume <id...>` / `resume --all` | Resume paused agents by issue ID |
| `aiurdev reset-budget <id...>` | Queue lifetime dispatch-latch resets; completion or failure is reported in alerts |
| `aiurdev --todo <id...> [--only]` | Queue GitHub tickets; with `--only`, dequeue all other pending tickets |
| `aiurdev init [--force]` | Scaffold `.aiur/config` in the current repo |
| `aiurdev build` | Force-rebuild the local release (dev shim only) |

Pure control commands (`agents`, `status`, `set`, `pause`, `resume`, `message`, `units`,
and `stop`) reuse the existing dev release when it is complete, even if sources
are newer. They control the already-running node, so a stale-source rebuild would
not update that session. Run/start paths and explicit `aiurdev build` still
rebuild when needed. `restart` reuses the existing release for that pre-dispatch
step too, but for the opposite reason: it rebuilds between its own stop and
start, so rebuilding first would rewrite the release under the still-live BEAM.

`--todo` is a standalone GitHub operation and does not require a running Aiur
session. It derives labels from the current config. `--only` removes the queue
label from other pending tickets but leaves in-progress work untouched.
Concurrent `--only` invocations are not coordinated across processes; running
two overlapping `aiurdev --todo ... --only` commands can drop each other's
tickets, so avoid running them at the same time.

If a control command times out while the daemon is still live, the outcome is
unknown. Check the daemon state before retrying or taking destructive action;
the CLI does not infer a cause or recommend restarting the whole session. It
does print what it can observe without the daemon cooperating — the
orchestrator's mailbox depth, run status and current function — because a large
mailbox or a blocked current function means one process is stuck, not that the
host is busy.

`resume` on a paused agent never claims an outcome it has not observed. The
orchestrator answers as soon as the resume control request is queued for the
agent, so the CLI then waits for that agent to actually leave the paused state
before printing `aiur: resumed #44`. Every resume in one invocation shares a
single 4s confirmation budget, so `resume --all` stays inside the control-RPC
timeout. A worker refusal is reported as `declined` with the held pause
condition; a lifecycle expiry is reported as `dropped` with its reason. If the
request is still pending at the confirmation deadline, or the correlated
outcome cannot be determined, the CLI says the outcome is unknown. Every
unapplied path exits 1, and the same declined/dropped reason remains visible on
the dashboard's paused row.

Read-only fleet queries never use an empty buffer to mean success: `status`,
`agents`, and `watch` print an affirmative empty-fleet row when no agents are
active. Query failures print one stderr diagnostic and exit 1. Bounded query
timeouts name their budget, report that the outcome is unknown, and print the observed orchestrator mailbox and current function rather than guessing a cause,
and exit 124; any partial fleet output captured before an outer RPC timeout is
discarded rather than presented as a trustworthy snapshot.

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

For tracker-level shelving, apply `agent:paused` in GitHub instead of changing
the issue state. Aiur will not claim a paused `agent:todo` ticket, will
cooperatively pause a running ticket when the label appears, and `aiurdev watch`
shows the override as `paused`.

`aiurdev resume <id>` removes `agent:paused` from the tracker before it resumes
or starts the local agent. If the tracker refuses that removal, the command exits
non-zero and explains that the resume will not hold; it does not report a plain
success. A fleet-wide `aiurdev resume` still preserves per-ticket pause labels.

When `server.host` is absent, the engine supplies a lower-precedence dashboard
default: an authenticated Tailscale IPv4 when available, otherwise `127.0.0.1`.
Configured `server.host` wins over that default, and explicit `--host` wins over
both. Startup output reports the usable URL and effective bind host and port.

Background mode is headless at the terminal layer: it skips the interactive
agent-list and chat/prewarm panes while serving the web dashboard at the
configured host and port. Detachment and dashboard availability are independent:
add `--no-dashboard` for the lean background shape, or use `--no-dashboard` in
foreground mode to keep the terminal UI without an HTTP listener. The launcher
still uses one detached tmux session to own the BEAM lifetime and cleanup
watchdog. If that session is already live, `aiurdev --bg` exits successfully
with an "already running" hint; if the tmux session is stale and the control RPC
is down, the launcher cleans it up before starting a fresh background run.

Claude Remote Control lifecycle hooks post to `Aiur.HttpServer`, so a
no-listener run cannot support configured Remote Control. Startup fails with a
clear error when `--no-dashboard` is combined with `agent.remote_control: true`
or an `agent.routing` value ending in `+remote`; remove the flag or disable that
Remote Control configuration. Runtime `model:remote` dispatch and live
promotion also fail fast if no listener is actually bound. Background startup
prints the confirmed bound URL or an explicit listener-unavailable warning.

Non-loopback dashboard binds retain the authentication guard: set both
`AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`, or Aiur refuses the
dashboard bind while leaving the agent runtime available.

Use `--port <N>` before the config path to override the dashboard/workflow port
for one invocation:

```bash
aiurdev --port 4099
aiurdev --port 4099 --bg
aiurdev --port 4099 --bg --no-dashboard
aiurdev --port 4102 ./.aiur/config
```

The `--test` and `--test3` reset paths require their pinned sandbox issues to
be open before launch. If a pinned issue is closed, reset removes any detected
`agent:*` or `model:*` labels from that closed issue, skips normal dispatch
labeling, and aborts with instructions to reopen the ticket or update
`.aiur-test-tickets.json`. These manual test modes are blocked inside agent
issue workspaces because they mutate pinned GitHub sandbox tickets; run them
from the Executor repo root or a dedicated isolated harness. Foreground startup
prints the resolved tmux socket/session, which non-TTY drivers should use
instead of hard-coded socket names.

### GitHub CI handoff safety

After CI passes, Aiur persists the approved PR head before handing the ticket
back to its agent. A later CI observation for that exact SHA cannot return the
ticket from human review to rework, even when the poll retained a stale
`ci-wait` issue snapshot from before the handoff. A CI failure for a different
SHA supersedes the approval and remains eligible for the normal rework path.
Check runs whose names end in `(non-blocking)` are advisory and do not affect
the lifecycle decision.

## Dashboard

When `server.port` (or CLI `--port`) is set, Aiur exposes:

- LiveView dashboard at `/` — active agents, logs, read-only per-agent log modal
  plus append-only Decision history and the 50 newest recent repository merges
- JSON API under `/api/v1/*` for operational debugging (read endpoints; agent-write
  endpoints are disabled unless `observability.dashboard_writable` is set)
- Read-only telemetry analytics at `/analytics` when the current run has a
  `telemetry.ndjson` input; this route uses the same dashboard basic auth,
  reducer, and self-contained renderer as the CLI artifact and is served with
  `Cache-Control: no-store`. Drag across any time chart to zoom the five
  time-series charts together; use Reset to return to the full selected range.

The endpoint serves packaged dashboard hooks, styles, fonts, logos, and provider
icons from `priv/static` before router dispatch. Explicit allowlists keep the
dashboard Basic Auth boundary intact: runtime assets revalidate, stable logo and
font files use long-lived caching, and provider icons derive from the coding-agent
registry. Content-addressed layout vendor files remain on their verified router
paths; vendor manifests, provenance, sources, and licenses are not exposed.

The Units catalog reconciles retained current-run membership with the latest
fresh orchestrator snapshot. After a daemon generation change, current agents
remain visible while membership catches up; counts are marked partial if that
membership source is unavailable. A periodic reconciliation also recovers
agents that existed without a dispatch notification, so an unknown catalog is
never presented as an exact zero.

The Units summary keeps progress useful while member weight facts catch up. If
some members have current facts, it shows the percentage derived from those
members and labels how many inputs are current. Expected post-restart catch-up
is marked as still settling; an unhealthy refresh is marked as degraded.

### Shared GitHub quota

GitHub-backed runs meter the shared agent credential's core and GraphQL budgets
in the dashboard, including remaining units, reset times, rolling read/write
attribution, and the top ticket consumer. Aiur raises an Executor alert at 10%
remaining and pauses new dispatch until the affected window resets. At zero,
daemon requests are rejected locally and agent-launched `gh` commands wait on
the recorded reset instead of retrying into the exhausted budget. Quota state
that has not yet been observed fails open so startup is not blocked by a meter.

Aiur also coordinates request *shape* across all local instances that share a
credential. A host-local SQLite broker at `~/.aiur/github-budget/` keys state
by SHA-256 fingerprints, never the token or consumer identity itself. It enforces a shared
requests-per-minute ceiling, total and endpoint-family in-flight ceilings, and
jittered admission starts. A primary exhaustion holds its resource globally;
a secondary-limit response or `Retry-After` holds every consumer of that token,
including separately started daemons and agent `gh` commands.

The defaults are deliberately conservative and can be tuned per workflow:

```yaml
tracker:
  github:
    max_inflight: 4
    max_inflight_per_endpoint: 2
    requests_per_minute: 120
    stagger_ms: 75
```

When active consumers of the same token disagree, the broker uses the most
restrictive ceilings and the widest stagger observed in the preceding two
minutes. This prevents a permissive second instance from raising the shared
limit above another instance's configured safety boundary.

At startup Aiur installs an optional Executor-shell wrapper at
`~/.aiur/bin/gh`. Put that directory ahead of the system `gh` in
an Executor shell's `PATH` to share the same budget for direct CLI calls. The
wrapper fingerprints the `GH_TOKEN`, `GITHUB_TOKEN`, or `gh auth` credential it actually
uses, so distinct daemon and Executor credentials never share a budget. Agent
workspaces receive the wrapper automatically.

### Supervisor Decision API

The machine Decision API under `/api/v1/decisions` uses a dedicated bearer
credential, not dashboard Basic Auth. Set `AIUR_SUPERVISOR_TOKEN` to at least 32
random bearer-safe bytes. Generate one with `openssl rand -base64 32`, then put
`AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` (global) or the
repository `.env` (project-local); an already-exported value wins, followed by
the global file and then the repository file. A present empty, short,
whitespace-surrounded, or non-bearer-safe value aborts startup, while an absent
value leaves the API disabled. Keep the dashboard on loopback/private tunneling
or terminate HTTPS before using the credential remotely.

Supervisor answers and revisions are disabled until their Decision kinds are
explicitly delegated:

```yaml
decisions:
  supervisor_allowed_kinds: [architecture]
  supervisor_allow_non_reversible: false
```

`human_required` remains absolute. Mutating enrich/decide/revise requests also
require `observability.dashboard_writable: true`, an exact dashboard/loopback
`Origin`, and `X-Aiur-Request: 1`. See the
[OCC-7 supervisor Decision API contract](../docs/operator-control-center/06-occ-7-supervisor-decision-api-contract.md)
for routes, payloads, retry semantics, and audit guarantees.

## Run telemetry

Aiur records daemon-owned run telemetry by default. The daemon continuously
records resource samples for itself, locally attributable ticket process trees,
and the Executor process when it can be identified. It also records sanitized
ticket lifecycle boundaries such as dispatch, workspace setup, implementation,
build/test, PR/review, pause/resume, and rework. Prompt text, command text, and
output are never included.

To opt out, set `observability.telemetry_enabled: false` in your config; the
telemetry writer and sampler will not start and no file will be created. The
setting is read once at daemon startup — a restart is required to apply a change.

`--debug` (or config-level `debug: true`) controls **log verbosity and evidence
capture**, not whether telemetry is recorded.

The append-only schema-versioned stream is written beside `aiur.log` as
`telemetry.ndjson`. A default run therefore writes to:

```text
~/.aiur/logs/<session-id>/log/telemetry.ndjson
```

Each daemon start appends a restart marker with a new boot identity. Schema 1
readers keep valid records from every selected stream and report malformed lines,
unknown record kinds, unsupported future schemas, attribution gaps, and unavailable
platform metrics as warnings instead of discarding the rest of the run.

Before a new writer starts, Aiur prunes old **whole boots** from the stream. The
default retention window is 30 days and 64 MiB (`observability.telemetry_retention_max_age_days`
and `observability.telemetry_retention_max_bytes`); these defaults retain useful
cross-session Build Order history without allowing a long-running operator stream to
grow indefinitely. During a long-running daemon boot, the writer closes a telemetry
segment and prunes at `observability.telemetry_retention_prune_interval_bytes`; it
defaults to `max(max_bytes / 8, 1 MiB)` (8 MiB with the default cap). Size is a
whole-boot-segment target: if one segment alone exceeds it, Aiur keeps that segment
intact rather than truncating lifecycle intervals mid-session.

From the repository root, generate the canonical analytics artifact from one file,
one session directory, or several session roots:

```bash
scripts/aiur-telemetry-dashboard \
  --input ~/.aiur/logs/20260711T120000Z-1234 \
  --input ~/.aiur/logs/20260711T160000Z-5678 \
  --output ./aiur-run.html
```

Passing the common `~/.aiur/logs` root recursively discovers every canonical
telemetry stream beneath it. Add `--repo owner/repo` to recover missing PR-open,
trusted-comment, and merge anchors from GitHub at generation time; this optional
enrichment reads `GITHUB_TOKEN`, and auth or network failures become visible report
warnings rather than blocking local analytics. Use
`--review-resume-grace-seconds N` to tune when a trusted review comment with no
observed rework/resume sequence is classified as broken.

The output is one self-contained HTML file with all normalized data, CSS, and
JavaScript inlined. It can be opened directly or served locally by any backend and
makes no view-time network requests. Run
`scripts/aiur-telemetry-dashboard --help` for the complete option list.

While Aiur is running with its browser dashboard enabled, `/analytics` renders
the current canonical `telemetry.ndjson` through that same reducer and renderer.
The Operations Dashboard links to it only when the input exists; debug-off runs
instead show an explicit analytics-unavailable state. The route accepts no input
path parameter and is never browser-cacheable.

## Configuration notes

- Path values support `~` for the home directory and `$VAR` for environment substitution.
- Run credentials resolve in this order: exported environment, `~/.aiur/.env`,
  then repository-local `./.env`. The native provider variables are
  `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, and `OPENROUTER_API_KEY`;
  OpenRouter credit polling additionally uses `OPENROUTER_MANAGEMENT_KEY`.
  Keep values out of workflow YAML and Git.
- `agent.kind` may name any registered backend, including `kimi`, `deepseek`,
  and `openrouter`. Per-instance overrides live under
  `agent.backend_configs.<name>`. DeepSeek is disabled for dispatch until its
  entry sets `enabled: true`. OpenRouter requires an explicit underlying model
  through a model label/routing rule or `backend_configs.openrouter.model`.
  Kimi and DeepSeek have native default models.
- OpenAI-compatible backends are local-only transports today: when SSH workers
  are configured, their sessions remain on the orchestrator host. They are
  deliberately non-resumable, so backend switches continue from shared
  workspace state rather than a cross-provider transcript.
- `agent.prior_work_continuation` defaults to `true`; a cold redispatch or
  backend switch receives continuation guidance based on the existing shared
  workspace instead of pretending the provider conversation was resumed.
- Codex defaults to safer policies when omitted (`approval_policy` rejects unprompted
  approvals, `thread_sandbox` is `workspace-write`).
- Setting `agent.codex.thread_sandbox: danger-full-access` also defaults Codex turns to
  `dangerFullAccess` unless `turn_sandbox_policy` is explicitly configured.
- Local Codex `workspaceWrite` turns derive the current issue workspace and, when
  enabled, the shared GitHub budget directory. Configured `writableRoots` are
  daemon-host extras: each must already be a writable directory, and extras are not
  forwarded to SSH workers, which derive their own remote workspace roots.
- `agent.max_turns` caps how many back-to-back backend turns Aiur runs in a single
  invocation when a turn completes but the issue is still active. Default: `20`.
- `agent.max_turns_by_complexity` optionally overrides that cap for tickets with
  `complexity:N` labels, for example `{1: 4, 2: 8, 3: 12}`. Missing levels and
  unlabeled tickets continue to use `agent.max_turns`.
- `agent.max_concurrent_agents` caps active workers only. Paused agents remain visible
  and can keep their panes open without consuming an active slot.
- An explicit `aiur --max-agents N` launch value takes precedence over
  `agent.max_concurrent_agents`, including when it is higher. Aiur warns when
  the CLI value exceeds the configured value so the effective cap is visible; omit the flag or set it at
  or below the configured value to silence the warning.
- `agent.switch_model_on_ratelimit` is an opt-in ordered list of configured
  backends, for example `[claude, codex]`. It applies only when no explicit
  `model:` label or complexity-routing rule selected a backend, and only to new
  claims: a running agent stays on the backend it started with.
- Aiur records rate-limit observations in `model-usage.json` next to the active
  workflow config. Each backend entry contains any reported `hourly`, `weekly`,
  and `monthly` `{used, limit, reset_at}` windows plus `observed_at`; Executors
  can inspect or remove this file while Aiur is stopped. Codex refreshes its
  authenticated account windows with `account/rateLimits/read` when a Codex
  session starts and also records streaming updates and runtime usage-limit
  failures. The Claude transports currently expose no equivalent authenticated
  account-usage endpoint, so they participate when a runtime limit is reported.
  Unknown reset times expire after one hour rather than excluding a backend
  forever for new dispatches. The running-agent fallback does not treat that
  estimate alone as recovery; it waits for a positive Codex observation or a
  real reported reset time.
- When every eligible fallback backend is limited, Aiur leaves the ticket
  unclaimed and emits one visible pause/retry alert until availability changes;
  it does not busy-loop dispatch attempts.
- `agent.rate_limit_fallback` (default `claude`) automatically reroutes an
  **already-running** codex agent to the headless Claude backend when it pauses on
  `usage_limit_exhausted`, and reverts it back to codex at a safe turn boundary
  after a positive recovery observation or a real reported reset. Unlike
  `switch_model_on_ratelimit` above (opt-in, new claims only), this is
  default-on and acts on a running agent. Set it to `""` to disable. After
  upgrading an existing GitHub workflow, run `aiur init` once to provision the
  marker and `model:claude` labels used by the automatic switch. Headless Claude
  currently runs on the orchestrator host, so Aiur leaves Codex agents on SSH
  worker workspaces parked instead of moving them to an unrunnable backend.
- `agent.target_load_average` enables the adaptive dispatch envelope (default `1.0`
  per scheduler): queued cold starts seed daemon capacity from active and
  reserved ticket slots plus observed reclaimable CPU headroom (idle and niced
  time), bounded by the static cap. That bootstrap seed is one-shot and never
  lowers a warmed envelope. Later
  capacity grows by `agent.load_ramp_step` below the target, and high samples
  halve it no more often than `agent.load_cooldown_seconds`. Set the target to
  `null` to use only the static cap and hard gate.
- `agent.max_load_average` remains the separate per-scheduler ceiling for new
  dispatch (default `1.5`). Aiur holds only when the ceiling is exceeded and a
  consecutive `/proc/stat` sample shows less than 60% reclaimable CPU; idle and
  niced time are reclaimable because niced work yields to agent processes. If a
  CPU delta is unavailable, the load-only decision remains the conservative
  fallback. The optional run-queue gate uses the same corroboration.
- `agent.min_free_memory_mb` optionally sets a Linux `MemAvailable` floor for
  normal new-work dispatch and local agent `mix compile` / `mix test` commands.
  Omit it to disable memory admission. Values are whole MB derived from
  `/proc/meminfo`; an unreadable sample fails open for non-Linux development
  hosts. A low-memory dispatch emits `aiur_perf memory_hold surface=dispatch`,
  while a local Mix command waits before claiming a build slot and emits the
  same phase with `surface=build`. Dispatch or builds resume once available
  memory is at or above the configured floor.
- Aiur also keeps a default-on file-descriptor reserve for normal new-work
  dispatch. It compares the daemon's open descriptors with its finite soft
  `ulimit -n` and holds dispatch below 10% remaining headroom (rounded up to a
  whole descriptor). Linux samples come from `/proc/<pid>/fd` and
  `/proc/<pid>/limits`; the shared launcher exports its effective post-raise
  limit so the daemon can use `/dev/fd` on supported non-procfs hosts. Missing
  platform data fails open, while a sampling `:emfile` fails closed until the
  next poll. Holds emit `aiur_perf fd_hold surface=dispatch` with the used,
  limit, available, and threshold values. `Aiur.SystemFileDescriptors.sample/1`
  exposes the same raw per-process sample for controller and telemetry consumers.
- `agent.max_concurrent_builds` caps agent-launched `mix compile` and `mix test`
  commands across all local workspaces for the current OS user. It defaults to `2`,
  a conservative setting for a 12-core host; agents queue only their Mix verification
  while ordinary editing, Git, and model work continue. Set it to `0` to remove
  the concurrency cap; a configured memory floor or start stagger remains active
  independently.
  Local Codex and Claude launches prepend shell-independent `elixir`, `mix`, and
  `mise` entrypoints, and local workspace lifecycle hooks run with the same admission
  environment before agent support is installed. This keeps `after_create` and
  `before_run` warm-up builds under the fleet cap as well as builds started during
  agent turns.
  Admission recognizes direct `mix compile` / `mix test`, `mix do` compounds separated
  by `+` or the legacy comma grammar, `elixir -S mix`, and `mise exec` / `mise x`
  commands passed after `--` or as a simple `-c` / `--command` string. A compound holds
  one lease for its whole invocation; nested wrappers reuse it only while its token is
  live. Malformed compounds and shell command strings that could hide Mix fail with
  status `125` instead of running ambiguously.
  The gate is cooperative: it covers Aiur's installed PATH entrypoints and Bash
  functions, including aliases of those wrappers, but a command that deliberately
  invokes a separate real executable by absolute, relative, or symlinked path never
  enters those entrypoints and cannot be intercepted.
  Local Codex `workspaceWrite` turns also add the canonical `~/.aiur/build-gate` metadata
  directory to `writableRoots` without replacing configured, workspace, budget, or
  writable Git roots. Persistent lock inodes live in the host-prepared sibling
  `~/.aiur/build-gate.locks`, which is deliberately excluded from turn-writable roots so
  a sandbox cannot unlink or replace a held slot. Linux admission uses a lock-owning
  subreaper, so sandbox-local PID/PGID values are diagnostic only and detached Mix
  descendants keep their slot until they exit.
  Agent transcripts emit
  `aiur_build_gate` queue/acquire/release/timeout signals, and `aiur status` reports
  active or queued contention.
- Gate coordination errors return status `125` without invoking Mix. Repair the path
  named by the error (metadata or lock-directory type, ownership, permissions, missing
  `flock`, or missing `python3` subreaper support) and
  restart/re-dispatch the affected agents. `BUILD GATE DEGRADED` means legacy or
  unreadable metadata needs attention. Stop/re-dispatch the old fleet, confirm no old
  `mix compile` or `mix test` process is still running, then remove only the reported
  legacy records and retry. Do not delete legacy records while old builds may still be
  live. As a deliberate emergency opt-out, set `agent.max_concurrent_builds: 0`, set
  `agent.build_start_stagger_seconds: 0`, omit `agent.min_free_memory_mb`, and
  restart/re-dispatch. All three settings can enable the shared gate; this sequence
  disables build admission entirely and removes its fleet safeguards.
- `agent.build_start_stagger_seconds` optionally separates admitted local `mix compile`
  and `mix test` starts at their actual heavy-command boundary. It defaults to `0`
  (disabled); this repository's dogfood workflow uses `5`. The memory floor runs
  before build-slot acquisition, then a multi-slot or unlimited gate waits until the
  configured start interval has elapsed. A one-slot build cap already serializes
  starts and therefore skips the extra delay. Whole-second portable timing may round
  the interval up by less than one second. Delays emit
  `aiur_perf phase_stagger_hold surface=build phase=<compile|test> wait_seconds=<n>`;
  paced multi-slot work remains visible as active capacity, and phase-only work stays
  queued until it starts. Set the interval to `0` to disable pacing independently of
  the memory and build-cap gates.
- Build-gate settings are captured when each agent process starts. Restart or
  re-dispatch the fleet after changing them. To tune staggering, compare at least
  three enabled and three disabled runs with the same tickets, revision, agent cap,
  build cap, and scheduler cap; compare median peak load and wall time. The dogfood
  acceptance target is at least 10% lower median peak load with no more than 10%
  median completion-time regression. If no fixed interval meets both, leave pacing
  disabled and prefer load-aware admission rather than hiding the throughput loss.
- Use `hooks.after_create` to bootstrap a fresh workspace (typically a `git clone`).
- Optional alert sounds play when an agent gets stuck or needs input. Enable via the
  `alerts:` block in `.aiur/config` (offered during `aiur init`): `enabled` is the master
  switch; `use_os_default_sounds: true` plays built-in macOS/Linux system sounds out of the
  box (macOS via `afplay`, Linux via `paplay`/`canberra-gtk-play`/`aplay`); `sound_dir`
  points at a folder of custom clips that overrides the defaults; `alerts_file` points at the
  topic→sound map. `aiur init` scaffolds an editable `.aiur/alerts` and sets `alerts_file: alerts`
  (a relative value resolves next to `.aiur/config`); an absolute or `~/` path points elsewhere,
  and when the file is unset or missing aiur falls back to the default `.aiur/alerts` next to
  the config. Playback is fully gated by `enabled` and is a no-op when no
  player binary or sound file is available.

## Testing

```bash
make all
```

`make e2e` runs a live end-to-end test against real Linear + Codex; it creates and tears
down disposable resources and requires `LINEAR_API_KEY`.

### Browser harness

The deterministic browser, accessibility, and measurement harness lives in
`src/browser/`. It starts a loopback-only synthetic LiveView fixture on an
isolated port; it never uses a globally installed browser, production data, or
external services.

```bash
cd src/browser
npm ci
npx playwright install chromium # one-time local browser download
npm test
```

`npm test` runs the harness primitives followed by the LiveView smoke. The
fixture requires a synthetic, HttpOnly session path for read-only or writable
access; it never accepts or exposes production credentials. Failures retain
sanitized Playwright traces and screenshots beneath `src/browser/.artifacts-run-*`;
video and other unverified binary formats are deleted before CI upload.
Successful runs remove only their run-owned artifact child. Set
`AIUR_BROWSER_SCREENSHOTS=1` to retain configured smoke screenshots. To prove
the failure-evidence path locally, run:

```bash
AIUR_BROWSER_KEEP_ARTIFACTS=1 npm run verify:failure-artifacts
```

That command deliberately fails one assertion, verifies a trace and screenshot
were captured, proves a parent-process sentinel is absent from trace, URL, DOM,
and screenshot evidence, and verifies port release before printing the retained
temporary artifact directory for inspection. The CI job runs that proof and
caches the downloaded Playwright browser using `src/browser/package-lock.json`
as its cache key.
Playwright Test 1.61.1 (Apache-2.0) and `@axe-core/playwright` 4.11.3
(MPL-2.0) are pinned in that lockfile. The smoke's broad harness liveness check
is not a product-performance budget; BO-014 owns those thresholds.

## Project layout

- `lib/` — application code
- `test/` — ExUnit suite
- `scripts/aiurdev` — dev shim over the launcher engine (local dev build)
- `examples/workflows/` — starter config + prompt-template pairs
- `.aiur/config` — the config contract for in-repo runs

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
