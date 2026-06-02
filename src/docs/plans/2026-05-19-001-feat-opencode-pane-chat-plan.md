---
title: feat: Replace conversation pane with opencode chat surface
type: feat
status: completed
date: 2026-05-19
origin: elixir/docs/opencode-pane-brainstorm.md
revised: 2026-05-20
revision_history:
  - 2026-05-19 v1 — initial draft
  - 2026-05-19 v2 — Mechanism D plugin dropped; `Aiur.Opencode.Protocol` isolation per R12; bridge as dedicated Bandit listener; queued-pane via existing `resume_agent/1`; security review SEC-001..006 integrated
  - 2026-05-20 v3 — turn-end signal sourced from `:turn_completed` in CodingAgent (not opencode `session.idle`) per FEAS-01; `Aiur.AgentPubSub.broadcast_turn_completed/1` added (FEAS-03); Bandit option fix to `thousand_island_options: [num_connections: …]` (FEAS-02); TranscriptRelay subscribes before reading file with timestamp-based dedup (FEAS-04); `:user` filter explicit in U4 streaming (FEAS-06); `/models` lockdown via opencode permission rules (ADV-R2-10); queued-pane retry race resolved with single-flight gate (ADV-R2-07); Bandit bind failure stays-up policy (ADV-R2-08)
  - 2026-05-20 v4 — second-round review applied: `opencode_os_pid` rename + `Port.info(:os_pid)` wiring; ISO8601 parse in promoted decoder; per-workspace bearer tokens; turn-id scoping on `broadcast_turn_completed/2`; idle watchdog on SSE stream; `:turn_input_required` handling; orphan-reap PID identity validation + read-before-materialize reorder; BridgeSupervisor `restart: :temporary`; queued-pane synthetic system message; placeholder shell during cold-start; `chat_completion_chunk` moved out of Protocol; bind-failure operator alert; composite dedup key `{timestamp, sequence}`; Authorization-header log redaction; honest cost accounting in Overview; Dependency Posture subsection added
---

# feat: Replace conversation pane with opencode chat surface

## Overview

Replace Aiur's hand-rolled in-pane chat (`lib/aiur_pane/*` + supporting RPC) with [opencode](https://opencode.ai) as the chat surface in each issue's tmux pane. The Codex/Claude background agent is unchanged — Aiur still spawns it as a stdio Port and routes operator messages through `AgentChat.send/3`. Only the pane *rendering* and *input* layer changes: instead of a custom BEAM pane process, the pane runs `opencode attach` against an Aiur-spawned `opencode serve`, and opencode "calls the model" through an Aiur-hosted OpenAI-compatible HTTP shim that relays into the existing agent pipeline.

The user-visible benefit is a richer chat experience that we don't have to build: proper scrollback, themes, undo, attention notifications, search, multi-line editing.

**This is a maintenance-boundary swap, not a free win.** We delete four custom UI files (`conversation.ex`, `composer.ex`, `viewport.ex`, `cli.ex`) plus `PaneRPC` and `PaneWarmPool`, and accept an integration boundary in their place: `Aiur.Opencode.Protocol` (isolation), `Bridge` + `BridgeSupervisor` + `ChatCompletions` (HTTP shim), `PaneSession` + `PaneSupervisor` (orchestration), `Server` (Port lifecycle), `TranscriptRelay` (replay + live publish), `EventConsumer` (SSE inbound), `WorkspaceSetup` (config materialization), plus a version-bump diff burden each time opencode releases. The new surface is roughly comparable in size to the deleted one. The reason to make the swap is that the deleted files were ours to evolve forever; the new surface is mostly *adapter* code against an external project that will ship most chat-UI improvements without our involvement. Maintenance cost lives in the same envelope; engineering attention moves to agent orchestration where it matters more.

This work lands as a single end-to-end PR.

---

## Problem Frame

The current pane (`lib/aiur_pane/conversation.ex`, `composer.ex`, `viewport.ex`) was bolted on to what was originally a read-only dashboard. It carries an entire raw-mode TTY input loop, geometry polling, manual rendering, and a cross-node RPC channel just to show a chat. It is brittle, lacks features operators reasonably expect (scrollback search, copy, history), and its maintenance pulls effort away from the work that actually matters — agent orchestration.

opencode (the TUI in `sst/opencode`) is a high-quality terminal chat UI already, with a clean client/server split where the server owns chat state and exposes an HTTP+SSE API. The server is configurable to call any OpenAI-compatible "model"; Aiur can be that model. With this in place, the operator gets opencode's chat, and the underlying AI is still the operator's Codex/Claude CLI exactly as it is today.

The challenge is the integration glue: opencode's design assumes it talks to an LLM, and we have to bend it into a chat front-end for an external agent runtime without ever letting opencode actually call an LLM. The brainstorm doc settled the bending strategy ("Mechanism D: Aiur is opencode's provider + a thin decorative plugin") and the lifecycle ("lazy spawn on first pane open, kill on close, cold-start on every reopen"). This plan is the implementation. Per a 2026-05-19 planning conversation, the plugin half of Mechanism D is dropped from v1 — the SSE event consumer covers the same ground without the volatile TS/Bun surface.

opencode is an external project under active development. To avoid the codebase being "ripped apart" on every opencode release, every opencode-specific shape (event names, message-part schema, config-file template, CLI flag strings) lives behind a single isolation module (`Aiur.Opencode.Protocol`). When opencode bumps a version, the diff lands in that one file.

---

## Requirements Trace

- R1. Replace the in-process pane UX with opencode without changing the Codex/Claude agent runtime or its `WORKFLOW.md` configuration. (origin: 2026-05-19 single-agent decision)
- R2. Operator text typed in opencode must reach `Aiur.AgentChat.send/3` with `delivery_policy: :checkpoint, fallback: :queue_next`. (origin: Mechanism D)
- R3. The pane chat must show all prior agent activity on every open. If the agent has been running, the full transcript up to pane-open time is backfilled. If the issue is queued (no agent yet), the backfill is empty. (origin: "if a user kicks off several agents, waits a minute, and then opens the agent chat, they should already see a minute's worth of history"; clarified per coherence review F4)
- R4. Free-running **agent** activity (assistant, command, and alert events that arrive while the operator is not typing) must continue to appear in the open chat. User-typed text is rendered locally by opencode and not republished by Aiur. (origin: 2026-05-19 backfill decision; clarified per coherence review F3)
- R5. opencode must never produce its own LLM response — every "model call" routes through Aiur to the background agent. (origin: Mechanism D, single-agent)
- R6. The opencode server is spawned lazily on first pane open per issue and torn down on close; reopens are cold starts that replay history from `logs/agent.ndjson`. (origin: 2026-05-19 server lifetime decision)
- R7. Aiur transcript tags map to opencode message parts: `user`→user text, `agent`→assistant text, `cmd`→native tool-call + tool-result parts, `system`/`alert`→styled assistant text with markdown prefix. (origin: 2026-05-19 tag-mapping + cmd-render decisions)
- R8. Alerts are surfaced both as an opencode TUI toast (live) and as a chat-entry message (persisted across reopens). (origin: 2026-05-19 alert routing decision)
- R9. Opening a pane for a queued (not-yet-running) issue is allowed; the first operator submit calls `Aiur.Orchestrator.resume_agent/1` (which returns `{:ok, :started}` for queued issues) and the typed text becomes the first operator message. (origin: 2026-05-19 queued-pane decision; API verified via grep)
- R10. Existing security/UX behavior of operator-input handling is preserved: 64 KiB body cap, control-character stripping with exact regex parity to `Aiur.PaneRPC`, `:checkpoint` + `:queue_next` delivery policy. (origin: existing `Aiur.PaneRPC.send_operator_message/2` is the documented audit chokepoint)
- R11. `lib/aiur_pane/*` and its CLI subcommand are removed; the existing `Aiur.Conversations.open/2` facade keeps working for callers like `Aiur.AgentList.App` Enter handling. (origin: replacement, not addition)
- R12. The integration absorbs opencode releases without per-update code churn outside a single `Aiur.Opencode.Protocol` isolation module. (origin: 2026-05-19 planning conversation — opencode is an external project under active development)
- R13. The "turn ended, close the stream" signal must be sourced from the **Aiur agent backend** (`:turn_completed` event from `Aiur.Codex.CodingAgent` / `Aiur.Claude.CodingAgent`), not from opencode's own session bus. The opencode `session.idle` event cannot serve this role because the very SSE response that opencode is consuming is what keeps its session busy — the signal would be circular. (origin: 2026-05-20 feasibility review FEAS-01)
- R14. The turn-end signal must be **scoped to the current turn** so a late or replayed `:turn_completed` broadcast cannot close an unrelated current stream. The bridge handler captures a per-turn opaque id at submit time; the broadcast carries it; the handler matches before closing. (origin: 2026-05-20 v3 adversarial round 2 — ADV-R3-Stale)
- R15. Bridge authentication must distinguish **which workspace** the caller is routing for, not merely "some Aiur instance". A per-workspace token (generated per `materialize/5`) prevents one workspace's opencode from forging a `model=aiur/issue-OTHER` request that the bridge would otherwise accept. (origin: 2026-05-20 v3 security round 2 — SEC-007)
- R16. Operator messages sent via the existing dashboard endpoint (`POST /api/v1/:identifier/messages`) and operator messages sent via the bridge SSE stream must not interleave into the same open pane's response. The pane's response stream filters to its own turn-id (R14); operator-initiated turns from other surfaces still queue and run normally, but their transcript broadcasts are not re-emitted into another caller's open SSE response. (origin: 2026-05-20 v3 adversarial round 2 — ADV-R3-Concurrent)

---

## Scope Boundaries

- Not changing the Codex/Claude `CodingAgent` behaviour, `AgentChat`, `AgentRunner`, `Orchestrator`, `AgentPubSub`, `AgentEvents`, or queue-restore semantics. The shim adapts to these contracts; the contracts are not relaxed.
- Not changing the agent's prompt-building (`Aiur.PromptBuilder`), workflow front-matter format (other than adding an `opencode:` section), or the `agent.ndjson` event schema.
- Not introducing a second AI runtime. There is one agent per issue (the existing Codex/Claude CLI). opencode's own model loop is bypassed by routing every model call through Aiur.
- **Not extending opencode features.** No `/models` switching support in pane sessions, no custom slash commands, no MCP wiring, no opencode theme/keybind customization beyond what defaults provide. Pane sessions use the one configured provider (the Aiur bridge). The rendered `opencode.json` declares **only** the Aiur provider with no other models, and opencode's permission block forbids provider/model changes mid-session, so `/models` either fails closed or has nothing to switch to — closing the data-egress risk in ADV-R2-10. Any future opencode-feature surface area requires an explicit follow-up decision.

### Deferred to Follow-Up Work

