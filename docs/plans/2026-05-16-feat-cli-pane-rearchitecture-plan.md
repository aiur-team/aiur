---
title: "feat: CLI pane rearchitecture — tmux-driven agent-list + per-agent conversation panes"
type: feat
status: active
date: 2026-05-16
origin: docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md
---

# feat: CLI pane rearchitecture — tmux-driven agent-list + per-agent conversation panes

## Enhancement Summary

**Deepened on:** 2026-05-16

**Review sources:** architecture-strategist, code-simplicity-reviewer, performance-oracle, security-sentinel, agent-native-reviewer, agent-native-architecture skill.

### Key improvements applied
1. Dropped `AgentEventBroadcaster` as a module (unjustified indirection). Inline calls plus a single 25-LOC `SymphonyElixir.AgentPubSub` wrapper modeled on `ObservabilityPubSub`.
2. Folded `SymphonyPane.LogSubscriber` into `SymphonyPane.Conversation`.
3. Added new modules for agent-native parity: `SymphonyElixir.Conversations` (attach/1 primitive split from PaneManager), `SymphonyElixir.AgentEvents` (payload contract with `@type` declarations), `SymphonyElixir.AgentDirectory` (read-side primitives), `SymphonyElixir.PaneRPC` (explicit pane-callable surface).
4. Symmetrized composer submissions: human messages now broadcast on `"agent:<id>"` as `{:transcript_event, %{role: :user, ...}}` for any subscriber to see, not just routed through `AgentChat.send/2`.
5. Promoted warm-pane-worker pre-spawn from "deferred mitigation" to Phase 1 — BEAM cold-start at 500–1500ms is past the perception cliff.
6. Switched composer submit from `:rpc.call` (synchronous) to `:rpc.cast` + local optimistic echo.
7. Added transcript render coalescing (16ms frame budget) to absorb streaming-Codex-output bursts without starving the composer.
8. Hardened cookie handling: moved cookie out of `ERL_AFLAGS` (was leaking via `/proc/<pid>/environ`) into `~/.erlang.cookie`; added umask, atomic-write, parent-dir 0700, UID validation.
9. Added EPMD multi-user node-naming (`-sname symphony-$USER`) to avoid collisions on shared hosts.
10. Added PubSub backpressure plan in `Conversation` for chatty agents.
11. Fixed missed `Application.stop/2` → `StatusDashboard.render_offline_status/0` call site.
12. Reduced integration test scope: cut #4 (50 rapid races) and #5 (control-mode disconnect) from Phase 1.
13. Re-estimated Phase 1 effort: 5–8 days → 10–14 days. Added CI tmux provisioning as an explicit task.

### New considerations discovered
- Two reviewers pushed back on the brainstorm's "one BEAM per pane" decision (KD 8). Captured in §"Reviewer Pushback" for user decision.
- LiveView refresh path needs explicit verification that `ObservabilityPubSub.broadcast_update/0` is independently triggered after the cutover.
- Detached-Termius-session behavior (user disconnects mid-conversation) needs explicit documentation.
- Body opacity through `AgentChat.send/2` → orchestrator → log needs verification before merge (no shell interp, no eval).

## Overview

Replace Symphony's monolithic 2,345-line `status_dashboard.ex` with a tmux-orchestrated, two-pane-types architecture. tmux owns layout. Symphony renders two pane types into individual tmux panes: a small agent-list pane (always-visible) and per-agent conversation panes (spawned on demand, one per open conversation). Each per-agent conversation pane is a separate hidden BEAM node that connects back to Symphony's main BEAM via Erlang distribution and subscribes to per-agent `Phoenix.PubSub` topics. The current monolith is deleted in the same change.

The plan originated from `docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md`; every key decision and constraint there is reflected below. Work proceeds on a fresh branch off `main` (hard cutover, no feature flag) and merges only after the user has used it in Termius on iPad and confirms typing feels like Claude Code.

## Problem Statement

The existing CLI has two intractable problems and a structural cause for both.

**Symptoms.**
- Cursor renders +2 rows / +2 columns offset from the user's typing position in Termius.
- Typing latency is dramatically worse than Claude Code or Codex CLI. The dashboard re-renders on its own clock and fights the composer.
- Multiple weeks of attempted surgical fixes have not landed (`elixir/lib/symphony_elixir/status_dashboard.ex` commits `9e4f722`, `601f9cc`, and earlier).

**Root cause.** `status_dashboard.ex` (2,345 LOC, one GenServer) is a timer-driven full-frame renderer originally designed as a read-only dashboard. An interactive composer was bolted on. Every keystroke arrives as a `GenServer.cast`, re-reads the agent log file from disk, re-computes a full frame, and emits it via synchronous `IO.write`. The incremental-paint fallback is fragile: it silently degrades on conditions that don't reproduce in local PTY tests (margin math drifts between full-frame and incremental paths, autowrap occurs on the final terminal column on some SSH clients, etc.). The audit recorded in the brainstorm rates surgical-fix feasibility 3–4 out of 5 with high residual bug surface — confirming we'd be back here in a month.

**Future-feature pressure.** The user's roadmap includes (a) Symphony scripting tmux to open/close/resize conversation panes, (b) agents subscribing to events from other agents and from PRs/issues, (c) alert-injection into specific panes. The current monolithic architecture cannot grow into any of these.

## Proposed Solution

A two-pane-types model with tmux as the layout manager (see brainstorm: `docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md`, Key Decisions 1–10).

**Agent-list pane** (small, always-visible, Symphony-owned). Renders the list of agents Symphony is orchestrating, with per-agent status and an alert indicator. Arrow keys + enter/space select an agent and instruct Symphony to open that agent's conversation pane via the tmux control-mode socket. Mostly read-only. No composer.

**Per-agent conversation pane** (one per open conversation, Symphony-owned, but **runs as a separate BEAM node**). A small escript (`bin/symphony-pane`) starts a hidden BEAM, connects to Symphony's main BEAM via Erlang distribution, subscribes to `Phoenix.PubSub` topic `"agent:<identifier>"`, renders the agent's transcript plus a composer at the bottom. Composer input is sent back to the orchestrator through the existing per-agent chat-send path (`AgentChat.send/2`, `Orchestrator.send_operator_message/2` — both already keyed by `issue_identifier`; see brainstorm Open Question 1, now resolved by repo research).

**tmux owns layout.** Symphony never owns the whole screen. Symphony attaches to tmux as a control-mode client (`tmux -CC attach`) for the duration of the user's session, scripts `split-window` to spawn conversation panes, and consumes `%pane-died` / `%window-pane-changed` notifications to keep the agent-list pane in sync. The user is attached normally in Termius; control-mode coexists without stealing input.

**Hard cutover.** `status_dashboard.ex` and `terminal_input.ex` are deleted in the same PR that introduces the new modules. No feature flag, no parallel surfaces. Work happens on a fresh branch off `main` so the risk is contained until the new flow is proven in Termius.

