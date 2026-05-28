---
status: active
created: 2026-05-25
scope: standard
links:
  - elixir/docs/notes/opencode-row-shapes-1.15.6.md
  - docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md
---

# Aiur chat pane — native opencode parity + aiur event surface

## Problem frame

Aiur's chat panes (opencode-attach TUI) don't faithfully show what an agent is doing while it works. Every codex transcript event becomes its own synthetic assistant message, so a single agent turn produces dozens of stacked `▣ Build · issue-N · timing` chrome headers with mostly empty bodies. Codex's `reasoning`, `dynamicToolCall` (MCP), and `fileChange` items are silently dropped entirely, and bash tool parts are written in a shape opencode's TUI can't render cleanly (literal `$ ` prefix in `state.input.command`, empty `state.output`, cryptic `$ cmd [exit=0]` used as the title).

The operator's job-to-be-done with the chat pane is **watching the work happen** — following commands, reasoning, and edits in real time the way they'd watch a native opencode session. Today they can't.

## Users / actors

- **Operator** — the human running aiur, watching agents work across multiple chat panes.
- **Agent** — codex (or future coding agents) emitting transcript events into the workspace event log.
- **Opencode TUI** — the renderer in the chat pane; consumes the SQLite `message` + `part` rows aiur synthesizes. We can't modify it.

## Goals

1. Each chat pane should faithfully reflect what the agent did during a turn — text, reasoning, tool calls, file edits — using the rendering opencode already does well.
2. Each codex turn becomes **one** assistant message containing all of its parts, not many one-event assistant messages.
3. Aiur's distinctive surface (cross-ticket coordination events the agent has subscribed to, outgoing aiur tool calls) shows up *inline* in the same chat pane, so the operator doesn't have to context-switch between aiur's event ticker and opencode's content.

## Requirements

### R1. One assistant message per codex turn

Group every codex event sharing a `turnId` into a single synthetic assistant message. The assistant message:

- **R1.1** Materializes on the first codex event of a turn (any item type). Writes the `message` row with `mode: "build"`, `agent: "build"`, `providerID: "aiur"`, `modelID: "issue-<safe_id>"`, `finish: "stop"` (placeholder until turn ends).
- **R1.2** Immediately gets a `step-start` part appended.
- **R1.3** Accumulates body parts as each codex item completes (see R2). Append-only; no UPDATE of existing rows mid-turn.
- **R1.4** On `turn_completed` / `turn_failed` / `turn_cancelled` / `turn_input_required`, appends a `step-finish` part with `reason` reflecting the terminal kind (`stop`, `tool-calls`, `error`, `cancelled`, etc. — exact mapping is a planning decision).
- **R1.5** Out-of-turn events (i.e., codex events with no `turnId`, or events arriving after the turn's step-finish) start a new message with their own step-start/step-finish, rather than appending to a closed turn.

### R2. Translate every codex item type aiur cares about

The codex item types codex 0.x emits, and how each should render:

| Codex item | When | Aiur part shape |
|---|---|---|
| `agentMessage` | `item/completed` (deltas ignored) | `text` part with the completed message text |
| `reasoning` | `item/completed` (deltas ignored) | `reasoning` part with the reasoning text + `time: {start, end}` |
| `commandExecution` | `item/completed` only | `tool` part with `tool: "bash"`, clean shape (see R3) |
| `dynamicToolCall` | `item/completed` only | `tool` part with `tool: "<tool name from codex>"`, input/output/title from the item payload |
| `fileChange` | `item/completed` only | `tool` part with a tool name that opencode's TUI renders (planning decides: `"edit"`, `"write"`, or a synthetic one), input describing the file + change |
| `userMessage` | — | **No change** — operator messages already render via the existing path |

`item/started` and `*/delta` events are not translated. They feed perf telemetry but don't get their own part. (This is the deliberate "no output streaming" trade-off for this PR — see Deferred section.)

### R3. Clean tool-part shape

For `commandExecution`, the tool part state shape matches what native opencode itself writes:

```jsonc
{
  "type": "tool",
  "tool": "bash",
  "callID": "call_<id>",
  "state": {
    "status": "completed",
    "input": {
      "command": "<the raw command, NO literal '$ ' prefix>",
      "description": "<human-readable summary from codex, if present>",
      "timeout": <ms, if codex provides>,
      "workdir": "<agent workspace cwd>"
    },
    "output": "<captured stdout — see R3.1>",
    "metadata": {},
    "title": "<description>",
    "time": {"start": <ms>, "end": <ms>}
  }
}
```

- **R3.1** Capture command output. Codex emits `item/commandExecution/outputDelta` as the command runs, and the completed `commandExecution` item carries the final stdout (or a snapshot of it). Aiur accumulates those deltas in-memory keyed by `itemId` and writes the assembled output into `state.output` when the item completes. Implementation lives in `agent_runner.ex` codex_message_handler, before broadcasting the transcript event.
- **R3.2** `state.title` shows the codex-supplied description when present; falls back to the first 60 chars of the command when not.
- **R3.3** `state.input.workdir` is the agent's workspace path (the same value the SessionWriter uses for the message's `path.cwd`).