- Remote workers (`worker_host != nil`): `Aiur.AgentEventLog.write/3` is a no-op for remote workers, so `logs/agent.ndjson` lives on the remote host and the local backfill reader cannot reach it. v1 explicitly targets `worker_host == nil`; remote-worker support gets its own follow-up.
- (Resolved in v3 via opencode.json config — see Scope Boundaries above.) Operator-initiated `/models` switching is now blocked at config time, not just by documentation.
- An `.opencode/plugins/aiur.ts` plugin: the brainstorm proposed a thin plugin for in-chat decoration; on review, the SSE event consumer (U7) covers every event the plugin would have handled (`permission.asked`, `tool.execute.*`, `session.idle`) without introducing a TS/Bun surface that must be re-tested on every opencode update. A plugin can be added later if a specific decoration need surfaces.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur_pane/conversation.ex`, `composer.ex`, `viewport.ex`, `cli.ex` — the pane scaffold this PR retires. Pattern: pane is its own BEAM child, RPCs back to Aiur. After this PR, all four files are deleted.
- `elixir/lib/aiur/pane_manager.ex` — owns tmux slot allocation, `respawn-pane -k`, anchor-chain fallback for slot cycling (PR #51 is fragile here — do not regress). The command string is the only thing that changes for opencode panes; slot logic passes through.
- `elixir/lib/aiur/pane_manager.ex:338-379` — `wrap_with_unique_node/2` sets `ERL_AFLAGS` to give pane BEAMs distribution names. opencode is not a BEAM child; the wrap must be bypassed for opencode commands.
- `elixir/lib/aiur/conversations.ex` — symmetric `open/close` + `attach/detach` facade. `default_command/1` is the right surface to change; do not introduce a parallel facade.
- `elixir/lib/aiur/pane_rpc.ex` — the cross-node call chokepoint with the 64 KiB body cap and control-char strip (`elixir/lib/aiur/pane_rpc.ex:93`). The shim must mirror these constraints when receiving model calls. The regex parity matters per security review SEC-006 — match exactly, no `/u` flag.
- `elixir/lib/aiur/agent_chat.ex` — `AgentChat.send/3` is the single facade for operator-to-agent routing; on success it broadcasts the `:user` transcript event itself. The shim must use the 3-arity form with `delivery_policy: :checkpoint, fallback: :queue_next`.
- `elixir/lib/aiur/orchestrator.ex:1600-1604` — `Aiur.Orchestrator.resume_agent/1` returns `{:ok, :resumed | :started} | {:error, term()}`. The `:started` arm handles queued issues that have not yet run; this is the correct routing path for R9.
- `elixir/lib/aiur/alerts.ex:39-50` — `Aiur.Alerts.emit_system/2` for Aiur-originated system alerts, `Aiur.Alerts.emit_custom/3` for custom-named alerts with caller-supplied messages. There is no `emit/3` — earlier draft of this plan was wrong.
- `elixir/lib/aiur/agent_runner.ex:68-98` — `codex_message_handler/4` is where `agent.ndjson` is appended and `AgentPubSub.broadcast_transcript/2` is called. Both surfaces drive opencode population (file → backfill, PubSub → live). v3 also wires this handler to broadcast a new turn-completion signal when the underlying CodingAgent emits `:turn_completed`.
- `elixir/lib/aiur/agent_runner.ex` — `transcript_event_from/1` currently private; this plan promotes it (or moves the codex-event decoder to `Aiur.AgentEvents`) so the backfill replayer can use the same decoder the live path uses.
- `elixir/lib/aiur/codex/coding_agent.ex:472,692,786` and `elixir/lib/aiur/claude/coding_agent.ex:373,499,593` — sites where the existing backend emits `:turn_completed` (or returns `{:ok, :turn_completed}`). These are the source-of-truth for R13's turn-end signal: the SSE response stream in U4 ends when this signal arrives via the new PubSub helper, not when opencode's `session.idle` fires.
- `elixir/lib/aiur/agent_pubsub.ex` — currently exposes `broadcast_transcript/2`, `broadcast_alert/2`, `broadcast_running_change/1`, `broadcast_status_change/2`, `subscribe_agent/1`. There is **no** generic `broadcast/2`. v4 adds `broadcast_turn_event/3` (event tag: `:turn_completed | :turn_failed | :turn_cancelled | :turn_input_required`; payload carries `turn_id`) and folds turn-event delivery into the existing per-identifier topic that `subscribe_agent/1` already returns (per FEAS-03 + R14 + ADV-R3-InputRequired).
- `elixir/lib/aiur/agent_event_log.ex` — best-effort, write-failures-swallowed ndjson writer. The backfill reader must be tolerant of `json_safe` shape (string keys, ISO8601 timestamps, missing fields).
- `elixir/lib/aiur/issue_log.ex` — DynamicSupervisor-managed per-issue ring buffer + log file. Not the canonical transcript for opencode (that's `agent.ndjson`), but useful precedent for per-issue process registration via `Aiur.IssueLog.Registry`.
- `elixir/lib/aiur/codex/coding_agent.ex:239-264` — `start_port/2` pattern: `Port.open({:spawn_executable, "bash"}, [args: ["-lc", command], cd: workspace])`. The opencode server lifecycle module copies this pattern verbatim.
- `elixir/lib/aiur/codex/config.ex`, `elixir/lib/aiur/claude/config.ex` — agent-backend config readers. `Aiur.Opencode.Config` mirrors this shape.
- `elixir/lib/aiur/config/schema.ex` — Ecto schema with `embeds_one` for each section. Adding `opencode:` requires a new embed; `test/support/test_support.exs` must also emit it in `write_workflow_file!/2` so existing tests don't fail validation.
- `elixir/lib/aiur/http_server.ex` + `elixir/lib/aiur_web/endpoint.ex` — existing Bandit + Phoenix host, single port, basic-auth-by-default. The opencode bridge is a *separate* Bandit listener under the top-level supervisor (decision logged below).
- `elixir/lib/aiur.ex:42-58` — top-level supervisor tree. The new `Aiur.Opencode.Bridge` is a peer child of `Aiur.HttpServer`; the new `Aiur.Opencode.PaneSupervisor` (DynamicSupervisor) is a peer that holds per-pane sessions.
- `elixir/lib/aiur/workspace.ex` — the only existing producer of files inside a workspace (besides `agent.ndjson`/`agent.md`). The new opencode bootstrap step (`opencode.json`) lives alongside `run_before_run_hook/3`.
- `elixir/test/aiur/app_server_test.exs:104-132` — the fake-binary-shell-script pattern for testing Port-spawned external processes. The opencode-server tests reuse this pattern with a fake `opencode` shell script.
- `elixir/test/aiur_pane/conversation_test.exs` — the pane test pattern using `write_fun:` + `input_fun:` injection. Replaced by the new pane-session tests in this PR.
- `elixir/mix.exs` — `req ~> 0.5` is already declared. Per scope review SG-02, use `req`'s `into:` streaming for SSE consumption rather than calling `Finch.stream/4` directly; `Finch` is a transitive dep of `req` and should not be addressed as a public API.

### Institutional Learnings

- `elixir/docs/opencode-pane-brainstorm.md` — the dated decisions are binding constraints, not suggestions.
- `elixir/docs/logging.md` — every new module emits structured `key=value` logs including `issue_identifier` and a stable `opencode_session_id=<sid>` field for grep-friendliness.
- `elixir/AGENTS.md` — every public `def` in `lib/` needs an adjacent `@spec`; `mix specs.check` is the gate. Runtime config goes through `Aiur.Config`, not ad-hoc `System.get_env`.
- `elixir/AGENTS.md` — workspace safety: never run agent cwd in the source repo; all workspaces stay under `Aiur.Config.workspace_root()`. Same applies to `opencode serve` cwd.
- Pause/resume queue-restore is sensitive (`agent_runner.ex:445-452`); the shim must not invent a parallel claim path. Operator messages flow through the existing `AgentChat.send/3` → `Orchestrator.send_operator_message/3` queue.
- `AgentChat.send/3` already broadcasts the `:user` transcript event on success. The transcript publisher (live PubSub → opencode session) must filter out `:user` events so the chat doesn't double-echo the line opencode already renders locally.

### External References

- opencode docs: https://opencode.ai/docs/server/ (HTTP API), https://opencode.ai/docs/providers (custom OpenAI-compatible providers), https://opencode.ai/docs/cli (`opencode serve`, `opencode attach`), https://opencode.ai/docs/config (workspace config shape).
- OpenAI Chat Completions API streaming format (used as the wire format opencode expects from a custom OpenAI-compatible provider).
- Vercel AI SDK `@ai-sdk/openai-compatible` adapter (the package opencode uses to call custom providers).

---

## Key Technical Decisions

- **Shim hosts on a dedicated Bandit listener under the top-level supervisor**, not the existing `AiurWeb.Endpoint`. Rationale: clean separation from dashboard auth (`:dashboard_auth` pipeline), independent SSE connection pool, independent supervision lifecycle, durable for future shape changes (remote opencode, dev container, lazy spawn). Discussed at length in the 2026-05-19 planning conversation.
- **Single isolation module (`Aiur.Opencode.Protocol`) owns every opencode-specific shape.** Event-name constants (`session.idle`, `permission.asked`, `tool.execute.before/after`, etc.), message-part builders, the `opencode.json` template, the verified opencode version range, and the CLI flag strings all live here. Every other module imports from `Protocol`; no opencode-specific string literal appears elsewhere. When opencode releases break a shape, the diff is one file. (origin: R12, 2026-05-19 planning conversation)
- **One Aiur bridge listener serves all workspaces; routing by encoded model name.** Each workspace's `opencode.json` declares its default model as `aiur/issue-<safe_id>`. When opencode calls `POST /v1/chat/completions`, the shim parses the model field to derive the issue identifier and validates the parsed identifier against `~r/\A[a-zA-Z0-9._-]+\z/` (the same character class as `Aiur.Workspace.safe_identifier/1`) before routing. Provider config is workspace-level in opencode (verified during brainstorm), so per-workspace files give per-workspace routing automatically.
- **Bridge requests are authenticated via a per-Aiur-startup shared secret.** Aiur generates a fresh UUID v4 on boot, embeds it as `apiKey` in each workspace's `opencode.json`, and rejects any bridge request whose `Authorization: Bearer <token>` does not match. This closes the container/WSL2 hole that pure "bind to 127.0.0.1" doesn't cover, at zero operator cost — opencode's `@ai-sdk/openai-compatible` adapter already sends the configured `apiKey`. (origin: security review SEC-001)
- **`req` is the HTTP client** for Aiur → opencode calls (session create, message post, toast, abort). Already in `mix.exs`. The SSE consumer uses `Req.get/2` with `into: fun` for streaming — not direct Finch calls. No new dependency. (origin: scope review SG-02)
- **Backfill replays `logs/agent.ndjson` event-by-event** using the existing codex-event decoder (`transcript_event_from/1` promoted to public). This guarantees the rendered chat matches what a live operator would have seen. Live updates continue via `AgentPubSub` after the initial replay. The replay and live phases are a single GenServer (see U6) — same pipeline, only the source differs.
- **Backfill subscribes to PubSub before reading the file, then dedups by `event.timestamp`.** Subscribing first eliminates the gap between "finished reading file" and "subscribed for live updates" where an in-flight event could be dropped (FEAS-04). Live messages that arrive during replay buffer in the GenServer mailbox; after replay completes, each buffered live message is checked against the highest replayed `timestamp` and dropped if it was already in the file. Aiur's `agent.ndjson` and PubSub broadcasts use the same `Aiur.AgentEvents.transcript_event/3` timestamps, so dedup is exact.
- **Turn-end signal: a new `Aiur.AgentPubSub.broadcast_turn_event/3` is emitted from `Aiur.AgentRunner.codex_message_handler/4`** whenever the underlying CodingAgent's `:turn_completed`, `:turn_failed`, `:turn_cancelled`, or `:turn_input_required` event arrives. The chat-completions SSE handler subscribes to the per-identifier topic via existing `Aiur.AgentPubSub.subscribe_agent/1` and pattern-matches `{:turn_event, identifier, event_tag, %{turn_id: ^turn_id}}` to close the stream on a turn-id match. opencode's `session.idle` event is ignored — it cannot serve this role (R13). (origin: FEAS-01, refined v4 by R14 + ADV-R3-InputRequired)
- **The `system` tag renders as an assistant text part with a `**system:**` markdown prefix** during backfill and live. Plain markdown; no opencode `system` role mid-conversation (that role is reserved for opening context in opencode's UI).
- **opencode session lifecycle is tied to a `Aiur.Opencode.PaneSession` GenServer**, supervised under `Aiur.Opencode.PaneSupervisor` (DynamicSupervisor). The session GenServer owns the opencode server Port, the SSE consumer, and the transcript replayer/publisher for that pane. On terminate, all three die together.
- **The `wrap_with_unique_node/2` BEAM-distribution wrap is bypassed for opencode commands.** opencode is not a BEAM child; setting `ERL_AFLAGS` is dead weight and adds attack surface.
- **No `.opencode/plugins/aiur.ts` plugin in v1.** The brainstorm proposed one for in-chat decoration. On review the SSE event consumer already covers every event the plugin would handle (`permission.asked`, `tool.execute.*`, `session.idle`). Dropping the plugin removes Aiur's most opencode-version-volatile surface (per R12) and a TypeScript/Bun footprint that this repo would otherwise need to maintain. A plugin can be added later if a specific decoration need surfaces. (origin: scope review SG-05 + R12)
- **Workspace bootstrap is idempotent and rewrites `opencode.json` on every pane open.** The file is gitignored. The bridge URL and the shared-secret token are interpolated via `Jason.encode!/1` (not raw EEx `<%= %>`), making the rendered JSON injection-safe even if `bridge_host` or `identifier` contained quote/backslash characters. (origin: security review SEC-002)
- **Verified opencode version range is recorded in `Aiur.Opencode.Protocol` as a module attribute** and logged at startup (`opencode --version`). When operators are running an unverified version, Aiur logs a warning at boot; the bridge does not refuse to start. This is documentation-of-intent, not a hard gate. (origin: R12)
- **A snapshot test on the rendered `opencode.json`** lives alongside `workspace_setup_test.exs`. If opencode evolves its config schema and we update the template, the snapshot diff is the human-readable signal. (origin: R12)
- **Bandit listener uses `thousand_island_options: [num_connections: …]`, not `transport_options: [max_connections: …]`.** The latter is not a valid Bandit option and would silently no-op; the former is the public Thousand Island knob that Bandit exposes. (origin: FEAS-02)
- **On Bandit bind failure, only the opencode-bridge subtree fails — the dashboard stays up.** The bridge is mounted under a small `Aiur.Opencode.BridgeSupervisor` (`:rest_for_one`, `max_restarts: 1` over `5_000` ms) that wraps just the Bandit child. If the bind fails (port collision, etc.), this subtree's permanent-restart escalation hits the cap and shuts down *only* the bridge; the top-level `Aiur.Supervisor` does **not** see the failure and the dashboard remains reachable. A `:warning` log identifies the configured port and suggests overriding `opencode.bridge_port`. New panes attempting to open after the bridge has died return a clear error to the operator. (origin: ADV-R2-08)
- **Single-flight gate prevents the queued-pane retry race.** When the chat-completions handler sees `{:error, :no_running_agent}` from `AgentChat.send` it calls `Orchestrator.resume_agent/1`, which is a single-flight operation today (verified). The retry path uses `Aiur.AgentChat.send` with the same `:checkpoint` policy after a short await on the per-identifier topic for either a `:running` status broadcast or a 5s timeout. Subsequent retries are bounded to one — the handler never loops between resume and send. (origin: ADV-R2-07)
- **The chat-completions streaming loop filters out `:user` transcript events from the per-identifier PubSub topic.** opencode renders the operator's own input locally; re-emitting the `:user` event Aiur broadcasts would echo the message twice. This filter is in addition to the U6 TranscriptRelay filter — both surfaces consume the same PubSub topic and both must drop `:user`. (origin: FEAS-06)
- **Turn-id scoping (R14).** `broadcast_turn_event/3`'s payload carries a `turn_id` (UUID v4 generated by the bridge handler when it issues `AgentChat.send/3`, and threaded to `AgentRunner` via the message kind so that when the underlying CodingAgent eventually emits `:turn_completed`, the rebroadcast carries the matching id). The bridge handler closes the stream only on a broadcast whose `turn_id` matches the one it stamped. Late or replayed broadcasts with stale ids are ignored. Transcript-chunk filtering uses the same id: `AgentEvents.transcript_event/3` also stamps the live `turn_id` on each broadcast, and only events tagged with the current `turn_id` flow into the SSE response (R16 — concurrent dashboard turns broadcast on the topic but carry a different `turn_id`, or no `turn_id` at all if originated outside the bridge).
- **Per-workspace bearer token (R15).** `WorkspaceSetup.materialize/5` generates a fresh UUID v4 per workspace and writes it into that workspace's `opencode.json` as `apiKey`. The bridge maintains an ETS table keyed by `{token, identifier}`; an incoming request's `Authorization: Bearer <token>` plus parsed `model=aiur/issue-<id>` must match an ETS entry. The per-startup global secret approach (v3) is replaced. ETS entries are removed when the corresponding `PaneSession` terminates. This closes ADV-R3 cross-pane injection without adding operator burden — `@ai-sdk/openai-compatible` already sends the configured `apiKey`.
- **Idle watchdog on SSE stream.** The bridge handler arms a 10-minute idle watchdog (`Process.send_after(self(), :turn_watchdog, 600_000)`) after `AgentChat.send/3` succeeds and refreshes it on every chunk emit. On fire, the handler emits a synthetic `finish_reason: "timeout"` chunk and closes the stream. Catches the case where the underlying CodingAgent OOM-kills, hangs, or otherwise never emits `:turn_completed` / `:turn_failed` / `:turn_cancelled`. (origin: ADV-R3-Watchdog)
- **`:turn_input_required` extends the turn-end family.** Codex `coding_agent.ex:574-581` emits `:turn_input_required` when an approval prompt is pending; Aiur surfaces it as a discrete chat-completion finish with `finish_reason: "tool_calls"` and a synthetic text chunk explaining "awaiting approval". `broadcast_turn_completed/2` becomes `broadcast_turn_event/3` with an explicit event-tag argument (`:turn_completed | :turn_failed | :turn_cancelled | :turn_input_required`); the handler closes the stream on any of the four. The Claude backend does not emit `:turn_cancelled` or `:turn_input_required` today (lines 373, 499, 593 cover `:turn_completed` and the failure-state returns) — `AgentRunner.codex_message_handler/4` translates Claude-side returns into normalized broadcasts so backend asymmetry is contained in one place.
- **Composite dedup key in TranscriptRelay (FEAS-04, refined).** Replay-vs-live dedup uses a composite `{timestamp, sequence}` key where `sequence` is a monotonically-increasing per-identifier counter added to `Aiur.AgentEvents.transcript_event/3`'s output. The promoted `transcript_event_from/1` parses ISO8601 string timestamps from `agent.ndjson` via `DateTime.from_iso8601/1` (the current `timestamp_for/1` at `agent_runner.ex:230` falls through to `DateTime.utc_now()` on non-DateTime input, which would assign fresh timestamps to replayed lines and silently break dedup — FEAS-R3-Timestamp). Sequence numbers in ndjson are written by `AgentEventLog.write/3`; sequence numbers on live broadcasts are stamped by `AgentEvents.transcript_event/3` at broadcast time.
- **BridgeSupervisor isolation strategy.** The supervisor wraps the Bandit listener with `restart: :temporary` on the child spec. If Bandit fails (bind error, crash), the supervisor exits and `Aiur.Supervisor` does **not** restart it — the bridge stays down for the rest of the Aiur process's lifetime. This is the right behavior for both bind failures (a port is wedged, retrying won't help) and post-startup crashes (something is structurally broken; flapping restarts mask it). New pane opens after a dead bridge return a clear error via `Aiur.Alerts.emit_custom("opencode.bridge_unavailable", message, identifier: identifier, severity: :error)`. Adversarial review noted that the v3 `:rest_for_one, max_restarts: 1, max_seconds: 5` strategy was both wrong for bind isolation (parent supervisor would still cascade) and wrong for transient crashes (one hiccup permanently kills bridge); `restart: :temporary` resolves both. (origin: ADV-R3-RestartCap + FEAS-R3-BridgeIso)
- **opencode_os_pid (renamed from `aiur_pid`).** The orphan-reap field in `opencode.json`'s `aiur_metadata` is the **opencode server's OS PID**, obtained via `:erlang.port_info(port, :os_pid)` after `Server.await_ready/1`. `WorkspaceSetup.materialize/5` is called twice per pane open: once before Server.start_link (writes `opencode_os_pid: nil`), once after Server.await_ready (rewrites with the real OS PID). The reap path reads the *prior* opencode.json's PID *before* the new materialize-1 overwrites it. Before sending SIGTERM, the reap validates the PID's identity via `/proc/<pid>/comm` matching `opencode` (Linux) or `ps -o comm= -p <pid>` (other Unix); reap is skipped on platforms where neither works. This closes both the BEAM-vs-OS PID ambiguity and the PID-reuse risk. (origin: FEAS-R3-PidShape + ADV-R3-PidReuse + SEC-R3-PidValidation)
- **Decoder promotion target.** `transcript_event_from/1` (currently private in `AgentRunner`) is promoted to **`Aiur.AgentEvents.transcript_event_from/1`** (not a new `TranscriptDecoder` module). This is the natural home — `AgentEvents` already owns the broadcast-time shape and the new helper owns the inverse decode. One module per concern. (origin: COH-R3-DecoderHome)
- **`chat_completion_chunk/2` lives in `Aiur.Opencode.ChatCompletions`, not `Protocol`.** The OpenAI chat-completion-chunk shape is an OpenAI-standard concern, not opencode-specific; future Vercel-AI-SDK drift touches `ChatCompletions`, not the opencode-version-isolation module. Protocol retains opencode event names, message-part builders, the opencode.json template, CLI flag strings, and version range. (origin: SG-R3-Protocol)
- **Queued-pane synthetic system message and cold-start placeholder.** When the relay finds no `agent.ndjson`, it posts one synthetic `assistant` message to the opencode session: `**system:** This issue is queued. Type a message to start the agent.` The operator never sees a blank chat for a queued issue. During the spawn → health-poll → replay window (1–2 s typical), the tmux pane is respawned immediately with a shell that prints `Loading chat history…\n` and blocks on a named pipe until `PaneSession` signals ready, then `exec`s `opencode attach`. Operator never sees a blank terminal waiting. (origin: DESIGN-R3-Empty + DESIGN-R3-Loading)

---

## Open Questions

### Resolved During Planning

- **Where does the shim live?** → Dedicated Bandit listener under `Aiur.Supervisor`. See Key Technical Decisions.
- **How does the shim route a call to the right issue?** → Model name encoding `aiur/issue-<safe_id>`, validated against the `safe_identifier` regex before routing.
- **What HTTP client?** → `req` for both unary calls and SSE consumption (`into:` streaming).
- **How does the backfill reader decode events?** → Reuses `transcript_event_from/1` (promoted to public). Backfill is the same pipeline as live publish — same module (U6).
- **How is the `system` tag rendered?** → Assistant text part with `**system:**` markdown prefix.
- **Does the pane process still need BEAM-node distribution wrap?** → No. Bypass `wrap_with_unique_node/2` for opencode commands.
- **What does the v1 plugin do?** → No plugin in v1. SSE consumer covers it.
- **Where do generated files live in the workspace?** → `<workspace>/opencode.json`. Gitignored.
- **How is queued-pane auto-start wired?** → `Aiur.Orchestrator.resume_agent/1` returns `{:ok, :started}` for queued issues; the shim invokes it on `{:error, :no_running_agent}` from `AgentChat.send/3`. No new orchestrator API needed.
- **What's the auth model for the bridge?** → `Authorization: Bearer <token>` against a per-Aiur-startup UUID shared secret embedded in `opencode.json`.
- **How is opencode update churn contained?** → Single `Aiur.Opencode.Protocol` module owns every opencode-specific shape. Every other module imports from it.
- **Where does the turn-end signal come from?** → `:turn_completed` (also `:turn_failed`, `:turn_cancelled`, `:turn_input_required`) emitted by the existing `CodingAgent` backend. `Aiur.AgentRunner` rebroadcasts to PubSub via `broadcast_turn_event/3` with the matching `turn_id`. opencode's `session.idle` is *not* used (would be circular per R13). (origin: FEAS-01, refined v4 by R14 + ADV-R3-InputRequired)
- **Does `Aiur.AgentPubSub` already have a generic broadcast?** → No. v4 adds `broadcast_turn_event/3` as a named helper (event tag + payload with `turn_id`). No generic `broadcast/2` is introduced. (origin: FEAS-03)
- **What Bandit option caps connections?** → `thousand_island_options: [num_connections: 50]` on the Bandit child spec. `transport_options:` is not a valid Bandit knob. (origin: FEAS-02)
- **How is `/models` locked down?** → `opencode.json` declares only the Aiur provider with no other models; opencode's `permission` block forbids provider changes. There is nothing to switch to. (origin: ADV-R2-10)

### Deferred to Implementation

- **Exact OpenAI streaming chunk shape opencode expects.** The Vercel AI SDK's `openai-compatible` adapter follows the standard `chat.completion.chunk` format, but a couple of fields (e.g., `tool_calls` in deltas) are version-sensitive. The implementation verifies against an actual opencode build during U4; any deviation is documented in `Aiur.Opencode.Protocol`.
- **Behavior when the agent emits a tool-call across many small Codex events.** The shim must aggregate the partial tool-call into a single OpenAI `tool_call` delta. Algorithm detail; verify during implementation.
- **`logs/agent.ndjson` rotation/size.** For very long-running issues, replaying the entire file may be slow. Acceptable in v1; revisit if it becomes painful.
- **Concurrent in-flight model calls for the same identifier.** Per security review SEC-004, the handler returns HTTP 429 if a second concurrent stream arrives for an identifier already streaming. The exact mechanism (per-identifier semaphore via a Registry, or per-publisher state check) is implementer's call.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

The end-to-end flow when an operator opens a pane for issue `MT-123`:

```mermaid
sequenceDiagram
    participant Op as Operator
    participant AL as AgentList.App
    participant PM as PaneManager
    participant PS as Opencode.PaneSession
    participant WS as Opencode.WorkspaceSetup
    participant OS as opencode serve (Port)
    participant TR as Opencode.TranscriptRelay
    participant EC as Opencode.EventConsumer
    participant TM as tmux
    participant OT as opencode TUI
    participant BR as Opencode.Bridge (shim)
    participant AC as AgentChat / Orchestrator
    participant PB as AgentPubSub

    Op->>AL: Enter on issue MT-123
    AL->>PM: open_conversation("MT-123")
    PM->>PS: start_child(PaneSession, MT-123)
    PS->>WS: materialize(workspace, port, token)
    WS->>WS: write opencode.json (Jason-encoded values)
    PS->>OS: Port.open(opencode serve --port P)
    PS->>OS: poll /global/health until ready
    PS->>OS: POST /session  (issue title)
    OS-->>PS: {session_id}
    PS->>TR: start(MT-123, session_id, base_url)
    TR->>TR: replay agent.ndjson via Aiur.Opencode.Protocol shapes
    TR->>OS: POST /session/:id/message (×N events)
    TR->>PB: subscribe_agent(MT-123)
    PS->>EC: start(base_url)
    PS->>PM: ready (attach_url + session_id)
    PM->>TM: tmux respawn-pane with `opencode attach …`
    TM->>OT: spawn
    OT->>OS: HTTP /session/:id (load history)
    OT-->>Op: render chat with backfilled history

    Op->>OT: type "what's the status?"
    OT->>OS: send prompt
    OS->>BR: POST /v1/chat/completions (model=aiur/issue-MT-123, Bearer token)
    BR->>BR: check Authorization, validate body (64 KiB, ctrl chars)
    BR->>BR: parse model field, validate safe_identifier
    BR->>AC: AgentChat.send("MT-123", text, checkpoint, queue_next)
    AC->>PB: broadcast(:user transcript)
    PB-->>TR: (filtered — TR drops :user)
    Note over OT: opencode renders user echo locally
    AC->>AC: enqueue; AgentRunner runs turn at checkpoint
    AC->>PB: broadcast(:assistant + :command transcripts)
    PB->>TR: events
    TR->>OS: POST /session/:id/message (each delta as message part)
    OS->>OT: SSE updates
    OT-->>Op: render assistant chunks
    Note over AC: CodingAgent emits :turn_completed
    AC->>PB: broadcast_turn_event(identifier, :turn_completed, %{turn_id})
    PB-->>BR: {:turn_event, identifier, :turn_completed, %{turn_id}}
    BR-->>OS: close streaming chunk channel
    OS-->>OT: stream ends

    Op->>OT: q (close)
    TM-->>PM: %pane-died
    PM->>PS: stop
    PS->>OS: Port.close
    PS->>TR: stop
    PS->>EC: stop
