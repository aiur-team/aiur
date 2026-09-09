---
title: Paseo Integration - Plan
type: feat
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Paseo Integration - Plan

## Goal Capsule

- **Objective:** let the Executor watch and chat with aiur agents from a phone through Paseo, first on this machine with no aiur code change, then as an opt-in aiur feature anyone with Paseo can enable.
- **Product authority:** this document's Product Contract. The Remote Control (RC) history in `docs/brainstorms/2026-06-02-remote-control-toggle-requirements.md` and `docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md` is the precedent and carries the one hard constraint: a `claude` session has exactly one input source.
- **Recommendation:** Option 1 (local setup, zero code) now; Option 2a (a `paseo` coding-agent backend) as the native integration; Option 2b (aiur as a Paseo provider plugin) deferred until Paseo's plugin API leaves beta.
- **Open blockers:** none. KTD-1 and KTD-2 were settled by the 2026-09-09 spike; the implementation plan is the build order pack at `docs/build-order/paseo/`.

---

## Product Contract

### Summary

Add Paseo as a vendor-neutral mobile and desktop chat surface for aiur agents. Phase 1 is a documented local setup that needs no aiur change. Phase 2 is an opt-in `paseo` backend where Paseo owns the Claude or Codex process inside aiur's workspace, so aiur's turn loop and the phone share one input queue.

### Problem Frame

aiur drives agents autonomously and already offers one phone surface: Claude Remote Control. That surface is Claude-only, needs a subscription entitlement, harvests the session URL by scraping a tmux pane, and hands the whole agent off, so aiur stops driving while the phone drives (`src/lib/aiur/orchestrator/remote_control_mode.ex`, `src/lib/aiur/claude/repl/rc_attach.ex`). Codex agents have no phone surface at all.

Paseo is an Apache-licensed control plane (16.6k stars, v0.7.2 stable, v0.8.0 beta, about ten commits a day) with a local Node daemon, an end-to-end encrypted relay, native iOS and Android apps, and first-class Claude Code and Codex providers. It cannot attach to a process it did not spawn. Every agent Paseo shows is a process Paseo started, or a saved session Paseo re-spawned with `resume`. That single fact shapes every option below.

### What Paseo offers aiur (verified 2026-09-09 against `getpaseo/paseo` HEAD `726067b4`)

- Daemon: `npm install -g @getpaseo/cli`, `paseo daemon start`, config in `~/.paseo/config.json`, default listen `127.0.0.1:6767`, one port for HTTP, WebSocket, and MCP.
- Phone reachability: `paseo daemon pair` prints a QR for the E2E relay (`relay.paseo.sh`, self-hostable, Elixir). Tailscale direct connection also works. SSH tunnels are desktop and CLI only.
- Claude provider uses `@anthropic-ai/claude-agent-sdk` in-process with `permissionMode` passthrough including `bypassPermissions`, `settingSources: user, project, local`, `mcpServers`, `env`, and `resume: <sessionId>`.
- Codex provider speaks `codex app-server` JSON-RPC, the same protocol aiur already speaks, with `thread/resume` and a `full-access` mode preset.
- Any cwd is allowed: `paseo run --cwd <dir>` or `agents.create({ cwd })` auto-provisions a local workspace for that directory. Paseo does not need to own the worktree.
- Control surfaces: CLI (`run`, `send`, `attach`, `logs -f`, `import`, `permit`, `stop`, `archive`), TypeScript SDK `@getpaseo/client` over WebSocket, and a stateless streamable-HTTP MCP endpoint `POST /mcp/agents` with `create_agent`, `send_agent_prompt`, `get_agent_status`, `get_agent_activity`, `list_pending_permissions`, `respond_to_permission`, `kill_agent`, `archive_agent`, terminals, and schedules.
- Terminals: the app can open a PTY on the daemon host and send keys to it.
- Session import: `paseo import --provider claude --cwd <dir> <sessionId>` re-spawns `claude --resume`; Codex threads import through `thread/list`.
- Not available: attaching to a live foreign process, a streaming JSON CLI output, an Elixir SDK, a stable plugin API (0.8 beta), `stop` or `delete` on the SDK agent handle.

### aiur seams the work lands on