For `dynamicToolCall` and `fileChange`, mirror the same conventions — clean `input`, populated `output`, descriptive `title`. Exact field mapping is a planning task; codex's item payloads are the source of truth.

### R4. Cross-ticket received events render inline in chat

When an agent has subscribed to another ticket's events (via the issue #22 events-foundation surface — `aiur_subscribe`, auto-subscribe on `aiur_declare_blocker`), every event Aiur delivers from its inbox renders in this agent's chat pane as a synthetic assistant message immediately before / after the agent's own turn boundary.

- **R4.1** One synthetic message per received event (not grouped into the agent's turn — these are external signals).
- **R4.2** Rendered as a single `text` part with a clear visual marker. The exact format is a small design surface for planning, but should make it obvious this is an *incoming* signal, not the agent's own output. Suggested skeleton: a single text part containing the event topic, source ticket, payload summary, and id — opencode renders text parts cleanly without needing custom shapes.
- **R4.3** Always shown — independent of `--debug`. The whole point of subscribing is to react to these.
- **R4.4** Cards are written once on event-delivery, never re-emitted on session writer replay (avoids the duplicate-render class of bug).

### R5. Outgoing aiur tool calls render inline in chat — debug only

When the agent calls aiur-owned tools (`emit_event`, `emit_alert`, `aiur_subscribe`, `aiur_declare_blocker`), each call renders as a `tool` part inside the current turn's assistant message — only when `--debug` mode is active.

- **R5.1** Gated on the runtime `--debug` flag. In normal runs the operator doesn't see these (the action's effect is visible elsewhere: alerts fire sound, events appear in other panes).
- **R5.2** When shown, the tool part uses the same clean shape as R3 (input = the tool's arguments, title = a short description like `"emit_event progress.brainstorm-end"`, output = the tool's result / ack).
- **R5.3** Part of the current turn's message (per R1), not a standalone synthetic message.

### R6. Resolve duplicate assistant-text rendering

The operator currently sees the same "Starting work on issue #99..." text appear twice in the chat pane shortly after attach. Root cause unknown — candidates: `replay_history` racing with live PubSub (writer subscribes after the first event lands in IssueLog but before SQL replay finishes), codex re-emitting the same item under a different itemId, or the synthetic-stream marker path triggering a second insert.

- **R6.1** Find the duplicate's mechanism and prevent the second write. Planning will investigate; the fix shape is part of planning, not requirements.
- **R6.2** Guard via SessionWriter dedup (by `itemId` if codex supplies one, or `(turn_id, role, body)` hash) so this class of bug doesn't regress.

## Acceptance examples

- **AE1 (R1):** Agent runs `mix test` (10 commands) + writes one summary text. Chat pane shows ONE `▣ Build · issue-N · timing` header, with reasoning/tool/text parts stacked below it inside that one message. NOT 10+ stacked headers.
- **AE2 (R2):** Agent uses `Read` tool (codex `fileChange` or `dynamicToolCall`) on three files. Each appears as a distinct tool part inside the turn's message, with the file path visible.
- **AE3 (R3):** A `git status --short` run shows `state.input.command = "git status --short"` (no `$ ` prefix), `state.title = "Shows current git status"` (or similar description), `state.output = "?? test-sandbox/\n"` (real stdout), `state.input.workdir = "/home/.../aiur-workspaces/<issue-id>"`.
- **AE4 (R4):** Agent on ticket 100 has `aiur_declare_blocker(99)`. Ticket 99 emits `progress.tests-green`. Ticket 100's chat pane shows an incoming-event card with `topic = ticket.99.progress.tests-green`, source ticket, and timestamp. Card appears even in non-`--debug` runs.
- **AE5 (R5, --debug):** Agent calls `emit_event("progress.brainstorm-end")`. With `aiur --debug ...`, the chat pane shows a tool part `emit_event progress.brainstorm-end` inside the current turn. Without `--debug`, the part does not appear.
- **AE6 (R6):** Attach to an agent mid-run, then detach and re-attach. The "Starting work on issue #N..." opening message appears exactly once in chat history each time, not twice.