```

The shim's `POST /v1/chat/completions` handler does **not** generate the streamed assistant content from the request body; it merely hands the latest user message to `AgentChat.send/3` and then **streams the response back from PubSub**, converting each `:assistant` and `:command` transcript event into an OpenAI chat-completion chunk until the `{:turn_completed, identifier, _}` message arrives on the same per-identifier topic. `:user` transcript events are filtered out of the response stream (opencode renders the operator's input locally). The turn-end signal is sourced from the underlying `CodingAgent` backend's `:turn_completed` event — *not* opencode's `session.idle` — because opencode's session is held busy by the very SSE response it is consuming (R13).

---

## Output Structure

```
elixir/
├── lib/
│   └── aiur/
│       └── opencode/
│           ├── protocol.ex                # isolation layer: event names, message shapes, opencode.json template, version range
│           ├── config.ex                  # WORKFLOW.md reader (peer of Aiur.Codex.Config)
│           ├── api_client.ex              # req-based client for opencode HTTP API
│           ├── bridge.ex                  # Plug.Router for the shim listener
│           ├── chat_completions.ex        # POST /v1/chat/completions SSE handler
│           ├── server.ex                  # opencode serve Port lifecycle GenServer
│           ├── transcript_relay.ex        # backfill + live PubSub→opencode publisher (merged)
│           ├── event_consumer.ex          # opencode SSE → Aiur PubSub/alerts
│           ├── workspace_setup.ex         # render opencode.json with Jason-encoded values
│           ├── pane_supervisor.ex         # DynamicSupervisor for PaneSession children
│           └── pane_session.ex            # per-pane orchestration GenServer
├── test/
│   └── aiur/
│       └── opencode/
│           ├── protocol_test.exs
│           ├── config_test.exs
│           ├── api_client_test.exs        # fake opencode HTTP server
│           ├── bridge_test.exs
│           ├── chat_completions_test.exs
│           ├── server_test.exs            # fake opencode shell-script binary, like app_server_test.exs
│           ├── transcript_relay_test.exs
│           ├── event_consumer_test.exs
│           ├── workspace_setup_test.exs   # includes opencode.json snapshot test
│           └── pane_session_test.exs
└── docs/
    └── plans/
        └── 2026-05-19-001-feat-opencode-pane-chat-plan.md   # this file