## Technical Approach

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Terminal (Termius/iTerm, the user's SSH client) attached to tmux   │
│                                                                     │
│  ┌──────────────────────┐  ┌─────────────────────────────────────┐  │
│  │ agent-list tmux pane │  │ conversation tmux pane (per agent)  │  │
│  │  ┌────────────────┐  │  │  ┌───────────────────────────────┐  │  │
│  │  │ symphony       │  │  │  │ symphony-pane <agent-id>      │  │  │
│  │  │ (named node)   │  │  │  │ (hidden node)                 │  │  │
│  │  │                │  │  │  │                               │  │  │
│  │  │ AgentList      │  │  │  │ Conversation viewport         │  │  │
│  │  │ Renderer ──┐   │  │  │  │ + composer                    │  │  │
│  │  └────────────┼───┘  │  │  └───────────────────────────────┘  │  │
│  │               │      │  │                  ▲                  │  │
│  └───────────────┼──────┘  └──────────────────┼──────────────────┘  │
│                  │                            │                     │
│           tmux -CC                            │ Erlang distribution │
│           control socket                      │ + Phoenix.PubSub    │
│                  │                            │                     │
│           ┌──────▼────────────────────────────▼──────┐              │
│           │  Symphony main BEAM (named node)         │              │
│           │   - Orchestrator (existing)              │              │
│           │   - Phoenix.PubSub (per-agent topics)    │              │
│           │   - Tmux control-mode client (new)       │              │
│           │   - PaneManager (new)                    │              │
│           │   - AgentList rendering (new)            │              │
│           │   - AgentRunner / agents (existing)      │              │
│           └──────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
```

Three independent communication channels:
1. **Main BEAM ↔ tmux** via control-mode socket. Symphony scripts pane creation/destruction and observes lifecycle. Symphony's agent-list-pane renderer also uses normal stdio (it is the foreground process of the agent-list pane).
2. **Pane BEAM ↔ Main BEAM** via Erlang distribution. Per-agent topic subscription, composer-send RPC. One pane node per open conversation.
3. **User ↔ tmux** via the user's terminal client (Termius). The control-mode client never sees the user's keystrokes; tmux dispatches them to whichever pane has focus, which is owned by either the agent-list renderer or a `symphony-pane` process.

### Module-by-module breakdown

New modules in the main app (`elixir/lib/symphony_elixir/`):

- **`agent_events.ex`** — payload-contract module. Defines `@type transcript_event :: %{role: :user | :assistant | :system, body: binary, timestamp: DateTime.t()}`, `@type alert :: %{...}`, `@type running_change :: ...`, etc. Pure types and a small `broadcast/2` helper. Single canonical wire-format reference for every subscriber (in-process today, MCP-bridged later).

- **`agent_pubsub.ex`** — thin wrapper modeled on the existing `SymphonyElixirWeb.ObservabilityPubSub` (25 LOC). Three functions: `subscribe(identifier)`, `broadcast_transcript(identifier, event)`, `broadcast_running_change(payload)`. Replaces the originally-planned `AgentEventBroadcaster` after the simplicity reviewer flagged it as unjustified indirection. Callers (`AgentRunner`, `Orchestrator`, `Alerts`, `Composer`) use this wrapper for consistency.

- **`conversations.ex`** — agent-native primitive for attaching to a conversation. Public API: `attach(identifier) :: {:ok, subscription_ref}`, `detach(subscription_ref)`. Internally subscribes the caller to `"agent:<id>"` and returns a handle. Used by `Tmux.spawn_pane_for/1` for the human path, callable by any future in-process or external agent that needs to consume an agent's transcript without spawning a tmux pane. **Split from the originally-conflated `PaneManager.open_conversation/1`** per agent-native review.

- **`agent_directory.ex`** — read-side MCP-shaped primitives. Public API: `list_agents/0`, `get_transcript_tail(identifier, n)`, `get_alerts(identifier)`. Replaces ad-hoc `:rpc.call(Orchestrator, :snapshot, [])` from the pane subcommand with stable, documented primitives. A future MCP server exposes these verbatim as tool surfaces.

- **`pane_rpc.ex`** — explicit chokepoint module for cross-node calls from pane subcommands. Public API: `snapshot/0`, `send_operator_message/2`, `attach_conversation/1`, `detach_conversation/1`. The pane calls *only* these functions via `:rpc.call`. Documents the intended distribution surface (security: per security-sentinel) and gives audit logging a single chokepoint.

- **`distribution.ex`** — Distribution module retained but slimmed. Starts `:net_kernel.monitor_nodes(true, node_type: :hidden)` and validates `ERL_EPMD_ADDRESS=127.0.0.1`. Cookie management lives in the wrapper script using `~/.erlang.cookie` (per security review — not via `ERL_AFLAGS`). Called from `Application.start/2`. If this collapses to ~10 LOC during implementation, fold into `application.ex` directly (simplicity reviewer note).

- **`tmux.ex`** — control-mode client. Owns the `tmux -CC attach` port. Public API: `command/1` (send a tmux command, await `%begin/%end`), `subscribe_events/0` (caller receives `{:tmux, %{type: ..., ...}}` messages), `spawn_pane_for/1` (UI-side helper that issues `split-window` and registers the pane id). Parses the control-mode notification stream (`%output`, `%window-pane-changed`, `%pane-died`, `%client-detached`, `%session-changed`, `%subscription-changed`). One persistent connection per Symphony BEAM startup; reconnects on broken pipe (tmux session itself survives independently). In test mode, the port is stubbed with an in-memory mock that satisfies the same protocol.

- **`pane_manager.ex`** — supervised GenServer that owns the mapping from `issue_identifier` to tmux `pane_id` (UI concern only — `Conversations.attach/1` is the data primitive). Subscribes to `Tmux.subscribe_events/0` and `:nodedown` notifications. Plan: deduplicate `%pane-died` and `:nodedown` by treating `:nodedown` as the authoritative signal (per cited tmux issues #2483, #2882 — same logic that argued against tmux hooks).

- **`pane_warm_pool.ex`** — supervised pool of pre-booted pane workers. At startup, pre-spawn one warm `bin/symphony conversation --warm` process. When `PaneManager.open_conversation/1` is called, claim the warm worker, replace it with a freshly-spawned one. Cuts the *first* `open_conversation` from ~1500ms to ~200ms. **Promoted from "deferred mitigation" to Phase 1 per performance-oracle's perception-cliff analysis.**

- **`agent_list/renderer.ex`** — renders the agent-list pane's content. Pure function: `render(snapshot, terminal_columns, terminal_rows, selection_index) :: iodata`. No GenServer. Trivially testable.

- **`agent_list/input.ex`** — small GenServer that owns stdio for the agent-list pane. Reads keystrokes (preserves the existing CSI parser from `terminal_input.ex:256–305`), maintains `selection_index` and `mode` state, calls `Renderer.render/4` on changes, calls `Tmux.spawn_pane_for/1` on enter/space (which itself calls `Conversations.attach/1` internally). Replaces `terminal_input.ex`.

- **`agent_list/app.ex`** — entry point invoked by `SymphonyElixir.CLI.main(["agents" | _])`. Connects the renderer and input together, subscribes to `"agents:running"` PubSub topic for snapshot updates, attaches to the tmux control client, ensures the agent-list pane is the focused pane.

New small app for the conversation pane (lives in `elixir/lib/symphony_pane/` plus its own `mix.exs` build target, OR as a second `main_module` dispatch inside `SymphonyElixir.CLI` — see "Mix escript packaging" below):

- **`symphony_pane/cli.ex`** — `main/1` entry point. Parses argv (expects `<issue_identifier>`), starts distribution by inheriting `-sname pane_<uuid> -hidden -setcookie <cookie>` from the wrapper, connects to Symphony's main BEAM via `Node.connect/1` (target read from `SYMPHONY_NODE` env var), then hands control to `Conversation`.

- **`symphony_pane/conversation.ex`** — GenServer that owns the pane lifecycle. Calls `PaneRPC.attach_conversation(identifier)` to subscribe to `"agent:<identifier>"`, monitors Symphony's node via `Node.monitor(symphony_node, true)`, renders via `Viewport`, dispatches keys to `Composer`, exits cleanly on `{:nodedown, _}`. **Owns the transcript-tail state directly** (originally split into `LogSubscriber`, folded in per simplicity review). Receives `{:transcript_event, ...}` PubSub messages in `handle_info/2`, coalesces high-frequency bursts via `Process.send_after(self(), :flush_render, 16)` (16ms ≈ 60Hz) so streaming Codex output cannot starve the composer.

- **`symphony_pane/viewport.ex`** — small ANSI renderer with two regions: transcript (top, scrollable) and composer (bottom, fixed-height). Diffs line-by-line against last-rendered state. Uses `Owl.Data.tag/2` for ANSI composition and `Owl.IO.columns/0` for size detection (per framework research, Owl is a primitive dep — `Owl.LiveScreen` is NOT used). Reserves the final column to prevent autowrap (the lesson learned from `status_dashboard.ex`'s SSH-client bugs). Per-keystroke render budget: **<200μs from byte-in to byte-out, measured via `:timer.tc/1` in the hot path.**

- **`symphony_pane/composer.ex`** — composer state machine. Buffer, cursor position, history (later). On submit: (1) immediately echo the user's message to the local transcript via optimistic update, (2) call `PaneRPC.send_operator_message(identifier, body)` via **`:rpc.cast`** (async — composer does not block on network), (3) the orchestrator's broadcast of `{:transcript_event, %{role: :user, ...}}` arrives on the PubSub topic and confirms the optimistic update. Length-caps composer input at 64 KiB before submit; filters control characters except `\n`, `\t` before broadcast/log (per security review). Reuses the CSI parser from the existing `terminal_input.ex:256–305` for arrow keys / paste handling.

Modified existing modules:

- **`application.ex`** — add `Distribution.start!/0` call before `Phoenix.PubSub` in the supervision tree start order. Add `PaneManager`, `Tmux`, and `PaneWarmPool` to the supervision children. Drop `dashboard_spec` and `TerminalInput` from the child list. Add the `:phoenix_pubsub` `pool_size: 1` option to match the pane node. **Update `Application.stop/2`** to remove the `StatusDashboard.render_offline_status/0` call (line 56 today, breaks shutdown if not updated).

- **`orchestrator.ex`** — replace the two `StatusDashboard.notify_update/0` call sites (line 1224 today) with `AgentPubSub.broadcast_running_change(state.running)`. Add `AgentPubSub.broadcast_status_change(identifier, status)` calls at each `state.running` transition. **Verify** that the existing `ObservabilityPubSub.broadcast_update/0` continues to fire so LiveView still refreshes after the cutover.

- **`agent_runner.ex`** — `codex_message_handler/4` (today calls `AgentEventLog.write/3` at line 49) gains a sibling call to `AgentPubSub.broadcast_transcript(issue_identifier, event)`. The existing on-disk log writing stays unchanged — PubSub is a parallel real-time feed.

- **`agent_chat.ex`** — `send/2` (line 10 today) gains a `AgentPubSub.broadcast_transcript(identifier, %{role: :user, body: text, timestamp: now})` call after `Orchestrator.send_operator_message/2` returns `{:ok, _}`. **Symmetry fix per agent-native review:** without this, only agent-side events appear in `"agent:<id>"`; any subscriber (other pane, future agent, MCP bridge) sees only half the conversation.

- **`alerts.ex`** — line 93 today calls `StatusDashboard.notify_update/0`. Replace with `AgentPubSub.broadcast_alert(identifier, alert_payload)`. The agent-list-pane subscriber renders the alert indicator on receipt.

- **`scripts/agents`** — wrapper script gains:
  - Pre-flight check: `command -v tmux >/dev/null || die "tmux required"`.
  - Pre-flight check: `tmux -V` returns `>= 3.3` (control-mode feature parity, per external research).
  - Creates `~/.config/symphony/` with mode 0700 (`mkdir -m 0700 -p`).
  - Creates `~/.erlang.cookie` (not `~/.config/symphony/cookie`) with mode 0400 and 32 random base64-encoded bytes if missing. Uses `umask 0177` + atomic temp-write + `mv` to avoid TOCTOU. Validates the file is owned by the current UID and is ≥ 16 bytes before launch. **Cookie is NOT passed via `ERL_AFLAGS`** (security review: would leak via `/proc/<pid>/environ`); BEAM auto-reads `~/.erlang.cookie` natively.
  - Sets `ERL_AFLAGS="-sname symphony-${USER}"` (per-user suffix avoids collisions on shared hosts) plus `ERL_EPMD_ADDRESS=127.0.0.1`.
  - Exports `SYMPHONY_NODE=symphony-${USER}@$(hostname -s)` for child processes.
  - Spawns `tmux new-session -d -s symphony-${USER}-${RANDOM_HEX:0:8}` if no session exists (random suffix avoids accidental cross-session collisions); writes the session name to `~/.config/symphony/state`; sends `bin/symphony agents` to that session's first pane via `tmux send-keys`.
  - For interactive mode: `tmux attach -t <session>` after launching the foreground BEAM.

- **`cli.ex`** — `main/1` (today calls into `StatusDashboard` startup at line 219) is rewritten to dispatch on argv[0]: `agents` → starts the full app + agent-list pane; `conversation <id>` → starts only `:phoenix_pubsub` + the pane code. The full-app startup also attaches to the tmux control socket.

- **`mix.exs`** — coverage `ignore_modules` list (lines 14–57) is updated: add the new pane modules to the ignore list during Phase 1 development, then graduate them to full coverage as tests stabilize. Add `{:owl, "~> 0.13"}` to deps.

Deleted modules (hard cutover, brainstorm Key Decision 4):

- `elixir/lib/symphony_elixir/status_dashboard.ex` (2,345 LOC) — gone.
- `elixir/lib/symphony_elixir/terminal_input.ex` (355 LOC) — gone. (CSI parser logic is copied into `agent_list/input.ex` and `symphony_pane/composer.ex` — small enough to duplicate and easier than dependency-injecting a shared module.)
- Existing tests for these modules are deleted in the same change. New tests live alongside new modules.

### `Phoenix.PubSub` topic schema

Three topic families introduced. All broadcast on `SymphonyElixir.PubSub` (existing PG2 adapter, no config change beyond `pool_size: 1`).

| Topic | Producers | Subscribers | Payload |
|---|---|---|---|
| `"agent:<identifier>"` | `AgentRunner.codex_message_handler/4`, `Alerts.emit/3` | conversation pane for that agent | `{:transcript_event, %{role:, body:, timestamp:}}`, `{:alert, %{name:, message:, severity:}}` |
| `"agents:running"` | `Orchestrator` on every `state.running` mutation | agent-list pane | `{:running_changed, [%{identifier:, status:, alert_count:, ...}]}` |
| `"agents:status"` | `Orchestrator`, `AgentRunner` | agent-list pane | `{:status_changed, %{identifier:, status:}}` |

Naming follows Phoenix Channels convention (colon-delimited). Topic identifiers are stable across reconnects so a pane that briefly loses connection can resubscribe by replaying its identifier.

### tmux control-mode integration

Symphony attaches to tmux at startup via `tmux -CC attach -t symphony` (the wrapper has already created the session). The connection is a long-running `Port` owned by `SymphonyElixir.Tmux`. The module parses the notification stream:

- `%begin <time> <id> <flags>` / `%end <time> <id> <flags>` — bracket synchronous command responses. `Tmux.command/1` blocks on the matching `%end`.
- `%output %<pane-id> <data>` — bytes printed in a pane. We don't currently need these but they're useful for Phase 3 (alert-injection into conversation panes).
- `%window-pane-changed <window-id> %<pane-id>` — focus changed.
- `%pane-died %<pane-id>` — pane's process exited. `PaneManager` removes the mapping, broadcasts `{:pane_closed, identifier}` to the agent-list pane.
- `%client-detached` — control-mode connection lost. We reconnect.

Commands Symphony sends (each through `Tmux.command/1`):
- `split-window -h -t <agent-list-pane-id> -P -F '#{pane_id}' bin/symphony-pane <issue_identifier>` — spawns a conversation pane to the right of the agent-list pane. The `-P -F` captures the new pane's id.
- `select-layout -t <window-id> tiled` — auto-rebalance (Phase 2 will swap this for custom layout math, but `tiled` is a sane Phase 1 default).
- `kill-pane -t <pane-id>` — Phase 2 close affordance.

Backpressure: `refresh-client -f pause-after=2` enables flow control. If Symphony falls behind on `%output` (unlikely in Phase 1 since we ignore them), tmux pauses and resumes on `refresh-client -A`. Not Phase 1 work but documented for completeness.

Per the research, tmux's hooks (`pane-died`, `pane-exited`) are unreliable for per-pane scoping (issues #2483, #2882, #3776). Control mode is the right answer.

### Distribution setup

Main BEAM startup (in `SymphonyElixir.Distribution.start!/0`, called from `Application.start/2`):

1. Read cookie from `~/.config/symphony/cookie` (created by `scripts/agents` on first run with `head -c 32 /dev/urandom | base64`, mode 0400).
2. The BEAM is already launched as `-sname symphony -setcookie <cookie>` by the wrapper, so `Node.alive?/0` returns `true` here. No `Node.start/2` call needed in code.
3. `:net_kernel.monitor_nodes(true, node_type: :hidden)` — get `:nodedown` for each pane node disconnect.
4. Validate `ERL_EPMD_ADDRESS=127.0.0.1` is set (refuse to start if epmd is exposed to the network).

Pane BEAM startup (in `SymphonyPane.CLI.main/1`):

1. The wrapper has already passed `-sname pane_<uuid> -hidden -setcookie <same-cookie>` via `ERL_AFLAGS` set by the parent tmux session (env vars inherit through tmux). Plus `SYMPHONY_NODE=symphony@<hostname>`.
2. `Application.ensure_all_started(:phoenix_pubsub)`. The pane node creates its own `Phoenix.PubSub` registration with `name: SymphonyElixir.PubSub, pool_size: 1` matching Symphony — required for cross-node fan-out.
3. `Node.connect(System.fetch_env!("SYMPHONY_NODE"))`. On `false`, exit with a clear error.
4. `Node.monitor(symphony_node, true)`. On `{:nodedown, _}`, render "Symphony disconnected" banner and exit (tmux pane closes).
5. Subscribe to `"agent:<identifier>"`. Begin rendering.

Discovery: env vars set by the wrapper script. The wrapper writes `~/.config/symphony/state` containing `SYMPHONY_NODE=...\nSYMPHONY_PID=...` so a pane spawned outside the wrapper context can still self-bootstrap by sourcing that file.

### Mix escript packaging

Repo research established that `mix.exs` already configures one escript (`main_module: SymphonyElixir.CLI, name: "symphony", path: "bin/symphony", app: nil`). Adding a pane subcommand requires picking one of two paths:

**Option A (recommended): single escript, argv dispatch.** `SymphonyElixir.CLI.main/1` dispatches on the first argument:

```elixir
def main(["agents" | rest]),       do: SymphonyElixir.CLI.Agents.main(rest)
def main(["conversation" | rest]), do: SymphonyPane.CLI.main(rest)
def main(_),                       do: SymphonyElixir.CLI.Agents.main([])
```

Each subcommand controls its own application-start behavior (`agents` starts the full app via `Application.ensure_all_started(:symphony_elixir)`; `conversation` only starts `:logger` + `:phoenix_pubsub`). One escript, one build artifact (`bin/symphony`). Invocation: `bin/symphony agents` and `bin/symphony conversation <id>`. tmux split command becomes `split-window -h '... bin/symphony conversation <id>'`.

**Option B: separate escripts via umbrella.** Heavier — adds an umbrella restructure that the brainstorm explicitly didn't ask for. Reject for Phase 1; revisit if cold-start latency demands a slimmer pane release.

We go with Option A.

### Performance Considerations

Per performance-oracle review:

- **Per-keystroke latency budget: <200μs** from byte-in (pane stdin) to byte-out (pane stdout). Measured via `:timer.tc/1` in `Viewport.render/2`. This is the only metric that determines whether the rewrite met its primary goal.
- **Expected end-to-end keystroke path: 2–5ms** (composer state update <1ms + viewport line-diff 1–3ms + IO.write <1ms). Compared to current path 30–60ms (log file re-read 5–20ms + full-frame compute 10–30ms). New path is genuinely faster, not just relocated.
- **BEAM cold-start mitigations** are Phase 1 (not deferred):
  - `PaneWarmPool` pre-spawns one `bin/symphony conversation --warm` at startup. Reduces first `open_conversation` from ~1500ms to ~200ms. Replaces the warm worker after each claim.
  - Pane subcommand renders a "Connecting…" placeholder via `IO.write` before `Application.ensure_all_started`, so the user perceives motion at <50ms even on cold spawn.
- **PubSub fanout latency: 0.5–2ms** on loopback for small payloads with PG2 + `pool_size: 1` (both nodes must match — integration test #2 asserts this).
- **Transcript render coalescing: 16ms frame budget.** `Conversation` batches incoming `{:transcript_event, …}` messages via `Process.send_after(self(), :flush_render, 16)` to absorb streaming-Codex bursts (potentially 100+ events/sec) without starving the composer.
- **Composer submit is async.** `:rpc.cast` + optimistic local echo. The composer never blocks on network latency for the enter key.
- **Memory:** each pane BEAM is ~25–40 MB RSS. Three open panes = ~90–120 MB. Negligible on dev workstations; iPad-via-SSH is irrelevant (the BEAMs run on the host).

### Implementation Phases

#### Phase 1: Foundation (this PR)

The brainstorm explicitly accepts that Phase 1 scope is "larger than the minimum viable, in exchange for building it right the first time." Phase 1 ships everything needed for the user to use Symphony interactively via the new architecture in Termius — no fallback to `status_dashboard.ex`.

**Tasks** (in dependency order):

1. Add `{:owl, "~> 0.13"}` to `mix.exs` deps and run `mix deps.get`.
2. Implement `SymphonyElixir.Distribution` — `monitor_nodes` setup, `ERL_EPMD_ADDRESS` validation. May collapse into `application.ex` if it stays ~10 LOC.
3. Update `scripts/agents`:
   - Pre-flight `tmux` check and `tmux -V >= 3.3` check.
   - `mkdir -m 0700 -p ~/.config/symphony/`.
   - Create `~/.erlang.cookie` (mode 0400) with `umask 0177` + atomic temp-write + `mv`; validate UID and length on every run.
   - Set `ERL_AFLAGS="-sname symphony-${USER}"` (NOT `-setcookie`), `ERL_EPMD_ADDRESS=127.0.0.1`.
   - Export `SYMPHONY_NODE=symphony-${USER}@$(hostname -s)`.
   - Create tmux session with random suffix `symphony-${USER}-${RANDOM_HEX:0:8}`; persist to `~/.config/symphony/state` (mode 0600).
4. Implement `SymphonyElixir.AgentEvents` (`@type` declarations for `transcript_event`, `alert`, `running_change`, `status_change`).
5. Implement `SymphonyElixir.AgentPubSub` (25-LOC wrapper modeled on `ObservabilityPubSub`: `subscribe/1`, `broadcast_transcript/2`, `broadcast_running_change/1`, `broadcast_alert/2`, `broadcast_status_change/2`).
6. Wire broadcasts into `AgentRunner.codex_message_handler/4`, `Orchestrator` (replace `StatusDashboard.notify_update/0` call sites), `AgentChat.send/2` (symmetric human-message broadcast), and `Alerts.emit/3`.
7. Implement `SymphonyElixir.Conversations.attach/1` and `detach/1` (data-only primitive — no tmux).
8. Implement `SymphonyElixir.AgentDirectory` (`list_agents/0`, `get_transcript_tail/2`, `get_alerts/1`) — MCP-shaped read primitives.
9. Implement `SymphonyElixir.PaneRPC` (chokepoint module: `snapshot/0`, `send_operator_message/2`, `attach_conversation/1`, `detach_conversation/1`). Server-side input validation here: length cap, control-char filter, `:rpc.call` timeouts on all functions.
10. Implement `SymphonyElixir.Tmux` control-mode client.
    - Port to `tmux -CC attach`.
    - `%begin`/`%end` correlation, `%output`/`%pane-died`/`%window-pane-changed`/`%client-detached` parsing.
    - `command/1`, `subscribe_events/0`, `spawn_pane_for/1`.
    - Test-mode in-memory stub satisfying the same protocol.
11. Implement `SymphonyElixir.PaneManager` (UI concern only — owns `identifier -> pane_id` mapping; subscribes to tmux events; treats `:nodedown` as authoritative pane-closed signal).
12. Implement `SymphonyElixir.PaneWarmPool` (pre-spawn one warm `bin/symphony conversation --warm` at startup; replace warm slot after claim). Documents that warm pool of size 1 means second concurrent open is still cold-path; acceptable for single-user Phase 1.
13. Implement `SymphonyElixir.AgentList.Renderer` (pure function).
14. Implement `SymphonyElixir.AgentList.Input` (stdio owner, key dispatcher; on enter/space calls `Tmux.spawn_pane_for(identifier)`).
15. Implement `SymphonyElixir.AgentList.App` (subscribes to PubSub, threads renderer + input).
16. Implement `SymphonyPane.Viewport` (two-region ANSI renderer, final-column reserved, `:timer.tc` instrumentation for <200μs render budget).
17. Implement `SymphonyPane.Composer` (buffer state, CSI parser copied from old `terminal_input.ex`, optimistic local echo with **client-generated `msg_id` for de-dup**, calls `PaneRPC.send_operator_message/2` via `:rpc.cast`, 64 KiB length cap, control-char filter).
18. Implement `SymphonyPane.Conversation` (GenServer threading `Viewport` + `Composer` + transcript-tail state; subscribes to `"agent:<id>"`; coalesces transcript events into 16ms frames via `Process.send_after`; **keystrokes are handled in `handle_info` directly, never queued behind `:flush_render`**; de-duplicates broadcast loopback for messages whose `msg_id` matches an outstanding optimistic echo).
19. Implement `SymphonyPane.CLI.main/1` (calls `Application.ensure_all_started(:phoenix_pubsub)`, `Node.connect/1`, `Conversations.attach/1`, then `Conversation.start_link/1`).
20. Update `SymphonyElixir.CLI.main/1` to dispatch on argv (`agents` vs `conversation`).
21. Update `application.ex` supervision tree:
    - Add `Distribution.start!/0` call (or inline equivalent).
    - Add `Tmux`, `PaneManager`, `PaneWarmPool` to children.
    - Add `AgentList.App` to children (only in interactive mode).
    - Remove `StatusDashboard` and `TerminalInput` from children.
    - **Fix `Application.stop/2` to drop the `StatusDashboard.render_offline_status/0` call** (today's symphony_elixir.ex:56).
22. Delete `status_dashboard.ex` (2,345 LOC), `terminal_input.ex` (355 LOC), and their tests.
23. Update `mix.exs` coverage `ignore_modules` (drop deleted modules; temporarily add new ones during stabilization). Add `{:owl, "~> 0.13"}` to deps.
24. Provision tmux ≥ 3.3 in the CI image (.github/workflows or equivalent).
25. Write the three Phase 1 integration tests (end-to-end pane spawn, cross-node PubSub delivery, pane exits on Symphony death).
26. Update `README.md`, `elixir/README.md`, `elixir/AGENTS.md`, `elixir/local-workflows/WORKFLOW.symphony.local.md`, and `SPEC.md` to reflect the new architecture (per `elixir/AGENTS.md:60–64` doc-update convention). Write `docs/agent-event-api.md`.
27. Verify `make all` passes (format check, lint, test --cover, dialyzer).
28. **User-driven verification in Termius on iPad.** Acceptance is gated on this, not on local PTY tests (the lesson from the May 2026 typing-fix attempts is that local PTY does not represent Termius).

**Estimated effort:** 10–14 days, single-engineer, with the user available for Termius verification at the end. (Revised from initial 5–8 day estimate after architecture review flagged: brand-new tmux control-mode protocol implementation, brand-new BEAM distribution setup, cross-node PubSub integration tests with real tmux in CI, plus the hidden prerequisite of provisioning tmux ≥ 3.3 in CI images.)

**Success criteria** (must all hold before merge to `main`):
- Typing latency in a conversation pane is indistinguishable from Claude Code per the user's subjective judgment in Termius.
- Cursor lands exactly where the user types in Termius and local PTY.
- Opening and closing a conversation pane does not interrupt the agent's background work.
- Alerts arriving while a conversation is closed appear as indicators in the agent-list pane and persist until the user opens that conversation.
- `status_dashboard.ex` is deleted (not flagged off, deleted).
- `make all` is green.

#### Phase 2: Layout sophistication (future)

- Auto-rebalance pane widths when a new conversation pane opens (currently `select-layout tiled` is the Phase 1 baseline).
- Keyboard shortcuts in the agent-list pane for split-horizontal vs split-vertical when opening a conversation.
- Close-conversation keyboard shortcut.
- Cross-pane focus management (cycling, focus-by-agent-name).

#### Phase 3: Cross-pane communication and alert injection (future)

- Alert injection into specific conversation panes (separate from agent-list indicators).
- Cross-pane communication (one agent's pane can show an "agent X just emitted Y" marker).
- Phase 3 also re-examines the Claude Code Channels feasibility question from the brainstorm — only if we decide to embed Claude Code as the in-pane driver, which is not currently planned (see brainstorm Open Question 3).

## Alternative Approaches Considered

Three other paths were evaluated and ruled out during the brainstorm. Summarized here so future readers don't re-litigate them.

**Fix `status_dashboard.ex` in place.** The architecture is structurally wrong for an interactive composer: timer-driven full-frame render, keystrokes go through `GenServer.cast` that re-reads the log file from disk and re-renders synchronously, incremental-paint fallback silently degrades on SSH-only conditions. Audit rated surgical fix 3–4/5 with high residual bug surface. We would be back here in a month. Rejected. (See brainstorm "Why This Approach Not the Alternatives" — first paragraph.)

**Clean-room Elixir TUI rewrite (full-screen single window).** Possible in ~1 week with `Owl.LiveScreen` + a hand-rolled event loop. But the user's roadmap is tmux-orchestrated panes; building a full-screen TUI now and then carving it into panes later means rewriting twice. Ratatouille is dead (last commit October 2021; has the exact bugs we have). Bubble Tea via Port is 2–3 weeks honest, not 1. Rejected.

**Embed Claude Code as the conversation surface.** Attractive because Claude Code's typing and cursor are excellent. But Symphony's agents are Symphony-orchestrated long-running processes (driven by Symphony's event loop, with Symphony-injected tools), not raw Claude Code sessions. Spawning a fresh `claude` per conversation would create a new agent, not view an existing one. This option does not match the "agents run in the background, conversation pane is a view into them" constraint. Rejected. (Claude Code Channels feasibility remains a Phase 3 hypothetical only.)

**Phoenix LiveView `/console` in Safari on iPad.** Considered as a way to escape terminal-geometry pain entirely. Loses the terminal aesthetic and the tmux future. Out of scope.

**Burrito-bundled single binary.** Considered for pane subcommand packaging. Burrito's value is shipping to environments without Erlang; Symphony's users have Elixir installed (it's a developer tool). Skip for now.

## Reviewer Pushback on KD 8 (Resolved 2026-05-16: keep KD 8)

Two reviewers (architecture-strategist, code-simplicity-reviewer) independently pushed back on brainstorm Key Decision 8 (*one BEAM node per pane*). After analysis, the user resolved this 2026-05-16 by keeping KD 8 as written. The pushback and resolution are captured below for any future reader who wants to revisit it.

**The reviewers' argument:**

- Roughly 30% of the plan's surface area (`Distribution`, `~/.erlang.cookie` management, `ERL_EPMD_ADDRESS` configuration, `Node.connect`/`Node.monitor`, cross-node PubSub `pool_size` matching, integration test #2, half the §"Error & Failure Propagation" cases) exists *only* to support that decision.
- The justification — pub/sub future where agents subscribe to other agents and external events — is Phase 3 framing applied to Phase 1.
- A simpler alternative: single-BEAM with internal pane processes spawned by `PaneManager` via `Task.Supervisor.start_child/2`. The child process is the foreground of its tmux pane (just stdio). `Registry` for pane lookup. No distribution. No cookies. `Phoenix.PubSub` still used internally for events.
- Phase 1's §"State Lifecycle Risks" already states panes do not survive Symphony restarts, so the "isolation across BEAMs" benefit is unused.

**The brainstorm explicitly committed to KD 8 after the user weighed pros/cons.** This plan does not reverse that decision — it's surfaced here for the user to revisit if they want to.

Trade-offs of reversing (going single-BEAM):
- *Save:* ~5 modules, all distribution setup, cross-node integration test, cookie security work, EPMD multi-user concerns, ~30% of plan surface.
- *Lose:* Phase 1 ability for external agents (Phase 3 hypothetical) to consume events without an MCP bridge being built. Cross-node PubSub working in production is a thing-that-works-day-one vs a thing-to-build-later.
- *Migration path if reversed later:* the agent-native restructuring (`Conversations.attach/1`, `AgentEvents`, `AgentDirectory`, `PaneRPC`) keeps the interfaces stable. Switching the pane process from "separate BEAM node" to "in-process worker" affects implementation, not the surface contract. Reversing later costs ~1–2 days of plumbing, not a rewrite.

**Resolution (2026-05-16):** Keep KD 8. The "simpler" alternative trades platform infrastructure for application infrastructure — instead of one-time cookie/EPMD setup in the wrapper script, it requires designing and maintaining a custom Unix-socket wire protocol that grows with every new event type. Erlang distribution is the BEAM's idiomatic answer to "two BEAMs need to talk," and the agent-native restructuring (`Conversations.attach/1`, `PaneRPC`, `AgentEvents`) preserves reversibility: switching the pane transport from Erlang distribution to a custom socket later would be ~1–2 days of plumbing, not a rewrite.

**What the pushback successfully changed in this pass (all already applied):**
- `AgentEventBroadcaster` collapsed to a 25-LOC `AgentPubSub` wrapper.
- `LogSubscriber` folded into `Conversation`.
- `PaneWarmPool` promoted to Phase 1 to mitigate cold-start perception cliff.
- Cookie moved out of `ERL_AFLAGS` into `~/.erlang.cookie` (security).
- Composer submit changed from `:rpc.call` to `:rpc.cast` + optimistic echo.
- Transcript render coalescing added.
- Per-keystroke latency budget (<200μs) added to acceptance criteria.

The plan as it stands incorporates the pushback's correct points without abandoning KD 8.

## System-Wide Impact

### Interaction Graph

What happens when the user presses enter on an agent in the agent-list pane:

1. `AgentList.Input` receives the byte (`\r`), state machine transitions to "open conversation," calls `Tmux.spawn_pane_for(identifier)`.
2. `Tmux.spawn_pane_for/1` issues `Tmux.command("split-window -h -t <agent-list-pane-id> -P -F '#{pane_id}' bin/symphony conversation <id>")` and records the returned pane id with `PaneManager` for tracking.
3. `Tmux` writes the command to its control-mode socket, awaits `%begin/%end`, parses the returned pane id.
4. tmux spawns a new pane running `bin/symphony conversation <id>`. If a warm worker is available in `PaneWarmPool`, the pane attaches to it (claim + replace). Otherwise a fresh hidden BEAM is started.
5. The new BEAM runs `SymphonyPane.CLI.main/1`, ensures `:phoenix_pubsub` started, `Node.connect`s to Symphony, monitors Symphony's node, calls `Conversations.attach(<id>)` to subscribe to `"agent:<id>"`.
6. Concurrently the new pane's `Conversation` GenServer calls `PaneRPC.snapshot/0` (which internally uses `AgentDirectory.get_transcript_tail/2`) to get the recent transcript, hydrates its in-memory tail, and begins rendering. Subscribe-first-then-read ordering ensures no events are lost.
7. `PaneManager` records `identifier -> pane_id` in its state. Sends `{:pane_opened, identifier, pane_id}` to `AgentList.App` so the agent-list pane can update its indicator.

What happens when the user closes a conversation pane (Ctrl-D or tmux `kill-pane`):

1. The pane BEAM process receives EOF on stdin, exits cleanly. (Or: user kills the pane via tmux; the BEAM is SIGTERM'd.)
2. Two independent signals reach the main BEAM:
   - `:nodedown` from `:net_kernel.monitor_nodes` for the pane's hidden node → **authoritative signal**; `PaneManager` consumes this.
   - `%pane-died %<pane-id>` notification on the tmux control socket → `Tmux` forwards to `PaneManager`; logged for observability but not used to mutate state (per cited tmux issues #2483, #2882 — hooks are flaky).
3. `PaneManager` drops the mapping on `:nodedown` and broadcasts `{:pane_closed, identifier}` on the `"agents:running"` topic.
4. `AgentList.App` re-renders the agent-list pane (the agent's row no longer shows the "open" indicator).
5. The agent itself (orchestrator + agent_runner) is unaffected. It keeps running and emitting events to `"agent:<id>"` — the topic just has no subscribers until the user reopens the conversation.

### Error & Failure Propagation

- **Pane BEAM startup fails to connect to Symphony.** `Node.connect/1` returns `false` → `SymphonyPane.CLI.main/1` logs to stderr and `System.halt(1)`. tmux pane shows the error briefly before closing. The agent-list pane sees the `%pane-died` notification and cleans up. User sees agent-list pane still healthy.
- **Symphony main BEAM dies while pane is connected.** Pane receives `{:nodedown, _}` from `Node.monitor`. `Conversation` renders "Symphony disconnected" banner and exits. tmux pane closes. User sees the agent-list pane is also gone (since the agent-list pane runs in the main BEAM).
- **tmux session dies.** Symphony's `Tmux` port detects EOF on stdout, restarts itself (one retry with backoff). If the session is genuinely gone, the wrapper script's tmux-attach loop exits and the user can re-launch.
- **`Phoenix.PubSub` cross-node fan-out fails (pool_size mismatch, etc.).** Symptom: messages broadcast on the main node don't arrive on the pane node. Tests cover this by broadcasting from a test process and asserting receipt on a peer node. Caught before merge.
- **AgentRunner panic during a turn.** Existing supervision (orchestrator monitors agent pids) handles this — the orchestrator removes the entry from `state.running`, broadcasts `{:running_changed, ...}` on `"agents:running"`. The conversation pane subscribed to `"agent:<id>"` receives no further events; `Conversation`'s in-memory transcript tail reads from disk if needed. Pane stays open showing the final transcript.
- **Distribution surface (accepted risk).** Once a pane node connects, Erlang distribution exposes the entire main BEAM to it (`:rpc.call` against any module). The `PaneRPC` chokepoint is a documentation/audit convention, not enforcement — the threat model assumes any process running as the same UID is trusted (cookie auth backs this). If Symphony ever runs panes at a reduced trust level, custom auth via `:net_kernel.allow/1` would need to be added.

### State Lifecycle Risks

- **Stale pane mapping.** `PaneManager` treats `:nodedown` as the authoritative pane-closed signal (per cited tmux issues #2483, #2882 — same logic that argued against tmux hooks). `%pane-died` is logged but not used for mapping mutation. Reconciliation from `Node.list(:hidden)` happens only on `PaneManager` restart, which Phase 1 does not exercise (no restart-recovery requirement).
- **Cookie file corruption.** If `~/.erlang.cookie` is empty, unreadable, wrong UID, or shorter than 16 bytes, the wrapper exits with a clear error before starting BEAM. No partial-startup state.
- **Half-open distribution connection.** Erlang's `Node.connect/1` is synchronous; either it returns `true` (connected, monitored) or `false` (failed cleanly). No orphan state.
- **Transcript replay on pane reopen.** When the user closes and reopens an agent's conversation, `Conversation` subscribes to `"agent:<id>"` FIRST, buffers incoming events, then reads the on-disk log file (`<workspace>/logs/agent.md`) via `AgentDirectory.get_transcript_tail/2`, and merges by timestamp before first paint. Subscribe-first-then-read ordering eliminates the race.
- **Composer optimistic-echo double-render.** Composer renders the user's message locally on submit and also broadcasts it on `"agent:<id>"`. Without de-dup, `Conversation` would see both. Mitigation: composer attaches a client-generated `msg_id` to the optimistic entry; the broadcast carries the same `msg_id`; `Conversation` checks pending-echo IDs and replaces the optimistic entry instead of appending a duplicate.

### API Surface Parity

Symphony exposes three interfaces that today share `StatusDashboard` for surfacing updates: the CLI dashboard, the Phoenix LiveView dashboard, and (indirectly) the on-disk log. The cutover affects each:

- **CLI dashboard:** completely replaced by agent-list pane + per-agent panes. This is the change.
- **Phoenix LiveView dashboard (`SymphonyElixirWeb.DashboardLive`):** still subscribes to `"observability:dashboard"` via `ObservabilityPubSub`. That topic remains. We add `AgentPubSub` as a parallel publisher; `ObservabilityPubSub.broadcast_update/0` continues to fire when the orchestrator state changes. **No web-side changes required, but explicit verification step in Phase 1 task list.**
- **On-disk log (`<workspace>/logs/agent.ndjson` and `agent.md`):** unchanged. `AgentEventLog.write/3` continues to be called from `AgentRunner.codex_message_handler/4`. The new `AgentPubSub.broadcast_transcript/2` is a sibling call.

### Integration Test Scenarios

Unit tests with mocks won't catch cross-layer issues. The plan must include at least these integration scenarios:

Phase 1 ships three integration scenarios. Two more (50-iteration race fuzz; control-mode disconnect recovery) were cut from Phase 1 per simplicity review — they exercise behaviors a single human user does not produce.

1. **End-to-end pane spawn.** Launch the main BEAM with distribution and a real tmux session. From a test process, call `Tmux.spawn_pane_for("MT-123")` (which internally issues the `split-window` command; the spawned pane process calls `Conversations.attach("MT-123")` itself). Assert (a) tmux reports the new pane exists, (b) a new hidden BEAM node is in `Node.list(:hidden)`, (c) the new node has subscribed to `"agent:MT-123"`. Tear down by killing the pane.
2. **Cross-node PubSub delivery.** Start two BEAM nodes (main + peer) with the same cookie (via `~/.erlang.cookie`) and matching `pool_size: 1`. Broadcast `{:transcript_event, ...}` on the main node on topic `"agent:X"`. Assert the peer node's subscriber receives it within 100ms.
3. **Pane exits cleanly when Symphony goes away.** Start main BEAM + pane. Kill the main BEAM. Assert the pane BEAM exits within 2s (no hang). This is intentional — Phase 1 does not try to keep panes alive across server restarts.

Deferred to later phases:

- *50-iteration race fuzz of open/close* — over-engineered for Phase 1's single-user workload.
- *tmux control-mode disconnect recovery* — covered by a manual `kill -9 tmux` smoke check during Termius verification; automated test deferred.

These are bash-driven `mix test` integration tests living in `elixir/test/integration/`. They require tmux ≥ 3.3 to be installed in CI — **provisioning the CI image with tmux is an explicit Phase 1 task**.

## Acceptance Criteria

### Functional Requirements

- [ ] `bin/symphony agents` launches the new architecture: tmux session created, agent-list pane visible, no `status_dashboard.ex` in the call graph.
- [ ] Pressing enter or space on a selected agent in the agent-list pane spawns a new conversation pane to the right.
- [ ] The conversation pane shows the agent's recent transcript on open (read from `<workspace>/logs/agent.md`) and subsequent transcript events stream in via `Phoenix.PubSub`.
- [ ] Typing in the conversation pane's composer is responsive (no perceptible per-keystroke lag).
- [ ] Submitting the composer (enter without modifiers) sends the message via `AgentChat.send/2` → `Orchestrator.send_operator_message/2` and the agent receives it.
- [ ] Closing the conversation pane (Ctrl-D or `tmux kill-pane`) does not affect the running agent.
- [ ] Alerts emitted on an agent whose conversation pane is closed show up as an indicator on that agent's row in the agent-list pane.
- [ ] Reopening a conversation pane after an alert fires while it was closed shows the transcript history including the alert event.
- [ ] `status_dashboard.ex` and `terminal_input.ex` are deleted (not flagged off).
- [ ] Multiple conversation panes can be open simultaneously; each renders independently and does not affect the others.

### Non-Functional Requirements

- [ ] User confirms in Termius on iPad: typing latency is indistinguishable from Claude Code.
- [ ] User confirms in Termius on iPad: cursor lands exactly where typed, no offset.
- [ ] No autowrap artifacts when the user types near terminal edges.
- [ ] **Per-keystroke render budget:** `Viewport.render/2` measured via `:timer.tc/1` averages <200μs over a 100-keystroke trace (asserted in test or recorded in `bench/keystroke.exs`).
- [ ] BEAM cold-start latency on pane open is ≤ 200ms wall-clock from key press to first rendered frame on a warm-pool claim (revised down from 1500ms after `PaneWarmPool` promoted to Phase 1). First-spawn-after-startup (no warm slot yet) ≤ 1500ms.
- [ ] tmux must be present; wrapper refuses to start with a clear error if it is not.
- [ ] Distribution is bound to 127.0.0.1; no listening on external interfaces.

### Quality Gates

- [ ] `make all` is green (`format --check-formatted`, `mix specs.check`, `mix credo --strict`, `mix test --cover`, `mix dialyzer`).
- [ ] `mix specs.check` confirms every new public `def` in `lib/` has an `@spec` (per `elixir/AGENTS.md:37–46`).
- [ ] PR body matches `.github/pull_request_template.md` exactly; validate with `mix pr_body.check`.
- [ ] The 3 Phase 1 integration test scenarios in §"Integration Test Scenarios" pass in CI with a real tmux ≥ 3.3.
- [ ] `README.md`, `elixir/README.md`, and `WORKFLOW.symphony.local.md` are updated in the same PR (per `elixir/AGENTS.md:60–64`).
- [ ] `SPEC.md` is updated to describe the two-pane-types model and tmux dependency.

## Success Metrics

- **Typing fidelity:** the user's subjective verdict in Termius is "feels like Claude Code." This was the binding constraint from the brainstorm.
- **Code volume:** `status_dashboard.ex` (2,345 LOC) + `terminal_input.ex` (355 LOC) = 2,700 LOC removed. New modules total well under 2,700 LOC.
- **Architectural fit:** Phase 2 (auto-rebalance, more shortcuts) and Phase 3 (cross-pane communication) should be incremental additions on top of Phase 1, not rewrites.
- **Bug surface:** the cursor-offset and typing-lag bugs do not recur. Future TUI bugs are scoped to one pane type rather than the whole UI.
- **Future readiness:** when the user later wants agents to subscribe to other agents' events or PR/issue events, that work is "add new producers and consumers on `Phoenix.PubSub`," not "re-architect the CLI."

## Dependencies & Prerequisites

**External dependencies (added):**
- `tmux >= 3.3` on the host machine. Earlier versions lack the control-mode notifications we rely on (`%pane-died` stable since 2.8 but `%window-pane-changed` and full hook parity require 3.3). The wrapper checks version on startup.
- `owl ~> 0.13` in `mix.exs`.
- Erlang epmd (already present with Erlang/OTP). Bound to 127.0.0.1.

**Internal dependencies (already exist, no change required):**
- `Phoenix.PubSub ~> 2.2.0` (default PG2 adapter, cross-node-capable once nodes are connected).
- `AgentChat.send/2` and `Orchestrator.send_operator_message/2` (already per-agent — brainstorm Open Question 1 resolved).
- `AgentEventLog.write/3` for on-disk logging (unchanged).
- `AgentRunner.codex_message_handler/4` (gains a sibling PubSub broadcast call).
- Existing escript build pipeline (`mix.exs:107–114`, `bin/symphony`).

**Convention dependencies:**
- `elixir/AGENTS.md` `@spec` requirement for public defs.
- `make all` merge gate.
- Doc updates in same PR (root `README.md`, `elixir/README.md`, `WORKFLOW.symphony.local.md`, `SPEC.md`).

**Environment dependencies:**
- `~/.config/symphony/cookie` file (created by wrapper on first run).
- `~/.config/symphony/state` file (written by wrapper with `SYMPHONY_NODE` and `SYMPHONY_PID`).
- `ERL_AFLAGS`, `ERL_EPMD_ADDRESS`, `SYMPHONY_NODE` exported to all BEAM processes by the wrapper.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| BEAM cold-start latency feels bad on pane open | Low (was Medium) | Medium | `PaneWarmPool` pre-spawns one warm worker at startup (cuts first-spawn from ~1500ms to ~200ms); pane writes "Connecting…" placeholder before app start. Promoted from "deferred" to Phase 1 after performance-oracle flagged 1500ms as past the perception cliff. |
| LiveView dashboard silently breaks during cutover | Low | Medium | Every `StatusDashboard.notify_update/0` replacement preserves the `ObservabilityPubSub.broadcast_update/0` call. Integration test asserts LiveView still receives updates. |
| Detached Termius session leaves agent-list pane in unknown state | Medium | Low | tmux session persists across SSH disconnects; the agent-list pane's BEAM keeps running as foreground of its pane. Documented behavior: reconnecting in Termius and `tmux attach` resumes the same pane. No automatic action required from Symphony. |
| `-sname symphony` collides with another user on shared host | Medium | Medium | Wrapper uses `-sname symphony-${USER}` and random session suffix; documented in §"Modified modules → scripts/agents". |
| PubSub burst from chatty agent overwhelms pane mailbox | Medium | Medium | `Conversation` coalesces transcript events into 16ms frames via `Process.send_after`. If mailbox depth exceeds a threshold (TBD during implementation), drop oldest events with a "… N events dropped" indicator. |
| Cookie file race / leakage | Low | High | Wrapper uses `umask 0177` + atomic temp-write + UID validation. Cookie lives in `~/.erlang.cookie` (not `ERL_AFLAGS`) so it does not appear in `/proc/<pid>/environ`. |
| `body` of composer message interpreted unsafely downstream | Unknown | High | **Verify before merge:** read `AgentChat.send/2`, `Orchestrator.send_operator_message/2`, `AgentEventLog.write/3` and confirm `body` is treated as opaque text (no shell interp, no eval). Filter control characters except `\n`/`\t` before write. Cap input at 64 KiB. |
| tmux control-mode connection unstable in some environments | Low | High | Reconnect logic in `Tmux` module; fall back to `System.cmd("tmux", [...])` (argv list, NOT shell string — sidesteps argv-injection risk on identifiers and pane ids) for one-shot commands during reconnect window. |
| Termius still has rendering bugs we haven't seen | Medium | High | User-driven verification in Termius is a merge gate. If specific issues arise, the small per-pane surface (one log + one composer) is dramatically easier to fix than the previous monolith. |
| Cross-node PubSub fan-out doesn't work as documented | Low | High | Integration test #2 ("Cross-node PubSub delivery") catches this before merge. |
| Pane node fails to find Symphony's node via env var | Low | Medium | Wrapper writes `~/.config/symphony/state` as fallback discovery; pane self-bootstraps if `SYMPHONY_NODE` env var is missing. |
| Cookie-file permissions wrong → distribution fails silently | Low | Medium | Wrapper enforces mode 0400 on cookie file and validates on every startup. |
| Existing LiveView dashboard breaks during cutover | Low | Medium | LiveView subscribes to `"observability:dashboard"`, which remains. `ObservabilityPubSub.broadcast_update/0` continues to be called. Integration test asserts LiveView still updates. |
| Coverage gate (100%) blocks merge while new modules are stabilizing | Low | Low | `mix.exs` `ignore_modules` list temporarily includes new modules; tighten as tests mature. |
| Hard cutover removes safety net; if new architecture has unforeseen issues, fallback is `git revert` | Low | Medium | Work on fresh branch off `main`; merge only after user-driven Termius verification. Revert is one commit. |

## Resource Requirements

Single-engineer plan over **10–14 working days** (revised from initial 5–8 day estimate after architecture review). No team coordination, no third-party services, but one infrastructure change: CI image must add tmux ≥ 3.3. User availability for end-of-Phase-1 Termius verification is required.

## Future Considerations

- **Phase 2: layout sophistication.** Custom layout math replacing `select-layout tiled`. Keyboard shortcuts (split-h, split-v, close). Cycle focus by agent name.
- **Phase 3: cross-pane communication.** One agent's pane can show "agent X just emitted event Y" markers. Alert injection into specific conversation panes (separate from agent-list indicators). Re-examine Claude Code Channels feasibility — only if embedding Claude Code as the in-pane driver becomes attractive.
- **Pub/sub expansion.** Agents subscribe to events from other agents and from PRs/issues. The topic schema introduced in Phase 1 (`"agent:<id>"`, `"agents:running"`) is extensible: add `"issue:<number>"`, `"pr:<number>"` etc. as producers come online (webhook handlers in Phoenix).
- **Pane warm pool.** If cold-start latency becomes the dominant pain point, keep N pre-booted pane workers inside Symphony's main BEAM and "claim" one when the user opens a conversation (stream over tmux pane stdio). Avoids per-spawn BEAM boot. Listed as a mitigation in brainstorm Key Decision 10.
- **Mix release.** If escript cold-start ever crosses ~1s on the user's slowest device, migrate `bin/symphony` from escript to a Mix release with `rel/overlays/bin/symphony` and `rel/overlays/bin/symphony-pane` as separate entry-point scripts. Faster boot, full ERTS bundled.
- **Burrito.** Only if Symphony ever ships to non-developer machines (no Erlang installed). Not currently a goal.
- **Cookie rotation.** Phase 1 ships a single-cookie-forever model. If the cookie is ever leaked or needs to be rotated (e.g., accidental commit, capture in a debugger dump), the only Phase 1 remedy is manual deletion of `~/.erlang.cookie` plus a Symphony restart, which kills all open panes. Future enhancement: `bin/symphony cookie rotate` that regenerates the file, signals running panes to reconnect, and rolls the cookie cleanly. Not Phase 1.
- **Warm pool sizing.** Phase 1 ships a pool of 1, which masks first-spawn cold-start but not the second concurrent open. If users routinely open multiple conversations in rapid succession, increase the pool size and add eager replenishment. The `PaneWarmPool` module is designed for this growth.

## Documentation Plan

Updated in the same PR:

- `/home/applekid/github/its-applekid/symphony/README.md` — top-level "what is Symphony" section gains a mention that the CLI uses tmux.
- `/home/applekid/github/its-applekid/symphony/elixir/README.md` — replace any references to `status_dashboard.ex` with the new architecture.
- `/home/applekid/github/its-applekid/symphony/elixir/local-workflows/WORKFLOW.symphony.local.md` — update with the new launch flow.
- `/home/applekid/github/its-applekid/symphony/SPEC.md` — document the two-pane-types model, tmux dependency, PubSub topic schema.
- `/home/applekid/github/its-applekid/symphony/AGENTS.md` — note tmux requirement and the new pane subcommand.
- `/home/applekid/github/its-applekid/symphony/elixir/AGENTS.md` — note new modules under `lib/symphony_elixir/` and `lib/symphony_pane/`.
- New file: `/home/applekid/github/its-applekid/symphony/docs/handoffs/2026-05-XX-cli-pane-cutover-handoff.md` written at end of Phase 1 documenting the cutover for any future agent picking this up.
- New file: `/home/applekid/github/its-applekid/symphony/docs/agent-event-api.md` — schema-first reference for the PubSub event topology, payload `@type` declarations, and the `Conversations.attach/1` / `AgentDirectory` / `PaneRPC` primitive surfaces. Keyed for agent consumption (terse, schema-first). Becomes the canonical reference for any future MCP bridge.

Old docs that become misleading and need updating or marking superseded:
- `docs/brainstorms/2026-05-16-cli-terminal-typing-requirements.md` (superseded by this plan).
- `docs/plans/2026-05-16-cli-terminal-typing-plan.md` (superseded).
- `docs/handoffs/2026-05-15-alerts-handoff.md` "2026-05-16 Follow-Up" section (the bugs described there are now resolved by the rearchitecture, not by surgical fix).

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md](../brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md)
  - Key decisions carried forward: two-pane-types model (KD 1), agents as background processes (KD 2), alerts in agent-list pane (KD 3), retire `status_dashboard.ex` (KD 4), Phase 1 includes Symphony-driven pane spawning (KD 5), hard cutover (KD 6), global composer retired (KD 7), pane subcommand is a separate BEAM node via Erlang distribution (KD 8), tmux is a hard dependency (KD 9), BEAM cold-start latency accepted (KD 10).
  - Stated assumptions validated by repo research: per-agent chat-injection (resolved — already exists), named-node setup (false today, plan adds it), PubSub cross-node adapter (PG2 default, no change needed), tmux on host (Termius is just SSH client), per-agent topics (greenfield work).
  - Open Question 2 resolved by external research: tmux control mode is the right invocation mechanism (not shell-out + hooks).

### Internal References

- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/status_dashboard.ex:1–2345` — full module to be deleted.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/terminal_input.ex:1–355` — input loop to be deleted; CSI parser at lines 256–305 copied into new modules.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/orchestrator.ex:1001–1003` — agent spawn (Task.Supervisor).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/orchestrator.ex:1224` — `StatusDashboard.notify_update/0` call site to replace.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/orchestrator.ex:1409` — `Orchestrator.send_operator_message/2` (the per-agent chat-send path the pane will use).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/orchestrator.ex:1636` — `handle_call` for `:send_operator_message`.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/agent_chat.ex:10` — `AgentChat.send/2` (called by composer).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/agent_runner.ex:49–55` — `codex_message_handler/4` (gains PubSub broadcast).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/agent_event_log.ex:11` — on-disk log writer (unchanged).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/alerts.ex:93` — `StatusDashboard.notify_update/0` call site to replace.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir.ex:23–51` — Application supervision tree.
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir_web/observability_pubsub.ex:1–25` — existing PubSub wrapper (kept).
- `/home/applekid/github/its-applekid/symphony/elixir/lib/symphony_elixir/cli.ex:36–227` — escript entry point to rewrite for argv dispatch.
- `/home/applekid/github/its-applekid/symphony/elixir/mix.exs:14–57` — coverage `ignore_modules` to update.
- `/home/applekid/github/its-applekid/symphony/elixir/mix.exs:81–97` — deps list (add `:owl`).
- `/home/applekid/github/its-applekid/symphony/elixir/mix.exs:107–114` — escript config.
- `/home/applekid/github/its-applekid/symphony/scripts/agents:236–264` — `ensure_built/1` (escript build).
- `/home/applekid/github/its-applekid/symphony/scripts/agents:411–429,519` — foreground/background launch.
- `/home/applekid/github/its-applekid/symphony/AGENTS.md:22–23,42–43` — wrapper convention, workspace path layout.
- `/home/applekid/github/its-applekid/symphony/elixir/AGENTS.md:15–64` — `@spec` requirement, `make all` gate, doc-update convention.

### Review Sources (deepen-plan pass)

- **architecture-strategist** — flagged separate-BEAM-per-pane as the primary unforced complexity; recommended PaneAPI contract module; noted missed `Application.stop/2` call site; re-estimated effort.
- **code-simplicity-reviewer** — flagged `AgentEventBroadcaster` and `LogSubscriber` as unnecessary; recommended cutting integration tests #4 and #5; identified `Phoenix.PubSub` choice as load-bearing on the separate-BEAM decision.
- **performance-oracle** — flagged BEAM cold-start at 500–1500ms as past the perception cliff; recommended warm pane pre-spawn + "Connecting…" placeholder as Phase 1; recommended `:rpc.cast` for composer submit; recommended transcript render coalescing.
- **security-sentinel** — flagged cookie via `ERL_AFLAGS` as leaking via `/proc/<pid>/environ`; recommended `~/.erlang.cookie`; recommended umask/atomic-write/UID-validation for cookie file; recommended explicit `PaneRPC` chokepoint module; recommended composer length cap and control-char filtering.
- **agent-native-reviewer** — flagged conflation of "open conversation" (UI) with "subscribe to events" (data primitive); recommended split into `Conversations.attach/1` + `Tmux.spawn_pane_for/1`; flagged human composer submissions not broadcasting symmetrically; recommended `AgentEvents` contract module and `AgentDirectory` read-side primitives.
- **agent-native-architecture skill** — recommended `AgentDirectory` as MCP-shaped primitive module; anticipated Phase 3 MCP/HTTP bridge; emphasized treating the agent-list pane as one of many possible subscribers.

### External References

- [tmux Control Mode wiki](https://github.com/tmux/tmux/wiki/Control-Mode) — `%begin`/`%end`/`%output`/`%pane-died` protocol.
- [tmux CHANGES (master)](https://raw.githubusercontent.com/tmux/tmux/master/CHANGES) — feature availability per version.
- [iTerm2 tmux integration](https://iterm2.com/documentation-tmux-integration.html) — canonical control-mode consumer.
- [Distributed Erlang — OTP docs](https://www.erlang.org/doc/system/distributed.html) — distribution semantics, hidden nodes, dynamic names.
- [Elixir Node module docs](https://hexdocs.pm/elixir/Node.html) — `Node.start/2`, `Node.connect/1`, `Node.monitor/2`.
- [net_kernel — Erlang/OTP](https://www.erlang.org/doc/apps/kernel/net_kernel.html) — `monitor_nodes/2`, `:hidden` filter.
- [Phoenix.PubSub 2.2.0](https://hexdocs.pm/phoenix_pubsub/2.2.0/Phoenix.PubSub.html) — subscribe/broadcast API.
- [Phoenix.PubSub.PG2 2.2.0](https://hexdocs.pm/phoenix_pubsub/2.2.0/Phoenix.PubSub.PG2.html) — cross-node adapter, `pool_size` constraint.
- [mix escript.build — Mix 1.19.5](https://hexdocs.pm/mix/Mix.Tasks.Escript.Build.html) — `app: nil`, `embed_elixir`, `strip_beams`.
- [Owl 0.13.0 docs](https://hexdocs.pm/owl/) — `Owl.Data.tag/2`, `Owl.IO.columns/0`. (`Owl.LiveScreen` evaluated and rejected for the conversation pane viewport — wrong fit.)
- [EEF: Exposed EPMD security](https://erlef.org/blog/eef/epmd-public-exposure) — informs `ERL_EPMD_ADDRESS=127.0.0.1` decision.
- [tmux issue #2483: pane-died inconsistent](https://github.com/tmux/tmux/issues/2483) — argues for control mode over hooks.
- [tmux issue #2882: pane-exited wrong pane](https://github.com/tmux/tmux/issues/2882) — same.

### Related Work

- `docs/handoffs/2026-05-15-alerts-handoff.md` — original symptoms documented.
- `docs/brainstorms/2026-05-16-cli-terminal-typing-requirements.md` — earlier (now superseded) attempt to fix in place.
- `docs/plans/2026-05-16-cli-terminal-typing-plan.md` — earlier (now superseded) plan.
- Commits `601f9cc`, `9e4f722` — failed surgical fixes that this plan replaces.
