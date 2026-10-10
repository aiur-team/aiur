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
[`aiur-intro`](../.claude/skills/aiur-intro/SKILL.md) to help you choose.

## How it works

1. **Polls a tracker** (Linear, GitHub Issues, or in-memory) for candidate work.
2. **Creates an isolated workspace** per selected item and clones your repo into it.
3. **Launches a coding agent** (such as Codex, Claude, or Muse) inside the workspace with your `.aiur/config`
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
5. **GitHub authentication** — defaults to `GITHUB_TOKEN` and offers a GitHub
   App as an optional daemon upgrade when agents are hitting rate limits. With
   no selected credential yet, the wizard explains the next step instead of
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

## Operating, dashboard, and configuration notes

These sections now live in the docs site:

- [Operating with `aiurdev`](../website/docs-app/concepts/operating-with-aiurdev.md)
- [Dashboard and run telemetry](../website/docs-app/guide/dashboard-and-telemetry.md)
- [Configuration notes](../website/docs-app/reference/configuration-notes.md)

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

Apache License 2.0. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