```

Files deleted in this PR:

```
elixir/lib/aiur_pane/cli.ex
elixir/lib/aiur_pane/conversation.ex
elixir/lib/aiur_pane/composer.ex
elixir/lib/aiur_pane/viewport.ex
elixir/lib/aiur/pane_rpc.ex                  # no callers after cutover (verified via grep)
elixir/lib/aiur/pane_warm_pool.ex            # scaffold-only no-op; no callers (verified via grep)
elixir/test/aiur_pane/                       # entire subtree
```

---

## Implementation Units

- [ ] U1. **`opencode:` config schema and reader**

**Goal:** Add an `opencode:` section to the WORKFLOW.md schema and an `Aiur.Opencode.Config` module mirroring `Aiur.Codex.Config` / `Aiur.Claude.Config`. Without this, every downstream module would have to read env vars directly — which the project's AGENTS.md explicitly forbids.

**Requirements:** R1 (no env-leak), R10 (preserve config-via-WORKFLOW.md discipline)

**Dependencies:** None.

**Files:**
- Modify: `elixir/lib/aiur/config/schema.ex` (add `Aiur.Config.Schema.Opencode` embed alongside `Codex`/`Claude`)
- Create: `elixir/lib/aiur/opencode/config.ex`
- Modify: `elixir/test/support/test_support.exs` (emit `opencode:` block in `write_workflow_file!/2` so unrelated tests don't trip on changeset validation)
- Modify: `elixir/WORKFLOW.md` (document the new section)
- Test: `elixir/test/aiur/opencode/config_test.exs`

**Approach:**
- Schema fields with defaults: `command: "opencode"`, `bridge_port: 4097`, `bridge_host: "127.0.0.1"`, `serve_args: []`, `model_prefix: "aiur"`. Keep additive — every field has a default so existing workflows don't need to declare `opencode:` to keep working. The default bridge port `4097` is one above opencode's default `4096` (avoiding confusion with the opencode server's own listener); allow override via WORKFLOW.md.
- `Aiur.Opencode.Config` exposes `command/0`, `bridge_port/0`, `bridge_host/0`, `model_for_issue/1`, `validate!/0`. Implements `@behaviour Aiur.AgentConfig` for parity.
- `validate!/0` checks that the configured `command` resolves on PATH (via `System.find_executable`); fail-fast with a clear message if it doesn't, with override hint pointing at `opencode.command` in WORKFLOW.md.
- `serve_args` is operator-trusted (documented as such in WORKFLOW.md docs). No allow-list validation — the operator controls their own WORKFLOW.md.

**Execution note:** Start by adding the schema embed and the test-support emitter; run the full test suite to confirm no unrelated tests broke before writing the new module's logic.

**Patterns to follow:**
- `elixir/lib/aiur/codex/config.ex` for module shape, `validate!/0` shape, and `section_value/1` helper.
- `elixir/lib/aiur/config/schema.ex` `Codex` embed for changeset structure.

**Test scenarios:**
- Happy path: WORKFLOW.md with no `opencode:` section parses with all defaults intact.
- Happy path: WORKFLOW.md with `opencode.bridge_port: 5000` overrides the default.
- Edge case: blank `opencode.command` value falls back to default `"opencode"`.
- Error path: `validate!/0` returns `{:error, _}` when `command` resolves to a non-existent executable.
- `model_for_issue/1` produces the expected `"aiur/issue-<safe_id>"` string for an identifier with safe characters and one with unsafe characters (the same `safe_id` transform as `Aiur.Workspace`).

**Verification:**
- `mix test elixir/test/aiur/opencode/config_test.exs` passes.
- Full suite green: existing config-touching tests don't regress.

---

- [ ] U2. **`Aiur.Opencode.Protocol` isolation layer**

**Goal:** The single module that owns every opencode-specific shape — event-name constants, message-part builders, `opencode.json` template, CLI flag strings, verified version range. This is the per-R12 isolation boundary: when opencode updates a shape, the diff is here, not scattered.

**Requirements:** R7, R12

**Dependencies:** None.

**Files:**
- Create: `elixir/lib/aiur/opencode/protocol.ex`
- Test: `elixir/test/aiur/opencode/protocol_test.exs`

**Approach:**
- Module attributes for verified-version range: `@verified_min "0.x.y"`, `@verified_max "0.z.w"`. Update on every opencode bump that's been smoke-tested.
- Event-name constants: `@event_session_idle "session.idle"`, `@event_session_error "session.error"`, `@event_permission_asked "permission.asked"`, `@event_tool_before "tool.execute.before"`, `@event_tool_after "tool.execute.after"`. Each gets a `@spec`-d accessor (`session_idle/0` etc.) so callers don't pattern-match on string literals.
- Message-part builders, one public function per tag in R7:
  - `user_message_part(text)` → `%{role: "user", parts: [%{type: "text", text: text}]}`
  - `assistant_text_message(text)` → `%{role: "assistant", parts: [%{type: "text", text: text}]}`
  - `assistant_command_message(command, output, opts)` → `%{role: "assistant", parts: [%{type: "tool_call", name: "bash", input: %{command: command}}, %{type: "tool_result", output: output, output_meta: opts}]}`
  - `system_message_part(body)` → assistant text part with `**system:** ` prefix
  - `alert_message_part(body)` → assistant text part with `**alert:** ` prefix
- `opencode_json/1` accepts `%{bridge_url:, bridge_token:, identifier:, opencode_os_pid:}` and returns the rendered `opencode.json` map. All interpolation happens inside the function — callers pass values, not strings. The resulting map is `Jason.encode!`-ed by the workspace bootstrap step. The map declares exactly one `provider` (the Aiur bridge) and exactly one `model` per ADV-R2-10. An `aiur_metadata` key carries the **opencode-server OS PID** (`opencode_os_pid`, nilable on the first `materialize/5` call before the Port is opened — re-materialized after `Server.await_ready/1` with the real PID from `:erlang.port_info(port, :os_pid)`); opencode ignores unknown top-level keys.
- `serve_command(port, host, extra_args)` and `attach_command(url, session_id)` return the exact shell command strings opencode CLI expects.
- (v4) **`chat_completion_chunk/2` is NOT in Protocol** — it lives in `Aiur.Opencode.ChatCompletions` (U4) since the OpenAI chunk shape is an OpenAI-standard concern, not an opencode-specific one. Protocol stays focused on opencode-version-isolated shapes.

**Patterns to follow:**
- Existing isolation modules in the codebase: `Aiur.AgentEvents` plays a similar role for transcript-event shapes. Mirror that lightweight style.

**Test scenarios:**
- Happy path: each public function returns the documented shape; spot-check the JSON serialization round-trip via `Jason.encode!/1` + `Jason.decode!/1`.
- Snapshot: `opencode_json/1` output for a fixed input matches a checked-in JSON fixture exactly. This is the test that catches accidental shape drift.
- Snapshot variant: `opencode_json/1` with `opencode_os_pid: nil` (first-write case) is valid and accepted by opencode (the field appears as `"opencode_os_pid": null`).
- Lockdown: snapshot assertion that the rendered config declares exactly one `provider` (`aiur`) and exactly one `model` (`issue-<safe_id>`). No `anthropic`, `openai`, or other built-in provider key appears.
- Edge case: `assistant_command_message/3` with empty output produces a `tool_result` with empty `output`.
- Edge case: `system_message_part/1` with body containing `**foo**` doesn't mangle existing markdown.
- Documentation test (via doctest): every public function has an example.

**Verification:**
- `mix test elixir/test/aiur/opencode/protocol_test.exs` passes.
- The snapshot fixture under `test/fixtures/` is the human-readable diff signal when opencode's config schema evolves.

---

- [ ] U3. **opencode HTTP API client (`req`-based)**

**Goal:** A small client module wrapping the opencode server endpoints Aiur calls. Centralizes URL building, request shape, error mapping, and logging. Uses `Aiur.Opencode.Protocol` for any opencode-specific payload shapes.

**Requirements:** R3, R4, R6, R8, R12

**Dependencies:** U2.

**Files:**
- Create: `elixir/lib/aiur/opencode/api_client.ex`
- Test: `elixir/test/aiur/opencode/api_client_test.exs`

**Approach:**
- Public functions: `create_session(base_url, title)`, `post_message(base_url, session_id, payload)`, `show_toast(base_url, title, message, variant)`, `abort_session(base_url, session_id)`, `health(base_url)`. SSE consumption (`GET /event`) lives in U7 — different process model.
- `req` config: `Req.new(base_url: base_url, retry: false, receive_timeout: 30_000)`. Long timeout is fine; agent turns can take minutes.
- Return shapes: `{:ok, decoded_body}` or `{:error, {:opencode_http, status, body}}` for non-2xx, `{:error, {:transport, reason}}` for network failures.
- Logging: every call logs at `:info` with `opencode_session_id=<sid> method=<verb> path=<p> status=<code>`. Failed calls additionally log the body at `:warning` (with body truncation if large).
- All call sites use shapes built by `Aiur.Opencode.Protocol` — no opencode-specific JSON keys appear in this module.

**Patterns to follow:**
- `Aiur.PaneRPC` for the logging key=value style.
- The codebase doesn't yet have a `req`-based HTTP client; this becomes the precedent.

**Test scenarios:**
- Happy path: each endpoint hit against a fake opencode server (Bandit listener spun up in test setup) returns `{:ok, body}`.
- Edge case: `create_session` with non-ASCII title (e.g., emoji) round-trips correctly.
- Error path: 5xx from opencode returns `{:error, {:opencode_http, 500, _}}`.
- Error path: connection refused returns `{:error, {:transport, _}}`.
- Edge case: timeout returns `{:error, {:transport, :timeout}}`.

**Verification:**
- `mix test elixir/test/aiur/opencode/api_client_test.exs` passes.

---

- [ ] U4. **Aiur bridge listener + chat-completions SSE handler + turn-completion broadcast surface**

**Goal:** Stand up the dedicated Bandit listener that exposes `POST /v1/chat/completions` to opencode. This is the *only* HTTP surface opencode needs from Aiur, and it's the inverse of what opencode normally talks to — instead of relaying to an LLM, the handler relays to `AgentChat.send/3` and streams back PubSub events as OpenAI chat-completion chunks. This unit *also* introduces `Aiur.AgentPubSub.broadcast_turn_event/3`, `Aiur.Opencode.TokenRegistry`, per-turn `turn_id` propagation through `AgentChat`/`Orchestrator`/`AgentRunner`, and an idle watchdog on the SSE stream — the SSE handler is the consumer, and shipping the producer in the same unit keeps the change atomic.

**Requirements:** R2, R5, R9, R10, R11, R13, R14, R15, R16

**Dependencies:** U1, U2, U6 (`AgentEvents` extraction). U4 *creates* `Aiur.AgentPubSub.broadcast_turn_event/3`, `Aiur.Opencode.TokenRegistry`, the bridge, the chat-completions handler, and the BridgeSupervisor; *modifies* `AgentChat`, `Orchestrator`, `AgentRunner`, `AgentEvents` (sequence counter) to thread `turn_id` and propagate the new broadcast surface.

**Files:**
- Create: `elixir/lib/aiur/opencode/bridge.ex` (Plug.Router with `/v1/chat/completions`, `/v1/health`)
- Create: `elixir/lib/aiur/opencode/bridge_supervisor.ex` (Supervisor that wraps the Bandit listener with `restart: :temporary` on the child spec — a bridge failure leaves the bridge stay-down and `Aiur.Supervisor` does not cascade)
- Create: `elixir/lib/aiur/opencode/chat_completions.ex` (the streaming handler — separate from the router for testability; also owns `chat_completion_chunk/2` shape and the per-turn completion-id state)
- Create: `elixir/lib/aiur/opencode/token_registry.ex` (ETS-backed map `{token, identifier} → :ok` populated by `WorkspaceSetup.materialize/5`, drained by `PaneSession.terminate/2` — closes R15 / cross-pane injection)
- Modify: `elixir/lib/aiur.ex` (add `Aiur.Opencode.TokenRegistry` and `Aiur.Opencode.BridgeSupervisor` as children of `Aiur.Supervisor`, after `Aiur.HttpServer`)
- Modify: `elixir/lib/aiur/agent_pubsub.ex` (add `broadcast_turn_event/3` reusing `AgentEvents.agent_topic/1`; the helper carries `event` tag and an opaque `turn_id` so subscribers can match per-turn)
- Modify: `elixir/lib/aiur/agent_events.ex` (extend `transcript_event/3` to stamp a monotonically-increasing per-identifier sequence number; the new field is used by TranscriptRelay dedup in U6)
- Modify: `elixir/lib/aiur/agent_runner.ex` (extend `codex_message_handler/4` to detect `:turn_completed`, `:turn_failed`, `:turn_cancelled`, `:turn_input_required` events post-normalization and broadcast via `broadcast_turn_event/3`; thread the bridge-supplied `turn_id` through `Orchestrator.send_operator_message/3` → `AgentRunner` → broadcast)
- Modify: `elixir/lib/aiur/orchestrator.ex` (accept an optional `turn_id` in the message kind map and pass it through to AgentRunner state)
- Modify: `elixir/lib/aiur/agent_chat.ex` (accept and pass through `turn_id` in `opts`)
- Test: `elixir/test/aiur/opencode/bridge_test.exs`, `elixir/test/aiur/opencode/chat_completions_test.exs`, `elixir/test/aiur/opencode/token_registry_test.exs`, `elixir/test/aiur/agent_pubsub_test.exs` (turn-event roundtrip with turn_id matching), `elixir/test/aiur/agent_runner_test.exs` (turn-event broadcast with turn_id propagation)

**Approach:**
- **Bridge supervisor:** `Aiur.Opencode.BridgeSupervisor` declares its single Bandit child with `restart: :temporary`. If Bandit fails to bind or crashes post-startup, the supervisor exits and `Aiur.Supervisor` does not restart it — the bridge stays down for the rest of the Aiur process's lifetime. Pane opens after a dead bridge return a clear error via `Aiur.Alerts.emit_custom("opencode.bridge_unavailable", message, identifier: identifier, severity: :error)` containing the configured port and the override hint. A `:warning` log at boot also identifies the port. (origin: ADV-R2-08, refined by ADV-R3-RestartCap + FEAS-R3-BridgeIso)
- **Bandit child spec:** `{Bandit, plug: Aiur.Opencode.Bridge, port: <port>, ip: <ip>, thousand_island_options: [num_connections: 50]}`. `transport_options:` is *not* a valid Bandit knob — `thousand_island_options:` is the way to pass connection caps through to the underlying acceptor. (origin: FEAS-02)
- **Token registry (R15).** `Aiur.Opencode.TokenRegistry` is an ETS-backed map populated by `WorkspaceSetup.materialize/5` (insert) and `PaneSession.terminate/2` (delete). The bridge handler looks up `{token, identifier}` in the registry; absent → 401. This replaces the v3 per-startup global secret. (origin: SEC-R3-CrossPane)
- **AgentPubSub turn-event helper:** `def broadcast_turn_event(identifier, event_tag, payload) when is_binary(identifier) and event_tag in [:turn_completed, :turn_failed, :turn_cancelled, :turn_input_required]` broadcasts `{:turn_event, identifier, event_tag, payload}` on `AgentEvents.agent_topic(identifier)`. `payload` includes the `turn_id` propagated from the bridge. (origin: FEAS-03, refined by R14 + ADV-R3-Stale + ADV-R3-InputRequired)
- **AgentEvents `sequence_for/1`.** A monotonic per-identifier sequence number lives in `Aiur.AgentEvents` (an Agent or `:persistent_term`-backed counter, the same shape `Aiur.IssueLog` uses) and stamps every `transcript_event/3` output as `event.sequence`. `AgentEventLog.write/3` includes the sequence in each ndjson line. The composite `{timestamp, sequence}` key is the dedup primary key for U6. (origin: ADV-R3-Dedup)
- **AgentRunner wiring:** Inside `codex_message_handler/4` (after `normalize_event/1`), inspect the message's `:event` field. When the value is `:turn_completed`, `:turn_failed`, `:turn_cancelled`, or `:turn_input_required`, call `AgentPubSub.broadcast_turn_event(identifier, event, %{payload: payload, turn_id: turn_id_from_state})` *after* the existing `maybe_broadcast_transcript` call so transcripts always land before the close signal. The `turn_id` is stored in `AgentRunner` state at message-receive time (carried in by `Orchestrator.send_operator_message/3`'s message kind map). Claude backend: at `lib/aiur/claude/coding_agent.ex:373` Claude emits `:turn_completed` via `emit_message`; at lines 499 and 593 Claude returns `{:ok, :turn_completed}` to the state machine without invoking `on_message`. The plan adds a small adapter in `Aiur.Claude.CodingAgent` (or its caller in `AgentRunner`) so that the `{:ok, :turn_completed}` returns also produce a single `on_message`-shaped event for the broadcast wiring — keeping the broadcast surface backend-agnostic. Claude does not emit `:turn_cancelled` or `:turn_input_required` today; the broadcast surface accepts those events when they appear but the Claude path does not synthesize them.
- **Router:** `use Plug.Router`, `plug :match`, `plug Plug.Parsers, parsers: [:json], json_decoder: Jason`, `plug :dispatch`. Bind via `Aiur.Opencode.Config.bridge_host/0` + `bridge_port/0`. **No `Plug.Logger`** — the default logger logs request headers including `Authorization`, which would leak the bearer token. The bridge module emits its own `:info` line per request with `method`, `path`, `status`, `identifier`, and `turn_id` but never headers. Both bridge and `ApiClient` (U3) use a custom redacting log helper that asserts the `Authorization` header is never serialized. A test verifies no log line produced during a bridge request contains the token value. (origin: SEC-R3-LogLeak)
- **Auth (SEC-001 + R15):** every request must carry `Authorization: Bearer <token>`. The bridge looks up `{token, parsed_identifier}` in `Aiur.Opencode.TokenRegistry`; absent → 401. The 401 response body is `{"error": "auth_failed", "message": "Bridge token did not match an active workspace. If Aiur was restarted, close and reopen the pane to refresh the token."}` — this is the recovery hint operators see when Aiur restarts mid-pane and `opencode.json` holds a stale token. (origin: SEC-R3-CrossPane + ADV-R3-RestartBearer)
- **Connection cap (SEC-004):** `thousand_island_options: [num_connections: 50]` on the Bandit child spec (corrected per FEAS-02). Additionally, a per-identifier in-flight check rejects a second concurrent stream for the same identifier with HTTP 429 (the agent processes one turn at a time anyway).
- Handler parses `%{"model" => model, "messages" => msgs, "stream" => stream}`. Extracts issue identifier from `model` via a non-greedy regex: `~r/\A#{model_prefix}\/issue-([A-Za-z0-9._-]+)\z/`. The character class is the *only* allow list — anything else is HTTP 400. Treats the last `role: "user"` message as the operator submit. (origin: SEC-003)
- Validation (mirroring `Aiur.PaneRPC.send_operator_message/2` exactly, including the regex with no `/u` flag per SEC-006): UTF-8 valid via `String.valid?/1` (HTTP 400 on invalid), then ≤ 65_536 bytes, then control characters stripped via `String.replace(text, ~r/[\x00-\x08\x0B-\x1F]/, "")`.
- **Subscribe-before-send + turn-id mint.** The handler (1) generates a fresh UUID v4 `turn_id`, (2) calls `AgentPubSub.subscribe_agent(identifier)`, (3) calls `Aiur.AgentChat.send(identifier, sanitized_text, delivery_policy: :checkpoint, fallback: :queue_next, turn_id: turn_id)`. Subscribing first ensures the first transcript event or turn-end signal cannot land before the subscription is in place. (origin: R14)
- **R9 queued-pane auto-start with retry-race fix (ADV-R2-07):** on `{:error, :no_running_agent}` from `AgentChat.send`, the handler calls `Aiur.Orchestrator.resume_agent(identifier)`. On `{:ok, :started}` or `{:ok, :resumed}`, the handler waits up to 5 s for either a `{:status_change, identifier, :running}` message (already on the subscribed topic) or the first transcript chunk on the agent, then retries `AgentChat.send/3` **exactly once**. No further retries — repeated `:no_running_agent` after one resume cycle returns an error chunk. The 5 s threshold is a generous 5× buffer over typical sub-second agent startup; expose via `opencode.queued_pane_resume_timeout_ms` if field experience shows tuning is needed.
- **Streaming response with turn-id filtering and idle watchdog (R14/R16/ADV-R3-Watchdog):** `Plug.Conn.put_resp_header("content-type", "text/event-stream") |> send_chunked(200)`, mint a `completion_id` (UUID v4, used as the `id` field on every emitted `chat.completion.chunk`), arm `Process.send_after(self(), :turn_watchdog, 600_000)` (10 minutes), then enter a loop that pulls from the pre-established PubSub subscription. For each message:
  - `{:transcript_event, %{role: :assistant | :command, body: chunk, turn_id: ^turn_id}}` → emit a `chat.completion.chunk` shaped delta via `Aiur.Opencode.ChatCompletions.build_chunk/2`, refresh the watchdog.
  - `{:transcript_event, %{role: :user}}` → ignore (FEAS-06).
  - `{:transcript_event, %{turn_id: other_id}}` when `other_id != turn_id` → ignore (R16 — concurrent dashboard turn).
  - `{:turn_event, ^identifier, :turn_completed, %{turn_id: ^turn_id}}` → emit final chunk with `finish_reason: "stop"`, close.
  - `{:turn_event, ^identifier, :turn_failed, %{turn_id: ^turn_id}}` → emit final chunk with `finish_reason: "stop"` and a synthetic text part containing the error message, close.
  - `{:turn_event, ^identifier, :turn_cancelled, %{turn_id: ^turn_id}}` → emit final chunk with `finish_reason: "stop"`, close.
  - `{:turn_event, ^identifier, :turn_input_required, %{turn_id: ^turn_id}}` → emit a synthetic text chunk `**system:** Agent is awaiting approval. Resolve in the dashboard to continue.` then final chunk with `finish_reason: "tool_calls"`, close.
  - `:turn_watchdog` (timer fired) → emit synthetic text chunk `**system:** Agent appears to have hung — no response in 10 minutes. Reload the pane to try again.` and final chunk with `finish_reason: "timeout"`, close.