## Scope boundaries

### In scope

- Per-turn message grouping using `turnId`.
- Translating reasoning, dynamicToolCall, fileChange items (currently silently dropped).
- Clean bash tool-part shape with captured output.
- Inline rendering of received cross-ticket events (always) and outgoing aiur tool calls (`--debug` only).
- Resolving the duplicate-text-render bug.

### Deferred for later

- **Real-time output streaming during a long-running command.** `state.output` is populated at item completion only, not while output is still arriving. (Trade-off: requires SessionWriter UPDATE of part rows, which is meaningful new contention with opencode's read path. Worth scoping separately once R1–R6 are live.)
- **Workflow-phase milestone markers** (brainstorm→plan→work→review separators inside chat). Considered but not selected — the existing alert sounds + agent-list ticker already communicate phase transitions.
- **Reasoning-item visibility toggle.** Reasoning is always shown for now. If the operator finds it noisy in practice, add a UI toggle later.
- **Restoring user/operator messages on re-attach.** Out of scope — the existing path already renders these during the live session.

### Outside this product's identity

- We are NOT writing our own TUI. Opencode-attach owns the chat-pane TUI; aiur synthesizes opencode-shaped rows for it to render.
- We are NOT modifying opencode source. Anything that needs "wait for opencode to support X" is by definition deferred.
- We are NOT replacing aiur's existing event ticker (debug surface on agent_list pane). The chat-pane event cards are a complement, not a replacement.

## Dependencies / assumptions

- **Issue #22 events-foundation** (the surface this PR is built on) lands the subscription delivery and emit primitives R4 / R5 depend on. This brainstorm assumes the surface is stable on `aiur/22-events-foundation`; if it churns during this PR, R4 / R5 may need rework.
- **Codex 0.x event shapes** match what the issue-100 ndjson sample dump captured on 2026-05-25: `item/started`, `item/completed`, `item/<type>/outputDelta`, `turn/started`, `turn/diff/updated`, etc. The codex notification payload schema is treated as an external contract that aiur observes, not controls.
- **The opencode SQLite schema** (`message`/`part` tables, `data` JSON column) and rendering rules (parts ordered by lexical `id`) match the snapshot in `elixir/docs/notes/opencode-row-shapes-1.15.6.md`. The ULID-monotonic fix already shipped on this branch covers the part-ordering requirement.
- **`turnId`** is present on every codex event we care about. If codex ever omits it (e.g., on a synthetic or out-of-band event), R1.5 handles the fallback.

## Open questions for planning

1. **Turn-state lifetime:** SessionWriter currently has no per-turn state. Does the new turn buffer live on the SessionWriter GenServer's state, or in a small per-identifier `TurnBuilder` GenServer? (Planning decision — affects how interruption / crash / replay-on-attach behaves.)
2. **fileChange tool shape:** opencode renders certain tool names with special TUI styling (Read/Write/Edit native tools). What tool name should aiur use for codex fileChange items to get a clean rendering — `"write"`, `"edit"`, or `"fileChange"`?
3. **Event-card visual style:** R4 says "single text part with a clear visual marker." Does the marker mean a leading emoji + first-line, a bordered ASCII block, or just a `📥 received: ticket.99.progress.tests-green` header? Lock during planning.
4. **Replay across attach:** If a chat pane is re-attached mid-turn (e.g., user closed and reopened), `replay_history` rebuilds the SQLite rows. Open turns at the time of detach — do we replay them as closed (synthesize a step-finish with `reason: "stop"`) or skip the incomplete trailing turn entirely?

## Out-of-scope findings (for triage after this PR)

- Narrow-pane `???` characters + merged perf/ticker rows in the agent_list pane when chat panes split it narrower. Tracked as task #19. Separate bug surface, not chat-pane content.