- `Aiur.CodingAgent.Backend` behaviour plus the registry in `src/lib/aiur/coding_agent.ex`: a new backend is one adapter module and one registry entry. The `openai_compat` adapter (324 lines) and `claude-repl` adapter (170 lines) are the size reference.
- Workspace path is a pure function of root, repo, and issue id, so a Paseo agent's cwd is stable for the life of the issue (`src/lib/aiur/workspace/layout.ex`).
- Session handles persist a backend and thread id per issue (`src/lib/aiur/session_handle.ex`), which is where a Paseo `agentId` and `workspaceId` would live.
- Executor messages flow through `Aiur.AgentChat` to `Backend.send_operator_message/2`; the phone would bypass this and type into Paseo directly, which is safe only when Paseo owns the process.
- Lifecycle hook settings for turn detection already exist and can be written into the workspace as a project settings file, which Paseo's Claude provider loads (`src/lib/aiur/claude/hook_settings.ex`).
- Config sections are Ecto embedded schemas under `src/lib/aiur/config/schema/`, and every key must appear in `website/docs-app/reference/configuration.md` or `scripts/check-config-docs.py` fails lint.
- The Stream Deck socket and channel (`src/lib/aiur_web/streamdeck_channel.ex`) are the precedent for a third-party push surface if aiur ever needs to feed Paseo instead of the reverse.
- aiur's dynamic tools (`emit_alert`, `emit_event`, `aiur_declare_blocker`, review-thread tools) exist only on the app-server backends. The interactive `claude-repl` backend already runs without them.

### Options

- **Option 0. Do nothing new.** Use the existing Claude Remote Control toggle and the Claude mobile app. Zero work. Claude-only, entitlement-gated, pane-scraped, and the handoff stops autonomous driving. Included as the counterfactual.

- **Option 1. Local setup on this machine, no aiur change.** Install the Paseo daemon, pair the phone over the relay or Tailscale, register the aiur repo and the target repos as Paseo projects. Three usable flows fall out:
  - **1a. Executor in Paseo.** Start a Paseo-managed Claude session in the aiur repo root with the `aiur-run` and `aiur-monitor` skills loaded. From the phone the Executor answers "what is agent 2519 doing", runs `aiur message`, pauses, resumes, and answers decisions. This matches aiur's own "your coding agent is the Executor" model and needs nothing new.
  - **1b. Terminal into a live REPL agent.** For agents on the `claude-repl` backend (label `model:remote` or `agent.remote_control: true`), open a Paseo terminal that runs `tmux attach -t <aiur pane>`. The phone sees the live interactive `claude` and can type into it, which is what `OperatorInject` does today. Headless app-server agents have no pane, so this covers REPL agents only.
  - **1c. Import a parked session.** Pause an agent in aiur, then `paseo import --provider claude --cwd <workspace> <sessionId>` to continue it from the phone. On return, `paseo archive` and resume in aiur, which re-dispatches by cwd. Manual, and the two-processes-one-transcript hazard from the RC history applies if the pause step is skipped.
  - **Effort:** 2 to 4 hours of setup plus one docs page. **Trade-offs:** no per-agent Paseo entries for headless agents, no permission prompts for aiur agents on the phone, and 1b and 1c only work for Claude REPL sessions or paused sessions.

- **Option 2a. Native opt-in: `paseo` coding-agent backend.** A new backend where aiur calls the Paseo daemon to create the agent in aiur's workspace, sends each turn prompt through Paseo, reads turn completion and activity from Paseo, answers permission requests from the Decision API, and archives the agent on terminal state. Paseo owns the `claude` or `codex` process, so the phone and aiur share one queue with no handoff. Selected per issue by label (`model:paseo-claude`, `model:paseo-codex`) or by `agent.routing`, and gated by a new `paseo:` config section with the daemon URL and password. Registry entry declares `remote_control: false`, `immediate_delivery: true`, `resumable: true` (Paseo persists sessions), and `fallback_backend` to the plain backend when the daemon is unreachable.
  - **Effort:** roughly 8 to 12 tickets, one to two weeks of fleet work: adapter, config schema and docs, an Elixir HTTP or WebSocket client for Paseo, session-handle persistence of `agentId`, hook settings written into the workspace, permission-request bridging, dashboard 📱-style indicator with the Paseo deep link, init-wizard detection of an installed daemon, tests with a fake daemon.
  - **Trade-offs:** Paseo's wire protocol is unversioned beyond `protocolVersion` in the hello frame and moves fast, so aiur must pin a tested Paseo version range and degrade loudly. Agents lose aiur's dynamic tools unless KTD-2 is solved. Paseo's daemon becomes a runtime dependency for those issues only, which is the opt-in the request asks for.

- **Option 2b. Native opt-in, inverse direction: aiur as a Paseo provider plugin.** Ship a Paseo server plugin whose `ProviderRegistration.connect()` bridges to aiur, so every aiur agent, headless included, appears in Paseo's list with chat and timeline, and aiur keeps owning the processes. Needs a push event API on aiur (a Phoenix channel modelled on the Stream Deck one) and a TypeScript shim implementing Paseo's `ProviderConnection` or ACP.
  - **Effort:** two to three weeks, across two repos and two languages.
  - **Trade-offs:** the plugin API is 0.8 beta and single-maintainer; the "one input source" constraint still forbids phone chat into a headless `claude` mid-turn, so this only mirrors what aiur can already route through `AgentChat`. Strongest long-term shape, wrong time.