- Non-streaming case (`stream: false`): block, accumulate, return as one `chat.completion`. opencode's adapter always streams when configured to, but supporting non-stream keeps the shim testable with `curl`.
- The `/v1/health` endpoint returns `{"ok": true}` and skips auth. Used by debug tooling and supervisor health checks.
- **`chat_completion_chunk/2` lives here, not in Protocol.** Signature: `build_chunk(completion_id, %{content: string | nil, finish_reason: nil | "stop" | "timeout" | "tool_calls"})`. Threads completion-id through every chunk in a turn so the Vercel AI SDK sees a consistent envelope. Tool-call delta handling: aggregate partial codex events into a single OpenAI `tool_call` delta in this module; do not leak partial-aggregation state out.

**Execution note:** Test-first. SSE handling is subtle (chunk boundaries, content-length, half-open connections); the test harness drives `Plug.Test`-style conns against the handler with a stubbed `AgentChat` and asserts the chunk-by-chunk byte output.

**Patterns to follow:**
- `elixir/lib/aiur_web/controllers/observability_api_controller.ex` for `Aiur.AgentChat`/`Orchestrator` call shape.
- `elixir/lib/aiur/http_server.ex` for how the existing listener is configured under the supervisor — same shape but a different Bandit child.
- `elixir/lib/aiur/pane_rpc.ex:93` for the *exact* control-char regex to mirror.