- **Option 2c. Automated handoff toggle, Paseo edition.** Reuse `remote_control_mode.ex`: a `p` key stops the agent, runs `paseo import` on its session, and demotes with `paseo archive` plus re-dispatch. Gives Codex parity through thread import.
  - **Effort:** three to five days. **Trade-offs:** inherits every RC handoff bug class, and autonomous driving stops while the phone drives. Superseded by 2a, which removes the handoff entirely.

- **Option 3. Alternatives outside Paseo.** Expose aiur's own LiveView dashboard over Tailscale to the phone (`observability.dashboard_writable` is already true, so messaging works). No app, no relay, zero code, but no native chat fidelity. Worth a line in the docs page from Option 1 as the no-Paseo baseline.

### Recommendation

Do Option 1 now, in the order 1a, 1b, 1c, and write it up as a docs page. Then build Option 2a as the native integration. Defer 2b until Paseo's plugin API is stable, and drop 2c because 2a makes the handoff unnecessary.

The reasoning: every option that keeps aiur as the process owner runs into the one-input-source constraint that already sank dual chat for RC. Letting Paseo own the process for opted-in issues sidesteps it, gives Codex parity, and removes the pane scraping and entitlement checks. The cost is a protocol dependency on a fast-moving daemon, which the opt-in gate, a pinned version range, and `fallback_backend` contain.

### Requirements

**Local setup (Option 1)**

- R1. A docs page under `website/docs-app/` describes installing the Paseo daemon, pairing a phone over the relay or Tailscale, and registering the aiur repo and target repos as Paseo projects.
- R2. The page documents the Executor-in-Paseo flow: a Paseo Claude session in the aiur repo root, with the `aiur-run` and `aiur-monitor` skills, operating aiur from the phone.
- R3. The page documents the terminal-attach flow for `claude-repl` agents, naming the tmux session and pane naming that aiur uses and stating that headless agents have no pane.
- R4. The page documents session import for a paused agent and states the rule: pause in aiur first, archive in Paseo before resuming in aiur.

**Native backend (Option 2a)**

- R5. A `paseo` family of backends is selectable per issue by label and by `agent.routing`, and is absent from every code path when `paseo.enabled` is false.
- R6. The backend creates the Paseo agent with cwd set to the aiur workspace, the issue identifier as a label, and the permission mode aiur uses for that backend family.
- R7. aiur's turn loop drives the Paseo agent one prompt per turn and detects turn completion without polling faster than once per second.
- R8. Executor messages sent through `aiur message` and the dashboard reach the Paseo agent, and messages typed on the phone appear in aiur's transcript and event feed.
- R9. Permission requests raised by the Paseo agent surface as aiur Decisions, and a Decision answer resolves the Paseo permission.
- R10. The Paseo `agentId` and `workspaceId` persist in the session handle so an aiur restart re-attaches instead of re-creating.
- R11. Terminal issue state archives the Paseo agent; a crash or unreachable daemon falls back once to the plain backend and raises an Executor attention.
- R12. The agent list and dashboard show a phone indicator and the Paseo deep link for Paseo-backed agents, following the existing 📱 convention.
- R13. `aiur init` detects an installed Paseo daemon and offers to enable the section; every new config key is documented so `scripts/check-config-docs.py` passes.
- R14. Tests run against a fake Paseo daemon; CI does not require Paseo installed.

### Key Decisions