**Test scenarios:**
- Happy path: streaming POST with a valid model name, valid Bearer token, single user message → response contains expected OpenAI-shaped chunk envelope with `delta.content` matching the broadcast assistant text. Covers AE for R2.
- Happy path: non-streaming variant returns a single `chat.completion` object with the same content.
- Edge case: model name `aiur/issue-MT-123_with_underscores` parses correctly.
- Edge case: messages array with multiple `role: "user"` entries — only the last is forwarded.
- Error path: missing Authorization header returns 401. Covers AE for SEC-001.
- Error path: wrong Bearer token returns 401.
- Error path: body of 65_537 bytes returns 400 with `{"error": "body too large"}`. Covers R10.
- Edge case: body containing `\x05` control char is stripped before forwarding to `AgentChat.send`. Covers R10.
- Error path: body containing invalid UTF-8 returns 400 (not silently mangled). Covers SEC-006.
- Error path: model name without `aiur/issue-` prefix returns 400.
- Error path: model name's parsed identifier contains `/` or `..` returns 400 (regex doesn't match). Covers SEC-003.
- Error path: model name's identifier doesn't exist in orchestrator state → 404 with `{"error": "no such issue"}`.
- Integration: queued issue (`{:error, :no_running_agent}` from `AgentChat.send`) triggers `Orchestrator.resume_agent/1`, the agent starts (returns `{:ok, :started}`), and the next `AgentChat.send` succeeds. Covers AE for R9.
- Integration: paused issue + resume returning `{:ok, :resumed}` works the same way.
- Error path: orchestrator returns `{:error, :max_concurrent_agents_reached}` → handler returns an error chunk.
- Integration: stream terminates after `AgentRunner` emits `:turn_completed` and `AgentPubSub.broadcast_turn_event/3` lands on the subscribed topic with the matching `turn_id`; no further chunks emitted. Covers AE for R13/R14.
- Integration: stream terminates on `:turn_input_required` with `finish_reason: "tool_calls"` and the operator-visible "awaiting approval" message. Covers AE for ADV-R3-InputRequired.
- Integration: idle watchdog fires after 10 minutes of no chunks → synthetic timeout chunk emitted, stream closes. Watchdog refreshes on each `:assistant` / `:command` chunk. Covers AE for ADV-R3-Watchdog.
- Integration: turn-id mismatch — broadcast a `{:turn_event, identifier, :turn_completed, %{turn_id: "other-id"}}` mid-stream → stream stays open (current turn_id doesn't match). Covers AE for R14.
- Integration: concurrent dashboard turn — broadcast a `{:transcript_event, %{role: :assistant, turn_id: "other-id"}}` mid-stream → no chunk emitted (filtered out). Covers AE for R16.
- Token mismatch: request with valid token but wrong identifier in `model` field returns 401 (TokenRegistry lookup fails). Covers AE for R15/SEC-R3-CrossPane.
- Integration: stream terminates with a failure-shaped final chunk when `:turn_failed` is broadcast.
- Integration: a `:user` transcript event broadcast on the subscribed topic mid-stream does **not** produce a chunk — only `:assistant` and `:command` events do. Covers FEAS-06.
- Integration: queued-pane retry — agent is queued, first `AgentChat.send` returns `:no_running_agent`, handler resumes, waits for `:running` status, second send succeeds, stream completes. Covers ADV-R2-07.
- Edge case: queued-pane retry — `:running` status never arrives within 5 s → second `send` still attempts once; on continued `:no_running_agent` an error chunk is emitted (no infinite loop).
- Integration: client disconnects mid-stream → handler cleans up PubSub subscription (asserted via `Process.alive?` and `Phoenix.PubSub.subscribers` count).
- Edge case: a second concurrent stream for the same identifier returns HTTP 429. Covers AE for SEC-004.
- Integration: `AgentPubSub.broadcast_turn_event/3` is a no-op when there are no subscribers (doesn't raise). Covers FEAS-03.
- Integration: `Aiur.AgentRunner.codex_message_handler/4` broadcasts the turn-completion signal when the underlying CodingAgent emits `:turn_completed` (test with a stub message handler driven through `AgentRunner`).
- Integration: `GET /v1/health` returns 200 without auth.
- Integration: starting the BridgeSupervisor with a port already in use → only the BridgeSupervisor subtree fails; `Aiur.Supervisor`'s other children stay running (`AiurWeb.Endpoint`, `HttpServer`, etc., are reachable). Covers AE for ADV-R2-08.

**Verification:**
- `mix test elixir/test/aiur/opencode/bridge_test.exs elixir/test/aiur/opencode/chat_completions_test.exs` passes.
- Manually: with a valid bearer token, `curl -N -H "authorization: bearer $TOKEN" -H "content-type: application/json" -d '{"model":"aiur/issue-MT-123","messages":[{"role":"user","content":"hi"}],"stream":true}' http://127.0.0.1:4097/v1/chat/completions` streams chunks while the issue's agent is running.

---

- [ ] U5. **opencode server lifecycle (`Aiur.Opencode.Server`)**

**Goal:** A GenServer that wraps `opencode serve` as a stdio Port: starts, polls health, exposes the base URL, logs the verified-version status, and shuts down cleanly on terminate. This is the per-pane process that the supervisor tree manages.

**Requirements:** R6, R12

**Dependencies:** U1, U2, U3.

**Files:**
- Create: `elixir/lib/aiur/opencode/server.ex`
- Test: `elixir/test/aiur/opencode/server_test.exs` (uses fake-shell-script pattern from `app_server_test.exs`)

**Approach:**
- Accepts `%{workspace: path, port: integer | :auto, identifier: string}` on start. If `:auto`, picks a free port via `:gen_tcp.listen(0, ...)`.
- `Port.open({:spawn_executable, bash}, [cd: workspace, args: ["-lc", Aiur.Opencode.Protocol.serve_command(port, host, extra_args)], :binary, :exit_status])`. The `cd:` argument matters: opencode is git-aware and uses the cwd for project root.
- Health-poll loop after spawn: `Aiur.Opencode.ApiClient.health(base_url)` up to 30 times at 100 ms intervals. On success, transitions to `:ready` and replies to any waiting callers.
- After ready, queries `opencode --version` (one-shot `System.cmd`). Compares against `Aiur.Opencode.Protocol`'s verified range. If outside, logs a warning at `:warning` level with the running version and the verified range, but does not fail. (R12 visibility)
- Public `await_ready/1` returns `{:ok, base_url}` or `{:error, :startup_timeout}`.
- `terminate/2` closes the Port (which SIGTERMs the opencode process — bash will forward).
- Per-message structured logging: `opencode_pid=<os_pid> issue_identifier=<id> phase=<starting|ready|terminated> opencode_version=<v>`.

**Execution note:** Test-first. The fake-binary harness mirrors `elixir/test/aiur/app_server_test.exs:104-132` — a tiny shell script that on launch listens on the given port and serves a fixed `/global/health` response, then exits when stdin closes.

**Patterns to follow:**
- `elixir/lib/aiur/codex/coding_agent.ex` `start_port/2` for the Port.open + cd + args pattern.
- `elixir/test/aiur/app_server_test.exs:104-132` for the fake-binary test pattern.

**Test scenarios:**
- Happy path: fake opencode binary serves `/global/health` → `Server` transitions to `:ready` and `await_ready/1` returns the URL. Covers AE for R6.
- Happy path: version-check logs the running version at `:info` when inside verified range.
- Edge case: version-check logs a `:warning` (but stays in `:ready`) when version is outside verified range.
- Edge case: explicit port number passed in → opencode is invoked with that port.
- Edge case: `:auto` port picks an unused port → assertion that subsequent `await_ready/1` returns a working URL.
- Error path: fake opencode never serves `/global/health` → `await_ready/1` returns `{:error, :startup_timeout}`, GenServer exits with `{:shutdown, :startup_timeout}`.
- Error path: fake opencode exits with non-zero status during startup → GenServer exits with `{:shutdown, {:exit_status, n}}`.
- Integration: `terminate/2` closes the Port and the OS-level opencode process actually exits within 2 seconds (process-table check via `:os.cmd`).

**Verification:**
- `mix test elixir/test/aiur/opencode/server_test.exs` passes.

---

- [ ] U6. **Transcript replay + live publisher (`Aiur.Opencode.TranscriptRelay`)**

**Goal:** One module that owns both phases of pushing Aiur transcript content into the opencode session: the cold-start replay of `logs/agent.ndjson` on pane open, and the live PubSub-tail thereafter. Same pipeline (source → convert via `Protocol` → POST via `ApiClient`); the source switches when replay completes. Merges what the earlier plan draft kept as two units.

**Requirements:** R3, R4, R7, R8

**Dependencies:** U2, U3. Also depends on promoting `transcript_event_from/1` from `Aiur.AgentRunner` to a public helper (in `Aiur.AgentEvents` or a new `Aiur.AgentRunner.TranscriptDecoder` — implementer's call). The decoder promotion happens here so the same logic decodes both file lines and live PubSub messages.

**Files:**
- Create: `elixir/lib/aiur/opencode/transcript_relay.ex`
- Modify: `elixir/lib/aiur/agent_runner.ex` (extract `transcript_event_from/1` — promoted to `Aiur.AgentEvents.transcript_event_from/1`; the new `:turn_completed` broadcast wiring lives in U4, not here)
- Modify: `elixir/lib/aiur/agent_events.ex` (host the promoted `transcript_event_from/1`; teach it to parse ISO8601 binary timestamps via `DateTime.from_iso8601/1` so replayed ndjson lines carry the same DateTime the live broadcast carried — fixes FEAS-R3-Timestamp)
- Test: `elixir/test/aiur/opencode/transcript_relay_test.exs`

**Sequencing note (CROSS-R3-CodexHandler):** Land the `AgentEvents.transcript_event_from/1` extraction in U6 **before** U4's `codex_message_handler/4` edits that add the turn-event broadcast wiring. Both units modify the same function body; U6's extraction happens first so U4 calls the promoted helper.

**Approach:**
- GenServer. On `init`, parameters: `%{identifier:, base_url:, session_id:, workspace:}`.
- **Subscribe-then-read-with-composite-dedup (FEAS-04, refined by ADV-R3-Dedup).** The init sequence is: (1) `Aiur.AgentPubSub.subscribe_agent(identifier)` immediately, **before** opening the file; (2) start reading `logs/agent.ndjson`; (3) accumulate any `{:transcript_event, _}` messages that arrive in the GenServer mailbox while replay is in progress; (4) after replay completes, drain the mailbox, dropping any event whose `{timestamp, sequence}` tuple is `<=` the highest tuple seen during replay (lexicographic compare), posting the rest. The composite key prevents sub-millisecond timestamp collisions from silently dropping legitimate live events — sequence is the per-identifier counter in `AgentEvents` added by U4. **Missing-queued-issue case (DESIGN-R3-Empty):** when `agent.ndjson` does not exist, the relay posts one synthetic assistant message: `**system:** This issue is queued. Type a message to start the agent.` then transitions to live.
- **Phase 1 — Replay.** `File.stream!("<workspace>/logs/agent.ndjson", [], :line)` is walked synchronously. Each line: `Jason.decode/1` → `Aiur.AgentEvents.transcript_event_from/1` (skip on `nil`; ISO8601 binary timestamps parsed via the helper's own `DateTime.from_iso8601/1` call) → convert via `Aiur.Opencode.Protocol.{user_message_part, assistant_text_message, assistant_command_message, system_message_part, alert_message_part}` per R7 → `Aiur.Opencode.ApiClient.post_message/3`. Skip malformed lines with `Logger.debug` and continue. Track the highest `{timestamp, sequence}` tuple seen.
- **Mailbox drain (between replay and live).** Selective receive of any queued `{:transcript_event, event}` messages, each processed through the same `Protocol`-based publish path, dropping any whose `{timestamp, sequence}` is `<=` the highest replayed tuple. Once the mailbox is empty, the init reply is sent — the PaneSession waits for this before reporting ready.
- **Mailbox-growth guard (ADV-R3-MailboxGrowth).** During replay (and especially during drain) the GenServer mailbox can accumulate live events if opencode's `post_message` is slow. Log a `:warning` when `Process.info(self(), :message_queue_len)` exceeds 1_000; crash and let the PaneSupervisor restart when it exceeds 10_000. The replay-on-restart path will catch the relay up via the file.
- **Phase 2 — Live.** `handle_info({:transcript_event, event}, state)` converts via `Protocol` and posts. **`:user` events are dropped** (R4 / F3) because opencode already renders the operator's local input. `:alert` events both POST to the session (chat entry) and call `Aiur.Opencode.ApiClient.show_toast/4` (toast). All other tags route through `post_message` only. Any `{:turn_event, _, _, _}` messages on the same topic are ignored here — they are the bridge handler's concern, not the relay's.
- Crash-safety: a transient HTTP error in `post_message` logs at `:warning` and is silently dropped (the equivalent local transcript in `agent.ndjson` is the source of truth — replay on the next cold-start fills any gap). A repeated error (5 consecutive failures) escalates the GenServer to crash and let the PaneSupervisor handle it.

**Patterns to follow:**
- `elixir/lib/aiur/issue_log.ex` for the PubSub-tailing GenServer pattern with per-identifier registration.
- `elixir/lib/aiur/agent_event_log.ex` for the `json_safe` shape the file lines come back as.

**Test scenarios:**
- Happy path: fixture ndjson with one `:user`, one `:assistant`, one `:command`, one `:system`, one `:alert` event → five `post_message` calls in order matching Protocol's shapes. Covers AE for R3 + R7.
- Edge case: missing file → returns `{:ok, 0}` then transitions to live. Covers AE for R9.
- Edge case: empty file → `{:ok, 0}` then live.
- Edge case: line with malformed JSON → logged + skipped; surrounding lines still processed.
- Edge case: ndjson with `event: "usage"` (telemetry) → not posted; count reflects this.
- Happy path (live): broadcast a `:assistant` transcript event → `post_message` called.
- Happy path (live): broadcast a `:command` event → posted with native tool-call + tool-result parts. Covers AE for R7.
- Happy path (live): broadcast an `:alert` → both `post_message` AND `show_toast` were called. Covers AE for R8.
- Edge case (live): broadcast a `:user` transcript → no API call. Covers R4 / F3 explicitly — the publisher must not double-echo.
- Edge case (live): broadcast a `{:turn_completed, _, _}` message → no API call (turn-end signal is consumed only by the bridge handler, not the relay).
- **Race coverage (FEAS-04):** start the relay GenServer with PubSub subscription active, immediately broadcast a transcript event whose timestamp matches a line already in the fixture ndjson — assert exactly one `post_message` call (the file replay wins; the live event is deduped).
- **Race coverage (FEAS-04):** start the relay, broadcast a transcript event with a timestamp *newer* than any file line, then let replay finish — assert the live event is posted exactly once after replay completes.
- Error path: 4 consecutive transient `post_message` failures → logged but process continues; the 5th consecutive failure → GenServer crash (matches the threshold stated in Approach above).
- Integration: with real `Aiur.AgentPubSub`, broadcasting via `AgentEvents.transcript_event/3` after replay-complete reaches the relay and produces the right API call.
- Queued-pane synthetic message: fixture with no `agent.ndjson` present in the workspace → exactly one `post_message` call with the `**system:** This issue is queued.` body before transition to live (DESIGN-R3-Empty).
- Mailbox growth: stub `post_message` to sleep 50ms per call, broadcast 2_000 transcript events while replay is running — the relay logs a `:warning` once message_queue_len exceeds 1_000.

**Verification:**
- `mix test elixir/test/aiur/opencode/transcript_relay_test.exs` passes.

---

- [ ] U7. **opencode SSE event consumer**

**Goal:** Long-lived process that connects to `GET /event` on a running opencode server, parses SSE, and turns relevant events into Aiur PubSub broadcasts or alerts. This is the opencode→Aiur direction. The turn-end signal that the chat-completions handler (U4) listens on is **not** sourced here — it comes from `Aiur.AgentRunner` via the `broadcast_turn_event/3` helper (R13 / FEAS-01 / refined v4). This consumer's job is the residual: permission prompts, opencode errors, and visibility logging.

**Requirements:** R5, R8, R12

**Dependencies:** U2, U3.

**Files:**
- Create: `elixir/lib/aiur/opencode/event_consumer.ex`
- Test: `elixir/test/aiur/opencode/event_consumer_test.exs`

**Approach:**
- GenServer keyed by `{opencode_session_id, identifier}`. On `init`, opens a streaming GET to `<base_url>/event` via `Req.get(..., into: fn {:data, chunk}, acc -> ... end)` — `req`'s native streaming interface (no direct Finch calls, per SG-02).
- Parses SSE frames (`data: {...}\n\n`). Dispatches by event name **looked up against `Aiur.Opencode.Protocol`** — no opencode-specific string literals in this module:
  - `Protocol.event_permission_asked()` → `Aiur.Alerts.emit_custom("opencode.permission_asked", message, identifier: identifier, severity: :info)` (real Alerts API per SG-07).
  - `Protocol.event_session_idle()` → **observation/log only** (`Logger.debug "opencode_session_idle identifier=… opencode_session_id=…"`). v2 used this as the turn-end signal; v3 sources turn-end from the agent backend instead (R13/FEAS-01). Keeping a debug log line preserves observability if we ever need to correlate "opencode thinks it's idle" with "agent finished a turn".
  - `Protocol.event_session_error()` → `Aiur.Alerts.emit_custom(..., severity: :error)`.
  - `Protocol.event_tool_before()` / `Protocol.event_tool_after()` → no-op (the live transcript publisher mirrors `:command` events from the *agent* side; opencode's own tool execution is not relevant in our setup because opencode never actually runs tools — the bridge intercepts every model call).
  - Unknown event names → ignored without crashing.
- Robust to opencode crashing: if the stream errors, the GenServer crashes; the PaneSession supervisor decides whether to restart it (typically `:transient` — opencode is down, restart is futile until the next cold-start).

**Patterns to follow:**
- Existing long-lived consumers in the codebase (none with SSE) — closest precedent is `Aiur.Tmux` for `subscribe_events` over a Port. Keep this consumer self-contained.
- `req` docs for `into:` streaming.

**Test scenarios:**
- Happy path: fake opencode SSE stream emits `permission.asked` → assertion that `Aiur.Alerts.emit_custom/3` was called with expected args. (Covers SG-07 fix.)
- Happy path: fake stream emits `session.idle` → assertion that **no** PubSub broadcast or alert is produced (only a `Logger.debug` line). v3 removed this as a turn-end source (R13/FEAS-01).
- Happy path: fake stream emits `session.error` → assertion that `emit_custom` was called with `severity: :error`.
- Edge case: fake stream emits an unknown event type → no-op, no crash.
- Edge case: fake stream emits malformed SSE (incomplete frame, missing `data:` prefix) → process continues without crashing.
- Edge case: a `tool.execute.before` event arrives → no API call (no-op per approach).
- Error path: opencode connection drops mid-stream → process exits; supervisor restart counted in test.
- Integration: with `Aiur.Opencode.Protocol`'s real event-name constants, the consumer dispatches to the right handler for each event.

**Verification:**
- `mix test elixir/test/aiur/opencode/event_consumer_test.exs` passes.

---

- [ ] U8. **Workspace bootstrap (`Aiur.Opencode.WorkspaceSetup`)**

**Goal:** Write the per-workspace `opencode.json` before spawning `opencode serve`. Idempotent — overwrites on every pane open since each pane is a fresh cold-start (R6). No plugin (decision logged above).

**Requirements:** R5, R6, R10, R12

**Dependencies:** U1, U2.

**Files:**
- Create: `elixir/lib/aiur/opencode/workspace_setup.ex`
- Test: `elixir/test/aiur/opencode/workspace_setup_test.exs` (includes a snapshot test of the rendered `opencode.json`)

**Approach:**
- `materialize(workspace_path, identifier, bridge_url, opencode_os_pid)` is the public entry point. `opencode_os_pid` is `nil` on the first call (before the Port is opened) and the real OS PID from `:erlang.port_info(port, :os_pid)` on the second call after `Server.await_ready/1`. The bearer token is **generated inside `materialize/4`** (UUID v4 per call, registered in `Aiur.Opencode.TokenRegistry` against `identifier`) — callers do not pass a token. (origin: SEC-R3-CrossPane + FEAS-R3-PidShape)
- Calls `Aiur.Opencode.Protocol.opencode_json/1` with `%{bridge_url:, bridge_token:, identifier:, opencode_os_pid:}` to get a fully-built Elixir map; serializes via `Jason.encode!/1`. **No EEx templates** — the resulting JSON file is `Jason`-built end-to-end, which is injection-safe by construction (SEC-002 closed).
- The rendered `opencode.json` includes:
  - `provider.aiur` set to `{npm: "@ai-sdk/openai-compatible", name: "Aiur Bridge", options: {baseURL: "<bridge_url>/v1", apiKey: "<bridge_token>"}, models: {"issue-<safe_id>": {name: "Aiur Relay"}}}`.
  - **Exactly one provider (Aiur) and exactly one model (the per-issue one).** Other built-in opencode providers (Anthropic, OpenAI, etc.) are *not* declared. With nothing else to switch to, `/models` becomes a UX no-op. This is the v3 fix for ADV-R2-10: data egress through model switching is closed at config time, not by documentation alone.
  - `default_agent: "aiur"` (or similar — a minimal opencode agent definition; the exact key is per `Protocol`'s template).
  - `permission` block allowing common safe defaults to avoid `permission.asked` prompt noise. In addition, the `permission` block (or `permission.disabled`) lists `provider_change` / `model_change` if opencode exposes such a key in the supported version range — verify during U2 against the verified opencode version's docs and capture the exact key in `Aiur.Opencode.Protocol`. If no such permission key exists, the "only one declared provider" approach alone is sufficient.
- Writes `<workspace>/opencode.json` (creating parent if absent). Adds `opencode.json` to the workspace `.gitignore` if not already present (mirroring `agent.ndjson` behavior).
- The `.opencode/plugins/aiur.ts` file is **not** written.

**Patterns to follow:**
- `elixir/lib/aiur/workspace.ex` `run_before_run_hook/3` for the "write files into workspace" pattern.

**Test scenarios:**
- Happy path: `materialize(tmp_workspace, "MT-123", "http://127.0.0.1:4097", nil)` produces `opencode.json` matching a checked-in snapshot fixture exactly (with `opencode_os_pid: null` placeholder; the fixture matches on every field except the freshly-generated token which is checked separately to be a UUID v4 shape).
- Token registered: after `materialize/4` returns, `Aiur.Opencode.TokenRegistry.lookup(generated_token, "MT-123")` returns `:ok`. Calling `materialize/4` a second time for the same identifier (re-open after close) invalidates the prior token and registers a new one — the prior token's `lookup/2` returns `:error`.
- Re-materialize after Server.await_ready: a second call with `opencode_os_pid: 12345` rewrites `opencode.json` with that PID in `aiur_metadata.opencode_os_pid` while preserving the token registered in the first call.
- Edge case: bridge URL containing `&`, quote, or other JSON-meaningful character is serialized correctly (since `Jason.encode!` handles it).
- Edge case: identifier with `/` or other unsafe chars is normalized to `safe_id` for the model name.
- Edge case: existing `opencode.json` from a prior cold-start is overwritten (no merge).
- Edge case: `.gitignore` add is idempotent (running twice doesn't duplicate the line).
- Error path: workspace path doesn't exist → `{:error, :workspace_missing}`.
- **Lockdown (ADV-R2-10):** snapshot assertion that the rendered `opencode.json` declares exactly one `provider` (`aiur`) and exactly one `model` (the per-issue entry). No `anthropic`, `openai`, or other provider key is present.

**Verification:**
- `mix test elixir/test/aiur/opencode/workspace_setup_test.exs` passes.
- The snapshot fixture under `test/fixtures/opencode.json` is the diff signal when the schema evolves.
- Manually inspect the rendered `opencode.json` for a real workspace and confirm `opencode serve` accepts it without errors.

---

- [ ] U9. **Per-pane orchestrator + supervisor (`Aiur.Opencode.PaneSession` + `Aiur.Opencode.PaneSupervisor`)**

**Goal:** Tie U5/U6/U7/U8 together. A `PaneSession` GenServer per pane that runs the bootstrap → spawn opencode → create session → replay → subscribe sequence, holds the server/relay/consumer children, and tears them down on close. (Renamed in this draft to keep "PaneSession" as the Aiur-side orchestrator name, distinct from "opencode session"; the `@moduledoc` makes the terminology explicit per F1.)

**Requirements:** R3, R4, R6, R7, R8, R9

**Dependencies:** U2, U3, U5, U6, U7, U8.

**Files:**
- Create: `elixir/lib/aiur/opencode/pane_session.ex` (GenServer)
- Create: `elixir/lib/aiur/opencode/pane_supervisor.ex` (DynamicSupervisor)
- Modify: `elixir/lib/aiur.ex` (add `Aiur.Opencode.PaneSupervisor` as a child of `Aiur.Supervisor`, after `Aiur.Opencode.Bridge`)
- Test: `elixir/test/aiur/opencode/pane_session_test.exs`

**Approach:**
- `@moduledoc` opens with terminology: "`Aiur.Opencode.PaneSession` is the BEAM-side orchestrator that owns one *opencode session* and its supporting processes for one tmux pane. 'opencode server' is the external `opencode serve` Port; 'opencode session' is the HTTP resource opencode creates via `POST /session`; 'PaneSession' is this Elixir GenServer."
- `PaneSupervisor` is a `DynamicSupervisor` with `strategy: :one_for_one`.
- `PaneSession` API: `start(identifier, workspace_path)` returns `{:ok, %{attach_url: ..., session_id: ...}}` once ready. `stop(identifier)` calls `DynamicSupervisor.terminate_child/2`.
- `init/1` sequence (refined v4 to fix the reap-vs-materialize ordering bug from COH-R3-Reap + FEAS-R3-ReapOverwrite):
  1. **Read prior PID, if any.** Open the workspace's existing `opencode.json` (if present) and capture `aiur_metadata.opencode_os_pid`. If nil or absent, skip step 2.
  2. **Validate and reap prior PID.** Verify the PID corresponds to a process whose `/proc/<pid>/comm` matches `opencode` (Linux) or whose `ps -o comm= -p <pid>` output matches `opencode` (other Unix). On match: `:os.cmd("kill #{pid} 2>/dev/null || true")`. On mismatch or non-Linux/Unix where neither tool resolves: log `:info` "skipping reap" and continue. **Never kill a PID without identity verification.** (origin: ADV-R3-PidReuse + SEC-R3-PidValidation)
  3. **Materialize (first call, no PID).** `Aiur.Opencode.WorkspaceSetup.materialize(workspace, identifier, bridge_url, nil)` — generates a fresh per-workspace token, registers it in `TokenRegistry`, writes `opencode.json` with `opencode_os_pid: nil`.
  4. `Aiur.Opencode.Server.start_link/1` (U5) — start opencode serve, wait for `await_ready/1`.
  5. **Re-materialize with OS PID.** `Aiur.Opencode.WorkspaceSetup.materialize(workspace, identifier, bridge_url, os_pid)` where `os_pid = :erlang.port_info(server_port, :os_pid)`. Token from step 3 is preserved (same `identifier`).
  6. `Aiur.Opencode.ApiClient.create_session/2` (U3) — store `session_id`.
  7. `Aiur.Opencode.TranscriptRelay.start_link/1` (U6) — runs replay synchronously, then transitions to live.
  8. `Aiur.Opencode.EventConsumer.start_link/1` (U7) — opencode SSE → Aiur.
  9. Transition to `:ready`, reply to callers waiting on `start/2`.
- `terminate/2` stops the three children in reverse order: EventConsumer → TranscriptRelay → Server (closing the Port), and also calls `Aiur.Opencode.TokenRegistry.delete(identifier)` so the bridge no longer accepts the closed pane's token.
- **Orphan reaping on restart (ADV-R2-02, refined v4).** If `PaneSession` crashes (or `Aiur` itself restarts), the opencode OS process spawned by `Aiur.Opencode.Server` could be left orphaned. The Port closes when the GenServer dies, which SIGTERMs the wrapping `bash` — but a slow or wedged opencode process could survive briefly. U9's `init/1` performs the read-validate-reap sequence above (steps 1–2) **before** the first `materialize/4` call (step 3) so the prior file's PID is captured before being overwritten. PID validation via `/proc/<pid>/comm` prevents accidental kills on Linux PID reuse. (origin: ADV-R2-02 + FEAS-R3-ReapOverwrite + ADV-R3-PidReuse + SEC-R3-PidValidation)
- **Pane reuse race (ADV-R2-03).** A second `Aiur.Conversations.open/2` for the same identifier while the first `PaneSession.start/2` is still in `:starting` phase must not spawn a second opencode server. `PaneSession` is registered in a `Registry` keyed by `identifier`. The `start/2` API uses `DynamicSupervisor.start_child/2` and pattern-matches `{:error, {:already_started, pid}}` → `await_ready(pid)` (a `GenServer.call/3` with a longish timeout that blocks until init completes and returns the cached `attach_url`/`session_id`). Race-tested in U9 by issuing two simultaneous `start/2` calls and asserting exactly one Port is opened.
- Logs structured `pane_session=<identifier> phase=<starting|ready|terminating>`.

**Execution note:** The longest-running step at startup is the replay phase of TranscriptRelay. For issues with thousands of events this could take a second or two. PaneSession returns `{:ready, ...}` only after replay completes — opencode TUI shouldn't be attached before history is in place, otherwise the operator briefly sees an empty chat.

**Patterns to follow:**
- `elixir/lib/aiur/issue_log.ex` for the per-identifier DynamicSupervisor + Registry pattern.

**Test scenarios:**
- Happy path: start → workspace bootstrap → fake opencode → replay → consumer up → returns `{:ready, %{attach_url, session_id}}`. Covers AE for R6 + R3.
- Edge case: queued issue with no `agent.ndjson` → replay returns `{:ok, 0}`; session still becomes ready. Covers AE for R9.
- Error path: fake opencode fails to start → `PaneSession` exits with `{:shutdown, :opencode_startup_failed}`; child supervisor reflects the failure.
- Error path: replay errors mid-stream → PaneSession exits; opencode server is torn down.
- Integration: `terminate/2` shuts everything down. Process tree (Server, EventConsumer, TranscriptRelay) is empty after `stop/1`.
- **Race (ADV-R2-03):** two concurrent `start/2` calls for the same identifier → exactly one Port opened; both calls return the same `attach_url`/`session_id`.
- **Orphan reap with valid identity (ADV-R2-02):** drop a stale `opencode.json` referencing a PID that resolves to an `opencode` process (use a sleep-shell fake bound to a known PID), then `start/2` — assert the PID is sent SIGTERM (via a recording wrapper around `:os.cmd`).
- **Orphan reap rejects mismatched identity (ADV-R3-PidReuse):** drop a stale `opencode.json` with a PID that points to a non-opencode process — assert that `:os.cmd` is NOT invoked with that PID and the reap path logs an `:info` skip line.
- **Orphan reap on non-/proc platform:** mock the validation helper to return `:unsupported_platform` — assert the reap is skipped silently.
- **Reap-before-materialize ordering (FEAS-R3-ReapOverwrite):** drop a prior `opencode.json` with PID X, then `start/2` — assert the reap reads PID X *before* the new `materialize/4` call rewrites the file.

**Verification:**
- `mix test elixir/test/aiur/opencode/pane_session_test.exs` passes.

---

- [ ] U10. **Pane manager cutover to opencode command**

**Goal:** Change the only existing call site (`Aiur.Conversations.default_command/1`) and the pane-spawning path (`Aiur.PaneManager.open_conversation/3`) to spin up an `Aiur.Opencode.PaneSession` and put `opencode attach` in the tmux pane instead of `bin/aiur conversation`. Bypass the BEAM-node distribution wrap for opencode commands.

**Requirements:** R1, R11

**Dependencies:** U2, U9.

**Files:**
- Modify: `elixir/lib/aiur/conversations.ex` (`default_command/1` returns the opencode attach command after starting a `PaneSession`)
- Modify: `elixir/lib/aiur/pane_manager.ex` (in `open_conversation/3`: call `Aiur.Opencode.PaneSession.start/2` before building the tmux command; bypass `wrap_with_unique_node/2` since opencode is not a BEAM child)
- Test: `elixir/test/aiur/pane_manager_test.exs` (update existing tests; do not duplicate `pane_session_test.exs`)

**Approach:**
- `Aiur.Conversations.open/2` is unchanged in shape; only the inner command flow changes.
- New flow in `open_conversation/3` (refined v4 for the cold-start UX gap from DESIGN-R3-Loading): (1) resolve workspace path for identifier; (2) respawn the tmux pane *immediately* with a small wrapper shell that prints `Loading chat history…` and blocks on a named pipe at `<workspace>/.aiur-pane-ready`; (3) start `Aiur.Opencode.PaneSession.start(identifier, workspace_path)` asynchronously; (4) when PaneSession reports ready, write the `opencode attach <url> --session <id>` command to the named pipe and the wrapper `exec`s it. Operator sees `Loading chat history…` instead of a blank terminal during the 1–2 s spawn-and-replay window. If PaneSession fails to become ready, the wrapper times out (15 s) and prints the error toast contents via `Aiur.Alerts.emit_custom("opencode.pane_start_failed", message, identifier: identifier, severity: :error)`.
- `wrap_with_unique_node/2`: gate on whether the command is an opencode command. For now (since opencode is the only command), simply skip it; if other command types come later we can add a discriminator.
- `Aiur.Conversations.close/1` continues to drop the subscription AND tear down the tmux pane; PaneSession's terminate cascades from the pane-died event.
- Update logging: `pane_id=<id> identifier=<id> command=opencode_attach`.

**Patterns to follow:**
- `elixir/lib/aiur/pane_manager.ex` existing `open_conversation/3` for the surrounding structure.
- The cycling / anchor-chain logic (PR #51 territory) is delicate — touch only the *command string* and the BEAM-wrap call, not the slot allocation.

**Test scenarios:**
- Happy path: `Aiur.Conversations.open("MT-123", caller)` boots a `PaneSession`, then respawns the tmux pane with `opencode attach`-shaped command (assert via the `{:mock, pid}` tmux transport's recorded args).
- Happy path: same identifier, second `open/2` reuses the existing tmux slot AND the existing `PaneSession` (the `PaneSession` is identifier-keyed via Registry — if already alive, return its existing attach URL).
- Edge case: queued issue → PaneSession comes up with empty replay; tmux pane respawns; chat is empty until operator submits. Covers AE for R9.
- Edge case: opencode startup fails → wrapper shell times out at 15 s and prints the bind/start error; operator sees an error toast/banner via `Aiur.Alerts.emit_custom("opencode.pane_start_failed", ...)`.
- Edge case: bridge dead before pane open (after BridgeSupervisor exit) → operator sees `Aiur.Alerts.emit_custom("opencode.bridge_unavailable", ...)` with the configured port and the override hint; PaneSession.start/2 returns `{:error, :bridge_unavailable}`.
- Edge case: pane closes → PaneSession is terminated; subsequent open is a cold start.
- Regression: slot cycling still works correctly (run the existing slot-cycle test, ensure it doesn't break).

**Verification:**
- `mix test elixir/test/aiur/pane_manager_test.exs` passes.
- Manually: `aiur` → press Enter on a running issue → opencode TUI loads with backfilled history → type a message → see streaming response.

---

- [ ] U11. **Remove `lib/aiur_pane/*`, `pane_rpc.ex`, `pane_warm_pool.ex` + CLI dispatch**

**Goal:** Delete the in-process pane scaffold now that opencode owns the pane. Remove the `conversation` CLI subcommand. `PaneWarmPool` (a scaffold-only no-op confirmed to have no callers) is deleted in this PR rather than deferred. Trim coverage-ignore entries.

**Requirements:** R11

**Dependencies:** U10 (cutover must be live and verified before deletion).

**Files:**
- Delete: `elixir/lib/aiur_pane/cli.ex`, `elixir/lib/aiur_pane/conversation.ex`, `elixir/lib/aiur_pane/composer.ex`, `elixir/lib/aiur_pane/viewport.ex`
- Delete: `elixir/lib/aiur/pane_rpc.ex` (verify no remaining callers via `grep -rn PaneRPC elixir/`)
- Delete: `elixir/lib/aiur/pane_warm_pool.ex` (verified zero callers; scaffold-only no-op per scope review SG-04)
- Delete: `elixir/test/aiur_pane/` (entire subtree)
- Modify: `elixir/lib/aiur/cli.ex` (remove `["conversation" | rest] -> AiurPane.CLI.main(rest)` dispatch branch and any helper)
- Modify: `elixir/mix.exs` (remove `AiurPane.*`, `Aiur.PaneRPC`, `Aiur.PaneWarmPool` from `:test_coverage.ignore_modules`)
- Modify: `elixir/lib/aiur/pane_manager.ex` (remove `wrap_with_unique_node/2` if no callers remain — opencode skipped it in U10)

**Approach:**
- Methodical deletion + grep for stragglers. The `Aiur.PaneRPC` module was the single chokepoint for cross-node calls from the pane BEAM; with no pane BEAM, no callers should remain. If any do (unlikely), surface them in this unit and route through a different path.
- Coverage list cleanup: lines 41-71 in `elixir/mix.exs` list pane-related modules as ignored from the 100% threshold. With the modules deleted, the ignore entries must be removed too or Coveralls will complain about unmatched ignore patterns.

**Test scenarios:**

**Test expectation:** none — this unit is pure deletion + ignore-list maintenance after the cutover (U10) has been verified manually. No behavior to test; the existing suite is the regression guard.

**Verification:**
- `mix test` passes with the deleted files gone.
- `grep -rn "PaneRPC\|AiurPane\|aiur_pane\|PaneWarmPool" elixir/lib elixir/test` returns no hits.
- `mix coveralls.html` does not warn about unmatched ignore patterns.

---

- [ ] U12. **Documentation: WORKFLOW.md, SPEC.md (repo root), AGENTS.md, brainstorm refresh**

**Goal:** Update the docs that describe Aiur's chat surface, config contract, and design intent. SPEC.md lives at the repo root, not under `elixir/` (per scope review SG-06).

**Requirements:** R1, R11, R12

**Dependencies:** U1–U11.

**Files:**
- Modify: `elixir/WORKFLOW.md` (add the `opencode:` config section with field-by-field docs; default values; note that `serve_args` is operator-trusted)
- Modify: `SPEC.md` (at the repo root — update the chat-surface section; note that opencode is now the pane chat)
- Modify: `elixir/AGENTS.md` (add a paragraph: the pane runs opencode; the bridge is the integration boundary; future modifications to chat UX go through `Aiur.Opencode.Protocol`; opencode SQLite store at `~/.local/share/opencode/` contains a copy of transcripts; **if Aiur is restarted while a pane is open, the pane's bearer token becomes stale — close and reopen the pane to refresh** — operators should be aware of this recovery action)
- Modify: `elixir/README.md` and root `README.md` (anything mentioning the conversation pane; add opencode install instruction)
- Modify: `elixir/docs/opencode-pane-brainstorm.md` (add a closing block noting that the plan landed and pointing readers at the plan file)

**Test scenarios:** none (documentation).

**Test expectation:** none — docs change only.

**Verification:**
- `mix pr_body.check` (from existing tooling) passes.
- Manual scan: every doc mentioning the old pane has been updated.

---

## System-Wide Impact

- **Interaction graph:** The bridge listener is a new HTTP entry point; the per-pane process tree (PaneSession + Server + EventConsumer + TranscriptRelay) is a new live subtree under `Aiur.Supervisor`. The `AgentPubSub` consumer count goes up by one per open pane (the TranscriptRelay's live phase). `Aiur.Conversations.open/close` callers (currently `Aiur.AgentList.App` Enter handler) get the new flow transparently.
- **Error propagation:** opencode failures are local to a pane — the PaneSession crashes, the supervisor declines to restart it (`:transient`), the operator sees a closed pane. Aiur's agent runtime is unaffected. The shim does not "fail" on agent errors; it streams `:alert` events back as chunks and waits for the next operator message.
- **State lifecycle risks:** The `:user` transcript event is now broadcast in two places — `AgentChat.send/3` always, and historically the pane process re-broadcast on local echo (no longer). The relay in U6 must filter `:user` events to prevent double-echo. The relay's PubSub subscription is per-pane; if a pane is closed and reopened, the new relay resubscribes — no stale broadcasts.
- **API surface parity:** The existing `POST /api/v1/:identifier/messages` dashboard endpoint continues to work — the shim is a *separate* surface, not a replacement for the existing observability API. Anyone driving Aiur via the existing API sees no change.
- **Integration coverage:** Replay + live publish + shim turn-end signaling all converge in the operator's chat. Unit tests mock individual seams; an end-to-end integration test (PaneSession with a real fake-opencode binary and a real `AgentPubSub` setup) exercises the full pipeline.
- **Unchanged invariants:**
  - `Aiur.AgentChat.send/3` semantics, including `:checkpoint` + `:queue_next` policy and the `:user` PubSub broadcast.
  - `Aiur.Orchestrator.send_operator_message/3` queue model.
  - `Aiur.Orchestrator.resume_agent/1` (used for R9 queued-pane auto-start) — existing public API; not modified.
  - `Aiur.AgentRunner` pause/resume queue-restore logic (`agent_runner.ex:445-452` footgun avoided).
  - `Aiur.AgentEventLog.write/3` schema; the relay reads but never writes.
  - `Aiur.AgentEvents.transcript_event/3` shape.
  - `Aiur.PaneManager` slot-cycling / anchor-chain logic.
  - `Aiur.Conversations.open/close` public shape.
  - `Aiur.Alerts.emit_system/2` / `emit_custom/3` — used by U7; not modified.
- **Changes (v3):**
  - `Aiur.AgentPubSub` gains `broadcast_turn_event/3` — additive on the existing per-identifier topic (`AgentEvents.agent_topic/1`). Existing subscribers continue to receive only the messages they pattern-match on; the new tuple shape `{:turn_event, id, event_tag, payload}` is ignored by current consumers (`AgentList.App`, `IssueLog`, etc.) which already match on `:transcript_event` / `:alert_event` tuples specifically. Verify via grep that no existing consumer uses a catchall `handle_info({_, _, _, _}, ...)` clause that would accidentally swallow this.
  - `Aiur.AgentRunner.codex_message_handler/4` gains a turn-event branch that calls `AgentPubSub.broadcast_turn_event/3` with the propagated `turn_id`. Pure additive; no existing call sites change behavior.
  - `Aiur.AgentChat.send/3`, `Aiur.Orchestrator.send_operator_message/3`, and `Aiur.AgentRunner` accept and thread an optional `turn_id` field. Existing callers (dashboard LiveView, observability API) continue to work without supplying it; broadcasts from those code paths simply omit the `turn_id` field, which the bridge handler treats as a different turn than its own and filters out.
  - `Aiur.Opencode.TokenRegistry` is a new public ETS-backed module; no existing call site is affected.

---

## Dependency Posture

Aiur's chat surface becomes load-bearing on a third-party project. The Protocol module absorbs *wire-format drift*; the broader posture this plan accepts:

- **What `Aiur.Opencode.Protocol` can absorb:** event-name renames, message-part schema changes, `opencode.json` schema evolution within an existing top-level shape, CLI flag changes, chat-completion-chunk field additions/renames, opencode SQLite store path changes. A version bump is one file changed.
- **What Protocol cannot absorb:** opencode removing its custom-provider extension point, removing or changing its session API model, switching from HTTP to a different transport, dropping the TUI attach mode, or any change that makes the "external LLM provider" abstraction obsolete. These would require redesigning the integration approach.
- **Discontinuation / pivot risk.** opencode is an external project under active development by `sst/opencode`. Aiur has no control over its roadmap. If opencode is discontinued, license changes, or pivots away from the terminal use case, Aiur loses its chat surface. Mitigations: the deleted `lib/aiur_pane/*` files remain recoverable from git history for one release cycle (this PR's parent commit) — a rollback PR could restore them and re-disable the bridge subtree without touching `AgentChat`, `Orchestrator`, or anything in the agent runtime. A new chat surface against a different TUI would also be possible by writing a new adapter against the same internal contracts.
- **Verified-version policy.** `Aiur.Opencode.Protocol` records a `@verified_min`/`@verified_max` range. Operators running an unverified version see a `:warning` log at boot (not a hard failure). The CI test suite verifies against one pinned opencode build per release.
- **Release coupling.** Aiur's release cadence is *not* coupled to opencode's. New opencode releases land independently; operators upgrade Aiur on Aiur's schedule. The Protocol module's job is to make verified-version updates a one-PR-per-bump operation rather than a refactor.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| opencode CLI not installed on operator's machine | `Aiur.Opencode.Config.validate!/0` checks PATH at boot; clear error message guides install. Add install instructions to `elixir/README.md`. |
| opencode HTTP/SSE wire format drifts between versions | `Aiur.Opencode.Protocol` owns every opencode-specific shape; a version bump touches one file. `Server` logs the running version vs. the verified range at boot. Snapshot tests on `opencode.json` catch silent schema drift. |
| Vercel AI SDK chat-completion chunk shape varies (tool-call deltas in particular) | The chunk shape lives in `Aiur.Opencode.ChatCompletions.build_chunk/2` (moved out of Protocol per SG-R3-Protocol). Implement against the documented shape; verify with a real opencode build during U4. If quirks appear, contain them there and document the deviation. |
| Backfill replay slow for very long-running issues | Acceptable in v1; if it bites, add an optional "last N events" cap (the brainstorm's Recent-Only Replay option, already designed). |
| `logs/agent.ndjson` malformed lines from a partial write | Backfill skips with `:debug` log. Existing best-effort writer never crashes; symmetry holds. |
| Long-lived SSE connections leak under load | Each chat-completion SSE handler unsubscribes from PubSub on exit; tests assert subscription count returns to baseline after stream end. Bandit handles half-open connections natively. The `thousand_island_options: [num_connections: 50]` cap (SEC-004 / FEAS-02) bounds the total. |
| Unauthenticated bridge in container/WSL2 deployments | Bearer-token auth via per-startup UUID shared secret in `opencode.json`'s `apiKey` field (SEC-001). Closes the hole at zero operator cost. |
| Injection through EEx templating of generated config files | `opencode.json` is built as an Elixir map and `Jason.encode!`-ed; no string interpolation (SEC-002). |
| Model-name regex over-captures path-traversal sequences | Regex uses an explicit allow-list character class (`[A-Za-z0-9._-]+`) matching `Aiur.Workspace.safe_identifier/1`; HTTP 400 on mismatch (SEC-003). |
| `/u` regex flag divergence from `Aiur.PaneRPC` control-char strip | Shim uses the exact same regex with no `/u` flag (SEC-006). UTF-8 validity is checked separately via `String.valid?/1` before strip. |
| Operator data secondary storage in opencode SQLite | Documented in `AGENTS.md`: opencode mirrors transcripts at `~/.local/share/opencode/`. Operators apply the same retention policy as `agent.ndjson` (SEC-005). |
| The bridge port collides with a port the operator uses | Default to `4097`; allow override via `opencode.bridge_port`. The `Aiur.Opencode.BridgeSupervisor` wraps the Bandit listener with `:rest_for_one, max_restarts: 1, max_seconds: 5` so a bind failure shuts down only the bridge subtree — the dashboard stays up. Boot-time `:warning` log identifies the port. (ADV-R2-08) |
| Pane slot cycling regression during cutover | U10 explicitly limits changes to the command string + BEAM wrap bypass. Existing cycling tests (post PR #51) are the regression guard. |
| Operator switches `/models` in opencode mid-session | `opencode.json` declares only the Aiur provider and a single per-issue model. There is nothing else to switch to, and `permission` blocks provider changes if the version supports it. Closed at config time. (ADV-R2-10) |
| Turn-end signal could be circular (opencode session.idle holds open the very SSE response that keeps it busy) | Turn-end is sourced from `Aiur.Codex.CodingAgent` / `Aiur.Claude.CodingAgent`'s existing turn events, rebroadcast via `Aiur.AgentPubSub.broadcast_turn_event/3` with a turn-id. The bridge handler pattern-matches `{:turn_event, identifier, _, %{turn_id: ^turn_id}}` on the per-identifier topic. opencode's `session.idle` is observed for logging only. (FEAS-01 / R13 / R14) |
| Missing PubSub broadcast surface for turn-end signal | `Aiur.AgentPubSub.broadcast_turn_event/3` added in U4 alongside the consumer. Uses the existing `AgentEvents.agent_topic/1` topic — no new subscription helper. (FEAS-03) |
| Bandit option name drift (`transport_options` vs `thousand_island_options`) | v3 uses `thousand_island_options: [num_connections: 50]`, the documented Bandit knob. Tested via the BridgeSupervisor startup integration test. (FEAS-02) |
| TranscriptRelay race between file read and PubSub subscribe | The relay subscribes to PubSub *before* opening the file and dedups any live event by `timestamp <= highest_replayed_ts`. (FEAS-04) |
| Chat-completions handler double-echoes operator input | The streaming loop in U4 filters out `:user` transcript events explicitly (opencode renders the operator's input locally). This is in addition to the U6 TranscriptRelay filter. (FEAS-06) |
| Queued-pane retry loops infinitely | The handler retries `AgentChat.send/3` exactly once after `resume_agent/1`, with a 5 s await on a `:running` status broadcast or any chunk arrival. No second resume cycle. (ADV-R2-07) |
| CodingAgent crashes / hangs mid-turn — bridge SSE never closes | 10-minute idle watchdog in the SSE handler; on fire, synthesizes a `finish_reason: "timeout"` chunk with operator-visible message. (ADV-R3-Watchdog) |
| `:turn_input_required` leaves SSE stream silent | Bridge handler treats `:turn_input_required` as a stream-terminating event with `finish_reason: "tool_calls"` and a synthetic text chunk pointing operator to the dashboard. (ADV-R3-InputRequired) |
| Stale `:turn_completed` broadcast closes wrong stream | Per-turn UUID `turn_id` minted by bridge, propagated through `AgentChat.send/3` → `Orchestrator` → `AgentRunner`, stamped on all broadcasts; bridge ignores broadcasts whose `turn_id` doesn't match. (R14 / ADV-R3-Stale) |
| Cross-pane injection via shared global bearer token | Per-workspace token generated in `WorkspaceSetup.materialize/4`, stored in `Aiur.Opencode.TokenRegistry` ETS keyed by `{token, identifier}`. Bridge requires both to match. (R15 / SEC-R3-CrossPane) |
| Aiur restart leaves opencode pane with stale bearer | Bridge returns a structured 401 body explaining "close and reopen the pane to refresh the token"; operator action is documented in `elixir/AGENTS.md`. (ADV-R3-RestartBearer / SEC-R3-StaleToken) |
| Concurrent dashboard + pane sends bleed into pane SSE | Transcript broadcasts now carry `turn_id`; bridge SSE handler filters to its own `turn_id` only. Dashboard turns broadcast on the same topic but with a different `turn_id` and don't appear in the pane stream. (R16 / ADV-R3-Concurrent) |
| Orphan-reap kills wrong process | PID identity verified via `/proc/<pid>/comm` (Linux) or `ps -o comm= -p` (Unix) match against `opencode` before SIGTERM. Reap skipped on platforms without either. Field renamed from `aiur_pid` to `opencode_os_pid` and sourced from `:erlang.port_info(port, :os_pid)` to remove BEAM-vs-OS PID ambiguity. (ADV-R3-PidReuse / SEC-R3-PidValidation / FEAS-R3-PidShape) |
| Orphan-reap reads PID after materialize overwrites it | `PaneSession.init/1` reads the prior `opencode.json` PID **before** the first `materialize/4` call rewrites the file. (FEAS-R3-ReapOverwrite / COH-R3-Reap) |
| Timestamp dedup silently broken by `timestamp_for/1` fallback | Promoted decoder in `Aiur.AgentEvents.transcript_event_from/1` parses ISO8601 binary timestamps via `DateTime.from_iso8601/1`. Composite `{timestamp, sequence}` key with per-identifier monotonic counter handles sub-millisecond collisions. (FEAS-R3-Timestamp / ADV-R3-Dedup) |
| BridgeSupervisor restart strategy wrong for both bind and crash | Bandit child declared `restart: :temporary`; bridge stays down after any failure rather than flapping. Dashboard unaffected by bridge subtree exit. (FEAS-R3-BridgeIso / ADV-R3-RestartCap) |
| Bearer token leaks via `Plug.Logger` headers | No `Plug.Logger` — bridge uses a custom redacting log helper. `ApiClient` is similarly configured. Test asserts no log line during a bridge request contains the token. (SEC-R3-LogLeak) |
| Backend asymmetry — Claude doesn't emit `:turn_cancelled` / `:turn_input_required` | The broadcast wiring in `AgentRunner` accepts these events from any backend that produces them. Claude's `{:ok, :turn_completed}` returns at lines 499/593 are normalized into `on_message` events by a small adapter in this unit so the broadcast surface is backend-agnostic. (FEAS-R3-ClaudeParity / ADV-R3-ClaudeShape) |

---

## Accepted Tradeoffs

Surfaced by the 2026-05-20 review round but deliberately accepted without an action item:

- **5 s queued-pane resume timeout is heuristic.** Based on a generous 5× buffer over typical sub-second agent startup; expose as `opencode.queued_pane_resume_timeout_ms` only if field experience shows tuning is needed.
- **Premise lacks pre-built incident data.** The plan does not cite specific operator support tickets or usage metrics motivating the rewrite. The decision to replace the pane is a forward-looking architectural bet (stop maintaining custom chat UI, move to a maintained external one), not a pain-driven response to documented user complaints. This is acknowledged explicitly here rather than dressed up as user-need.
- **opencode install friction unquantified.** Operators must install opencode separately; `validate!/0` fails fast with a clear error and a README pointer. We don't currently know the average install time. Acceptable; revisit if onboarding feedback says otherwise.
- **Opportunity cost not formally weighed against alternatives.** Two unconsidered paths — incrementally extending the existing pane vs. doing nothing — are real options. We accept the swap because the existing pane has been a recurring source of brittleness and the integration boundary is bounded.
- **Identity positioning is implicit.** Replacing the chat surface with a third-party TUI nudges Aiur toward "orchestrator-with-opencode-frontend" rather than "integrated dashboard." For an internal tool this is fine; flagging here so the framing doesn't get re-litigated in every future planning doc.
- **`system`/`alert` and agent text share the same visual weight.** Both render as opencode assistant text parts with a markdown bold prefix (`**system:**`, `**alert:**`). If operators struggle to distinguish, we can iterate (richer formatting, opencode color hints) in a follow-up.
- **`/models` UX outcome depends on opencode internals.** Lockdown via single-provider config means `/models` either fails or shows an empty list; the exact rendering depends on the opencode version. Acceptable — operators are documented as not using `/models` for pane sessions.
- **Permission block "safe defaults" — exact key list is implementation-time.** The opencode permission schema will be enumerated in `Aiur.Opencode.Protocol.opencode_json/1` during U2 against the verified opencode version's docs. Tool-execution permissions stay default-deny; safe auto-approvals are limited to read-only / display-only operations.
- **Orphan-reap is belt-and-suspenders.** Port closure already SIGTERMs the wrapping bash; the explicit PID reap covers the narrow window where opencode survives the bash exit. v1 ships with the reap because the implementation cost is small and it eliminates one possible long-tail bug class.
- **`req`'s `into:` callback assumes non-blocking handlers.** The EventConsumer's chunk-processing callback merely parses SSE frames and dispatches to PubSub / Alerts — no blocking I/O. If a future change adds a slow op inside the callback, it should be moved to a separate process to avoid SSE backpressure.
- **Multi-chunk turn boundary handling.** `Aiur.Opencode.ChatCompletions.build_chunk/2` threads a per-turn `completion_id` through every emitted chunk so Vercel AI SDK sees a consistent envelope. Tool-call partial-aggregation lives inside `ChatCompletions`.

---

## Documentation / Operational Notes

- `WORKFLOW.md` gains a documented `opencode:` section. Default values mean existing workflows continue without changes.
- `scripts/aiur` does not need to change — the shim binds the new `opencode.bridge_port` from the workflow.
- Logging: every new module emits `key=value` logs including `issue_identifier` and (where applicable) `opencode_session_id` and `opencode_version`. See `elixir/docs/logging.md`.
- opencode SQLite store at `~/.local/share/opencode/` is a secondary location for transcript content; documented in `AGENTS.md` so operators applying retention policy to `agent.ndjson` know to extend it.
- After this PR lands, the `Aiur.Opencode.*` module group becomes a candidate for a `docs/solutions/` capture via `/ce-compound`, since several patterns (long-lived SSE consumer, external process Port lifecycle, OpenAI-compatible shim, isolation-module-for-external-protocol) are first-time in this codebase.

---

## Sources & References

- **Origin document:** [elixir/docs/opencode-pane-brainstorm.md](../opencode-pane-brainstorm.md)
- Repo research: commit history of branch `aiur/60-opencode-pane-chat`
- opencode docs: https://opencode.ai/docs/server/, https://opencode.ai/docs/providers, https://opencode.ai/docs/cli, https://opencode.ai/docs/plugins/, https://opencode.ai/docs/config
- Related issues: aiur#60 (this), aiur#33 (BYO Codex/Claude — superseded direction)
- Project rules: `elixir/AGENTS.md`, `AGENTS.md`