- **Paseo support ships as a separate package, `aiur-paseo`, not as core Elixir modules.** (session-settled: user-directed — chosen over an in-core `Aiur.Paseo.*` adapter: the operator's constraint that opt-in features must not bloat core, backed by the `planning/decompose-packages` research.) `aiur-paseo` is a TypeScript app-server sidecar in `packages/aiur-paseo/`, following the `aiur-claude` precedent; core gains registry data plus a generic app-server backend, resume passthrough, and a generic surface indicator. The full design is `docs/build-order/paseo/00-design.md`.
- **Paseo owns the process for opted-in issues.** Chosen over aiur-owned processes mirrored into Paseo, because a `claude` session accepts one input source and the RC work proved dual chat impossible.
- **Opt-in by config section plus label, never global.** A missing or disabled `paseo:` section changes nothing, matching the request's "opt-in dep" framing and the existing `model:<backend>` grammar.
- **Pin a tested Paseo version range.** The daemon reports `protocolVersion` in its hello frame; aiur refuses newer majors with a clear attention rather than guessing.
- **Docs page first.** Option 1 ships as documentation, not code, so it cannot regress the fleet.

### Scope Boundaries

Deferred for later:

- Option 2b (aiur as a Paseo provider plugin) until the plugin API is out of beta.
- Paseo Hub triggers, schedules, and push notifications.
- Codex approval bridging beyond what aiur's Decision API already models.

Outside this product's identity:

- Replacing aiur's tracker-driven scheduler with Paseo's workspace model. aiur stays the source of truth for tickets, workspaces, and lifecycle.
- Reverse-engineering Anthropic's RC relay to get dual chat on the existing backends.

### Outstanding Questions

- KTD-1 resolved (spike 2026-09-09). Transport is Paseo's official TypeScript SDK over WebSocket, used from the `aiur-paseo` sidecar; core speaks only the app-server JSON-RPC protocol it already speaks to `aiur-claude`. The MCP-over-HTTP endpoint was exercised and works but lacks `cwd`, `env`, and `mcpServers` on `create_agent`.
- KTD-2 resolved. The sidecar ports `aiur-claude`'s dynamic-tool bridge and passes it through Paseo's `mcpServers`, so Paseo-owned agents get every aiur coordination tool.
- Deferred. Whether Paseo's `daemon.mcp.injectIntoAgents` (default false) should be turned on so agents can spawn sub-agents; default no.
- Deferred. The composite `LICENSE` in the Paseo repo ("portions licensed as follows") needs a read before aiur documents it as a dependency.

### Success Criteria

- Option 1: from a phone, the Executor session answers a status question about a running agent and delivers an `aiur message` that the agent acts on; a `claude-repl` agent responds to text typed in a Paseo terminal.
- Option 2a: an issue labelled `model:paseo-claude` completes a full turn loop to PR with aiur driving, while the same agent is visible and chattable in the Paseo app, with no second `claude` process for that workspace at any time.
- `make all` green; `scripts/check-config-docs.py` green; a manual `scripts/aiurdev --test --force --allow-remote` run observed end to end for 2a.

---

## Appendix

### Paseo facts with sources (clone HEAD `726067b4`)

| Fact | Source in Paseo repo |
|---|---|
| Daemon default port 6767, relay endpoint default | `packages/server/src/server/config.ts:28-29` |
| WebSocket at `/ws`, hello handshake with `protocolVersion` | `packages/server/src/server/websocket-server.ts:810`, `packages/protocol/src/messages.ts:7136` |
| Bearer password auth, open MCP when no password | `packages/server/src/server/auth.ts:62-84,122` |
| Claude via Agent SDK, `resume`, `settingSources`, `mcpServers` | `packages/server/src/server/agent/providers/claude/agent.ts:3271-3326` |
| Codex via `codex app-server`, `thread/resume` | `packages/server/src/server/agent/providers/codex/codex-app-server-agent.ts:7016` |
| Arbitrary cwd auto-provisions a workspace | `packages/server/src/server/session.ts:3651-3660` |
| MCP tool catalog and HTTP endpoint | `packages/server/src/server/agent/tools/paseo-tools.ts`, `bootstrap.ts:1439` |
| Session import path | `packages/cli/src/commands/agent/import.ts` |
| Plugin provider contract (beta) | `packages/plugin/src/server/provider.ts:4-54` |
| No attach to foreign processes | absent from `agent-manager.ts`, `provider-registry.ts` |

### aiur seams with sources

| Seam | Path |
|---|---|
| Backend behaviour and registry | `src/lib/aiur/coding_agent/backend.ex`, `src/lib/aiur/coding_agent.ex:80-264` |
| Remote Control promote and demote | `src/lib/aiur/orchestrator/remote_control_mode.ex:69-165` |
| RC URL harvest by pane scrape | `src/lib/aiur/claude/repl/rc_attach.ex`, `src/lib/aiur/claude/remote_control.ex:34` |
| Hook settings for turn detection | `src/lib/aiur/claude/hook_settings.ex`, sink `src/lib/aiur_web/router.ex:178` |
| Executor message path | `src/lib/aiur/agent_chat.ex`, `POST /api/v1/:id/messages` at `src/lib/aiur_web/router.ex:160` |
| Session handle persistence | `src/lib/aiur/session_handle.ex`, `src/lib/aiur/agent_runner/session_resume.ex` |
| Workspace path policy | `src/lib/aiur/workspace/layout.ex:32-46` |
| Config section pattern | `src/lib/aiur/config/schema/opencode.ex`, root `src/lib/aiur/config/schema.ex:52-172` |
| Docs enforcement | `scripts/check-config-docs.py` |
| Third-party push surface precedent | `src/lib/aiur_web/streamdeck_channel.ex` |
| Decision API | `src/lib/aiur_web/router.ex:81-109`, `src/lib/aiur/decision_store.ex` |
