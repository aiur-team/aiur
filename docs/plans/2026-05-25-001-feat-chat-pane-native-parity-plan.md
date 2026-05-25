---
title: "feat: Aiur chat pane — native opencode parity + aiur event surface"
type: feat
status: active
date: 2026-05-25
origin: docs/brainstorms/2026-05-25-aiur-chat-pane-native-parity-requirements.md
---

# feat: Aiur chat pane — native opencode parity + aiur event surface

## Overview

Today aiur synthesizes one opencode assistant message per codex event, producing dozens of stacked `▣ Build · issue-N · timing` chrome headers per agent turn with mostly empty bodies. This plan refactors `Aiur.Opencode.SessionWriter` to group every codex event sharing a `turnId` into a single assistant message, translates the codex item types we currently drop (`reasoning`, `dynamicToolCall`, `fileChange`), captures bash stdout, and adds two aiur-specific surfaces inline in the chat: incoming cross-ticket event cards (always shown) and outgoing aiur tool calls like `emit_event` / `aiur_subscribe` (shown only under `--debug`). The ULID-monotonic fix on `aiur/22-events-foundation` already gave us correct part ordering — this plan is the bigger UX correction on top of that foundation.

---

## Problem Frame

The chat pane is the operator's primary surface for watching an agent work. Today it shows so many empty chrome rows that the operator can't follow the work — they see `▣ Build · issue-N · 4.4s` repeated 8+ times with no visible commands or output. The operator's mental model is native opencode (which renders commands, reasoning, file edits, and tool calls fully inline under one assistant message per turn). Aiur's synthesis path drifted from that shape because the original session writer focused on "get events into the DB" rather than "render the agent's turn coherently."

The work also needs to surface the *cross-ticket coordination layer* the events-foundation PR (issue #22) is building — when ticket 100 subscribes to ticket 99's progress, ticket 100's chat pane should be where the operator sees ticket 99's signals arrive, not a separate event ticker.

See origin: `docs/brainstorms/2026-05-25-aiur-chat-pane-native-parity-requirements.md`.

---

## Requirements Trace

- **R1.** One assistant message per codex turn, keyed by `turnId`. Parts append on item completion. `step-start` on first event, `step-finish` on turn termination.
- **R2.** Translate `reasoning`, `dynamicToolCall`, `fileChange` codex items (currently dropped). Keep `agentMessage` and `commandExecution` translation; preserve unchanged `userMessage` rendering.
- **R3.** Clean tool-part shape — `state.input.command` without `$ ` prefix, populated `state.output` from accumulated outputDelta, descriptive `state.title`, `state.input.workdir` from agent workspace.
- **R4.** Cross-ticket received events render inline in chat as standalone synthetic messages — always, independent of `--debug`.
- **R5.** Outgoing aiur tool calls (`emit_event`, `emit_alert`, `aiur_subscribe`, `aiur_declare_blocker`) render as tool parts inside the current turn's message — **only when `--debug` mode is active**.
- **R6.** Resolve the duplicate "Starting work on issue #N…" rendering with a SessionWriter dedup guard.

**Origin acceptance examples:** AE1 (R1) — one chrome header per turn; AE2 (R2) — file-edit tools render as distinct parts; AE3 (R3) — clean bash shape with real stdout; AE4 (R4) — incoming event card always visible; AE5 (R5) — outgoing aiur calls visible only under `--debug`; AE6 (R6) — opening message appears exactly once after re-attach.

---

## Scope Boundaries

- Real-time output **streaming** during a long command (state.output updates as deltas arrive) — deferred. We accumulate deltas in memory and write to `state.output` only on item completion.
- Workflow-phase milestone markers (brainstorm→plan→work→review separators) — deferred; the agent_list ticker + alert sounds already cover this.
- Reasoning-item visibility toggle — deferred; reasoning is always shown for now.
- Narrow-pane `???` / merged-rows wrap bug in the agent_list pane — out of scope (tracked separately as task #19; different code surface).
- Modifying opencode itself — out of scope. We only synthesize opencode-shaped rows.
- Replacing the existing event-debug ticker on agent_list — out of scope; the chat-pane cards are a complement, not a replacement.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/opencode/session_writer.ex` — the GenServer that writes synthetic opencode rows. Currently `write_event/2` writes one message + step-start/body/step-finish per event. Needs per-turn buffering.
- `elixir/lib/aiur/opencode/protocol.ex` — owns the JSON wire shapes (`assistant_message_data`, `text_part_data`, `tool_part_data`, `step_start_part_data`, `step_finish_part_data`). New helpers needed for reasoning parts and richer tool input.
- `elixir/lib/aiur/agent_runner.ex` — `codex_message_handler/5` is the funnel for codex notifications. `transcript_event_from/2` decides what becomes a transcript event. Needs new branches for `reasoning`, `dynamicToolCall`, `fileChange`, plus outputDelta accumulation.
- `elixir/lib/aiur/agent_events.ex` — defines `transcript_event/3` and the role atom set. Will need a richer payload (typed part data) to carry tool / reasoning / file-change details, not just `body`.
- `elixir/lib/aiur/agent_pubsub.ex` — broadcasts transcript events on a per-identifier topic. SessionWriter subscribes here. No changes expected.
- `elixir/lib/aiur/issue_log.ex` — captures the same stream to disk and an in-memory ring buffer. `history/2` and `disk_history/2` feed SessionWriter replay. Replay race candidate for R6.
- `elixir/lib/aiur/codex/dynamic_tool.ex` — defines `emit_event`, `emit_alert`, `aiur_subscribe`, `aiur_unsubscribe`, `aiur_declare_blocker` tool surface. Handlers fire `event_publisher.(name, message, payload)` and return `%{ok: true, ...}` results. R5 inserts a tool-part at this seam.
- `elixir/lib/aiur/events/subscription_store.ex` — per-identifier inbox of received cross-ticket events. R4 hooks into the delivery path.
- `elixir/lib/aiur/events/debug_log.ex` — Phoenix.PubSub topic `aiur:events:debug` already used by the agent_list ticker. Can be reused for the SessionWriter to be alerted of inbox deliveries without duplicating SubscriptionStore wiring.
- `elixir/lib/aiur/agent_list/app.ex:137-179` — example of how `debug_mode?` is plumbed through (`opts[:debug?]` with `AIUR_DEBUG` env fallback). Reuse the same pattern for SessionWriter.

### Institutional Learnings

- `docs/solutions/` doesn't carry chat-pane-specific learnings yet. The closest are the opencode-row-shapes notes (`elixir/docs/notes/opencode-row-shapes-1.15.6.md`) — that's the authoritative shape reference.
- The ULID-monotonic fix (commit `2c4a5db` on this branch) means part lexical ordering is now reliable. We can append parts within a turn and trust them to render in insertion order.
- Recent prior art for SessionWriter changes: `Stop SessionWriter replay races + Ctrl+C trap crash (#83)` — the `await_replay` cap, single `BEGIN IMMEDIATE → COMMIT` transaction during replay, and per-identifier `:via` registration are stable patterns to keep.

### External References

None — opencode's row shape doc is in-repo (`elixir/docs/notes/opencode-row-shapes-1.15.6.md`), and the codex notification surface is observed empirically in `logs/agent.ndjson` dumps captured during the brainstorm.

---

## Key Technical Decisions

- **Turn-state lifetime — keep on SessionWriter state, not a separate process.** SessionWriter is already per-identifier (`:via` registry); adding a `current_turn` field plus a small `turns_buffer` map (keyed by `turn_id`) avoids spinning up a second GenServer per chat. Trade-off: SessionWriter mailbox processes turn events serially, which is what we want anyway (events for a single turn are inherently sequential). Rationale: minimum-viable change, no new supervision tree, single owner of part-ordering within a chat.
- **Turn termination signal — `broadcast_turn_event` already plumbed.** `agent_runner.ex:90` already broadcasts `{:turn_completed, payload}` / `:turn_failed` / `:turn_cancelled` / `:turn_input_required` via `AgentPubSub.broadcast_turn_event`. SessionWriter subscribes to that topic via `AgentPubSub.subscribe_agent`-equivalent and writes a `step-finish` when the turn ends. No new event types required.
- **Out-of-turn events** (transcript events with `turn_id: nil`) — write a one-off message with its own step-start/step-finish, as today. R1.5 codified.
- **`fileChange` tool name → `"edit"`.** Native opencode renders `"read" | "write" | "edit"` with built-in TUI styling. `"edit"` is the closest match to codex's `fileChange` semantics (modified file with before/after). Open question 2 resolved.
- **Event-card visual marker — leading `📥` text part.** R4 cards are a single text part with format `📥 ticket.99.progress.tests-green\n<one-line payload summary>\nid=<event_id>`. Decision: avoid bespoke "received event" tool name in opencode (might fall through to generic rendering). Plain text with a stable marker is readable and trivially testable. Open question 3 resolved.
- **Mid-turn re-attach replay** — when `replay_history` rebuilds the SQLite for a re-attached chat, *finalize any open turns* with a synthetic `step-finish` (`reason: "stop"`). Open question 4 resolved. Rationale: a re-attached chat showing perpetually "in progress" turns from a previous attach is worse than a finalized record.
- **R6 dedup strategy — itemId when codex provides it; fallback (turn_id, role, body) hash.** SessionWriter keeps a small `seen_keys` ring (last 200 keys) and drops duplicates. Cheap. Doesn't require knowing the exact race source (replay-vs-live vs codex re-emission) — defends against all of them.
- **Debug-mode plumbing for SessionWriter** — pass `debug?` through `start_link/1` opts and through `Slot.materialize_slot/6` (the existing call site that spawns SessionWriter). Default to `AIUR_DEBUG` env. Same pattern as `Aiur.AgentList.App`.
- **Tests for new behavior live alongside existing `session_writer_test.exs` and `protocol_test.exs`.** Use `:meck` if needed for mocking codex events; otherwise direct GenServer calls with synthetic `transcript_event` shapes. Avoid new test scaffolds.

---

## Open Questions

### Resolved During Planning

- **OQ1 (origin): Turn-state lifetime.** Resolved — on SessionWriter state. See Key Technical Decisions above.
- **OQ2 (origin): fileChange tool name.** Resolved — `"edit"` (matches opencode's native edit tool, gets clean TUI styling).
- **OQ3 (origin): Event-card visual marker.** Resolved — single `text` part with leading `📥` + structured one-liner. Plain text, no custom tool name.
- **OQ4 (origin): Mid-turn re-attach replay.** Resolved — finalize open turns on replay with synthetic `step-finish reason: "stop"`.
- **R6 duplicate root cause.** Strongly suspected — `replay_history` reads `IssueLog.history` while a live event is in transit; SessionWriter subscribed first, so the live event also lands in the mailbox while replay is still running. Fix is dedup; identifying the exact race is nice-to-know but not required to ship.

### Deferred to Implementation

- **Exact dedup key encoding.** Pick `itemId` when codex provides one (most codex item types have one); fall back to `:erlang.phash2({turn_id, role, body})`. Final decision during implementation when we see the actual codex payload shapes.
- **`outputDelta` accumulation buffer eviction policy.** A long-running `mix test` could buffer megabytes. Cap at e.g. 256 KB per item, truncate with a `[...output truncated at N bytes...]` marker. Verify the actual size distribution during implementation; might be smaller in practice.
- **Replay write-amplification under U4 (dedup).** If dedup adds a per-event hash lookup inside the `BEGIN IMMEDIATE → COMMIT` replay transaction, profile to confirm the bounded ring keeps replay under the 10s await cap. Likely fine but worth measuring.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```mermaid
sequenceDiagram
    participant Codex as codex notification stream
    participant AR as agent_runner.codex_message_handler
    participant PubSub as AgentPubSub
    participant SW as SessionWriter (per identifier)
    participant DB as opencode SQLite

    Codex->>AR: item/started commandExecution (turn=T1)
    Note over AR: skipped (started events not translated)

    Codex->>AR: outputDelta (item=I1)
    Note over AR: accumulate in stdout_buffer[I1]

    Codex->>AR: item/completed commandExecution (turn=T1, item=I1)
    AR->>AR: build tool transcript_event with clean shape + output
    AR->>PubSub: broadcast_transcript(:command, payload, turn_id=T1)
    PubSub->>SW: {:transcript_event, e}
    SW->>SW: turn_buffer[T1] == nil → INSERT message + step-start
    SW->>DB: INSERT message + step-start
    SW->>DB: INSERT tool part (appended to T1's message)

    Codex->>AR: item/completed reasoning (turn=T1)
    AR->>PubSub: broadcast_transcript(:reasoning, text)
    PubSub->>SW: {:transcript_event, e}
    SW->>DB: INSERT reasoning part (appended to T1's message)

    Codex->>AR: turn/completed (turn=T1)
    AR->>PubSub: broadcast_turn_event(:turn_completed, %{turn_id: T1})
    PubSub->>SW: {:turn_completed, payload}
    SW->>DB: INSERT step-finish part (closes T1's message)
    SW->>SW: drop turn_buffer[T1]
```

The same `SessionWriter` also handles two side-channels:

```mermaid
sequenceDiagram
    participant Sub as SubscriptionStore
    participant SW as SessionWriter
    participant DB as opencode SQLite
    participant DT as DynamicTool handlers
    participant PubSub as AgentPubSub

    Sub->>PubSub: deliver event (R4)
    PubSub->>SW: {:received_event, %{topic, id, payload}}
    SW->>DB: INSERT standalone message + 📥 text part + step-finish

    DT->>PubSub: emit_event/emit_alert/aiur_subscribe call (R5, debug-only)
    Note over PubSub,SW: SW gates on debug_mode?
    PubSub->>SW: {:aiur_tool_call, %{name, args, result}}
    SW->>DB: INSERT tool part (appended to current open turn, or standalone)
```

---

## Implementation Units

- [ ] **U1. Per-turn message buffer in SessionWriter**

**Goal:** Refactor `Aiur.Opencode.SessionWriter` so all transcript events sharing a `turn_id` accumulate parts into one assistant message. First event of a turn writes the message + step-start; subsequent events append parts; the turn-end signal writes step-finish. Events with `turn_id: nil` keep today's one-message-each behavior.

**Requirements:** R1 (R1.1–R1.5).

**Dependencies:** None — baseline change.

**Files:**
- Modify: `elixir/lib/aiur/opencode/session_writer.ex`
- Modify: `elixir/lib/aiur/agent_pubsub.ex` (add turn-event subscription path if not already there)
- Test: `elixir/test/aiur/opencode/session_writer_test.exs`

**Approach:**
- Add `turns: %{}` to SessionWriter state, keyed by `turn_id`, value = `%{message_id, started_at_ms, part_count}`.
- On `{:transcript_event, %{turn_id: tid} = e}` with `tid != nil`:
  - If `turns[tid]` exists, append body part(s) to its `message_id` (no new message, no step-start, no step-finish yet).
  - If not, INSERT new message + step-start in one transaction, then append body part(s).
- On `{:turn_completed | :turn_failed | :turn_cancelled | :turn_input_required, %{turn_id: tid}}`: append step-finish with the appropriate reason and drop `turns[tid]`.
- On `{:transcript_event, %{turn_id: nil}}`: keep today's behavior — single message with step-start/body/step-finish.
- On replay: same logic, but finalize any open turn buffer at end of replay with a synthetic step-finish (`reason: "stop"`).
- Subscribe SessionWriter to the turn-event channel (already broadcast via `AgentPubSub.broadcast_turn_event/3` — needs a `subscribe_agent_turns/1` or fold into `subscribe_agent/1`).

**Patterns to follow:**
- `Aiur.Opencode.SessionWriter.write_event/3` — same `with` pipeline shape, just split into "write message + step-start" and "append part" variants.
- `Aiur.Opencode.Db.with_transaction/1` — batch the new message + step-start in one transaction.
- ULID monotonicity guarantee (commit `2c4a5db`) — append-order is preserved by lexical id sort.

**Test scenarios:**
- *Happy path:* Three transcript events with the same `turn_id`, then a `turn_completed`. Covers AE1. Result: 1 message row, parts = step-start, body, body, body, step-finish. Ordered lexically.
- *Happy path:* Two transcript events with different `turn_id`s interleaved. Result: 2 messages, each with its own step-start/body/step-finish.
- *Edge case:* `turn_id: nil` event after a turn-grouped sequence. Result: standalone message with step-start/body/step-finish; the open turn buffer is untouched.
- *Edge case:* `turn_completed` for a `turn_id` that was never seen. Result: no crash; log warning at debug level; no DB write.
- *Edge case:* `turn_completed` arrives twice for the same turn. Result: step-finish written only once; second event no-ops.
- *Edge case:* `turn_failed` instead of `turn_completed`. Result: step-finish reason is `"error"` (or matching reason — finalize during implementation).
- *Integration:* `replay_history` with two open turns at history end. Result: both turns get synthetic step-finish; new live events after replay are treated as new turns.

**Verification:** Live aiur run shows ONE `▣ Build · issue-N · timing` header per agent turn in the chat pane, not many.

---

- [ ] **U2. Translate reasoning, dynamicToolCall, fileChange codex items**

**Goal:** Extend `Aiur.AgentRunner.codex_message_handler/5` so codex items currently dropped (reasoning, dynamicToolCall, fileChange) become transcript events with appropriate shape — and SessionWriter knows how to render each.

**Requirements:** R2 (R2.1–R2.4).

**Dependencies:** U1 (uses the new "append part" path).

**Files:**
- Modify: `elixir/lib/aiur/agent_runner.ex`
- Modify: `elixir/lib/aiur/agent_events.ex` (add `:reasoning` to role atom set, or use a richer payload shape — finalize during implementation)
- Modify: `elixir/lib/aiur/opencode/protocol.ex` (add `reasoning_part_data/2` helper)
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (route new transcript event shapes to part inserts)
- Test: `elixir/test/aiur/opencode/session_writer_test.exs` (new shape rendering)
- Test: `elixir/test/aiur/opencode/protocol_test.exs` (new helpers)

**Approach:**
- New `transcript_event_from/2` branches in `agent_runner.ex` for:
  - `item/completed reasoning` → role `:reasoning`, body = text.
  - `item/completed dynamicToolCall` → role `:tool`, payload includes `tool` (name), `input`, `output`, `title`.
  - `item/completed fileChange` → role `:tool`, payload encodes the file path + change summary; `tool: "edit"`.
- Extend `AgentEvents.transcript_event/3` to accept a `:payload` opt for tool/reasoning details so the body field stays a string and richer data rides in payload.
- `SessionWriter.insert_body_parts/5` (or its successor): pattern-match on role → emit appropriate part shape.
- `Protocol.reasoning_part_data/2`: returns `%{"type" => "reasoning", "text" => text, "time" => %{...}}` per the row-shape doc.

**Patterns to follow:**
- `Aiur.AgentRunner.assistant_message_from_codex/1` and `system_activity_from_codex/1` — same with/case shape for the new item types.
- `Aiur.Opencode.Protocol.tool_part_data/1` — copy the keyword-opts pattern for new tool variants.

**Test scenarios:**
- *Happy path:* codex `item/completed reasoning` notification → `:reasoning` transcript event with the reasoning text.
- *Happy path:* codex `item/completed dynamicToolCall` with tool name `"github_create_issue"` → `:tool` transcript event with that tool name and the item's input/output.
- *Happy path:* codex `item/completed fileChange` with a path + diff summary → `:tool` event with `tool: "edit"`.
- *Edge case:* `item/started` (any of the above types) → still `:skip`, no transcript event.
- *Edge case:* reasoning text empty / missing → `:skip` (no part).
- *Integration (with U1):* a turn that contains agentMessage + reasoning + commandExecution + fileChange → one message with text + reasoning + tool + tool parts inside, plus surrounding step-start/step-finish. Covers AE2.

**Verification:** Chat pane for a real agent turn shows reasoning blocks, file-edit blocks, and MCP tool blocks alongside text and bash commands — not just text + bash.

---

- [ ] **U3. Clean bash tool-part shape + outputDelta capture**

**Goal:** Bash tool parts match the native opencode shape from `elixir/docs/notes/opencode-row-shapes-1.15.6.md` — clean `state.input.command` (no literal `$ ` prefix), populated `state.output` from accumulated codex `commandExecution/outputDelta` deltas, `state.title` from the codex-supplied description (or first 60 chars of command), `state.input.workdir` from the agent's workspace.

**Requirements:** R3 (R3.1–R3.3), AE3.

**Dependencies:** U1.

**Files:**
- Modify: `elixir/lib/aiur/agent_runner.ex` (outputDelta accumulator keyed by `itemId`; pass workspace path to event payload)
- Modify: `elixir/lib/aiur/opencode/protocol.ex` (`tool_part_data/1` accepts new opts; or `bash_tool_part_data/1` helper)
- Test: `elixir/test/aiur/opencode/protocol_test.exs`
- Test: `elixir/test/aiur/opencode/session_writer_test.exs` (shape assertion against synthesized rows)

**Approach:**
- In `codex_message_handler/5`, maintain a `%{item_id => iodata}` map (in the closure or via Process dict) accumulating `item/commandExecution/outputDelta` payloads.
- On `item/completed commandExecution`, build the tool transcript event with the assembled output (truncated per cap), the agent's workspace cwd, the codex-supplied description as title, and the raw command (no `$ ` prefix).
- Cap accumulated output at 256 KB per item (decision in Open Questions); replace excess with `\n[...truncated]\n`.
- Drop the `item_id` from the accumulator after emission.

**Patterns to follow:**
- Native opencode bash row in `elixir/docs/notes/opencode-row-shapes-1.15.6.md` — copy field shapes.

**Test scenarios:**
- *Happy path:* `item/completed commandExecution` with `command: "git status --short"`, `description: "Shows current git status"`, captured output `"?? test-sandbox/\n"`. Covers AE3. Result: `state.input.command == "git status --short"` (no `$ ` prefix), `state.input.description == "Shows current git status"`, `state.input.workdir` is the agent workspace path, `state.output == "?? test-sandbox/\n"`, `state.title == "Shows current git status"`.
- *Edge case:* command with no description. Result: `state.title` is the first 60 chars of the command.
- *Edge case:* very long output (> 256 KB). Result: truncated with marker; original `state.output` size in the configured cap range.
- *Edge case:* `commandExecution` with no preceding outputDelta events (instant command). Result: `state.output == ""` (acceptable; not a crash).
- *Integration:* full turn with one command — operator opens the chat pane and reads the command + output as a single block.

**Verification:** Synthesized bash tool part matches the field-by-field shape in the row-shape doc for any sample command.

---

- [ ] **U4. SessionWriter dedup guard for duplicate transcript events**

**Goal:** Resolve the duplicate "Starting work on issue #N…" rendering. SessionWriter rejects a second insert that matches the same dedup key (`itemId` if codex provides; otherwise hash of `{turn_id, role, body}`).

**Requirements:** R6, AE6.

**Dependencies:** None structurally; U1 makes the implementation cleaner since `write_event` is already being touched.

**Files:**
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (add `seen_keys` bounded ring to state, gate insert on dedup)
- Test: `elixir/test/aiur/opencode/session_writer_test.exs`

**Approach:**
- State adds `seen_keys :: :queue.queue(any())` with cap of last 200 keys.
- Compute key from event: prefer `event[:item_id]` (added in U2 payload), fall back to `:erlang.phash2({event.turn_id, event.role, event.body})`.
- Before insert: if key in queue → log debug and `{:noreply, state}`. Otherwise enqueue (with cap eviction) and proceed.

**Patterns to follow:**
- `:queue.in/2` + `:queue.out/1` for a bounded FIFO.

**Test scenarios:**
- *Happy path:* Same transcript event delivered twice → only one DB row written; second is a no-op.
- *Happy path:* Two distinct events with same body but different `turn_id` → both written (key includes turn_id).
- *Edge case:* `seen_keys` exceeds cap. Result: oldest key evicted; very-old replay of the same event would write again (acceptable — caps prevent unbounded memory).
- *Integration (with replay):* simulate replay race — same event in IssueLog.history AND in PubSub mailbox during boot. Result: written exactly once. Covers AE6.

**Verification:** Run aiur, attach to an agent, detach, re-attach. The opening "Starting work on…" message appears exactly once.

---

- [ ] **U5. Inline cross-ticket received-event cards**

**Goal:** When the SubscriptionStore delivers a cross-ticket event to an agent's inbox, SessionWriter writes a standalone synthetic assistant message with a leading `📥` text part — always, independent of `--debug`.

**Requirements:** R4 (R4.1–R4.4), AE4.

**Dependencies:** U1 (cleaner integration with the message-write API).

**Files:**
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (new `handle_info/2` for `{:received_event, payload}`)
- Modify: `elixir/lib/aiur/events/subscription_store.ex` (broadcast delivery via `AgentPubSub` so SessionWriter sees it)
- Modify: `elixir/lib/aiur/agent_pubsub.ex` (new helper `broadcast_received_event/2` if not already present)
- Test: `elixir/test/aiur/opencode/session_writer_test.exs`
- Test: `elixir/test/aiur/events/subscription_store_test.exs` (broadcast happens on delivery)

**Approach:**
- SubscriptionStore, at the seam where it delivers an event to an agent's "ready to read" queue, also broadcasts `{:received_event, %{topic, id, payload, source_ticket}}` via `AgentPubSub`.
- SessionWriter subscribes to that channel via `subscribe_agent/1` (fold into the existing subscription).
- On `{:received_event, e}`: insert a standalone message (per the standalone-message path) with `text_part_data("📥 #{e.topic}\n#{summarize_payload(e.payload)}\nid=#{e.id}")`.
- Mark these messages with a stable signature so replay never re-emits them (e.g., synthetic `parentID` from `event_id` so duplicate inserts collide on PRIMARY KEY — or use the dedup guard from U4).

**Patterns to follow:**
- `Aiur.AgentPubSub.broadcast_transcript/2` — same broadcast shape, distinct message tag.
- R4.4 (origin) — write once on delivery, never re-emit on replay.

**Test scenarios:**
- *Happy path:* SubscriptionStore receives an event matching a pattern → broadcasts `{:received_event, ...}` → SessionWriter writes a message with text part containing `📥 <topic>` and the payload summary. Covers AE4.
- *Edge case:* SessionWriter receives the same `{:received_event, ...}` twice → only one DB row (covered by U4 dedup, with key including `event_id`).
- *Edge case:* `--debug` off → event card still written (R4.3).
- *Integration:* Ticket 100's agent has `aiur_declare_blocker(99)`. Ticket 99 emits `progress.tests-green`. Ticket 100's chat pane shows the card.

**Verification:** Manual: dispatch two test tickets with a subscription between them; trigger an emit on the subscribed-to ticket; confirm a card appears in the subscriber's chat pane.

---

- [ ] **U6. Outgoing aiur tool-call rendering (--debug only)**

**Goal:** Calls to `emit_event`, `emit_alert`, `aiur_subscribe`, `aiur_unsubscribe`, `aiur_declare_blocker`, `aiur_unblock` render as tool parts inside the current turn's message — only when `--debug` is active.

**Requirements:** R5 (R5.1–R5.3), AE5.

**Dependencies:** U1 (uses append-to-current-turn API), U2 (uses tool transcript-event shape), U3 (clean tool shape).

**Files:**
- Modify: `elixir/lib/aiur/codex/dynamic_tool.ex` (broadcast a transcript event after each tool handler succeeds)
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (gate on `debug_mode?`)
- Modify: SessionWriter `start_link` / supervisor wiring to receive `debug?` opt
- Test: `elixir/test/aiur/codex/dynamic_tool_test.exs` (broadcast happens; gating works)

**Approach:**
- After each tool handler builds its `result` map, call `AgentPubSub.broadcast_transcript(identifier, AgentEvents.transcript_event(:aiur_tool, "...", turn_id: turn_id, payload: %{tool: name, input: args, output: result}))`.
- SessionWriter: on `:aiur_tool` transcript events, gate on `state.debug_mode?` — if true, render as a `tool` part appended to the current turn's message (or as a standalone message when no open turn).
- Add `debug?` to SessionWriter `start_link` opts, default to `Aiur.Config` / `AIUR_DEBUG` env.
- Pass `debug?` through wherever Slot spawns SessionWriter (`elixir/lib/aiur/opencode/slot.ex` — verify call site during implementation).

**Patterns to follow:**
- `Aiur.AgentList.App` — same `debug_mode?` pattern (state field + env fallback).
- Existing tool shape from U3.

**Test scenarios:**
- *Happy path:* `emit_event` tool handler invoked, `debug_mode?: true`. Result: SessionWriter writes a tool part with `tool: "emit_event"`, input = call args, output = result map. Covers AE5.
- *Happy path:* same call with `debug_mode?: false`. Result: no SessionWriter write (DB part count for the turn unchanged).
- *Edge case:* aiur tool call arrives outside any open turn (e.g., during boot). Result: standalone message with single tool part.
- *Edge case:* tool handler returns error. Result: tool part with `state.status: "error"` (matches opencode), output = error map.
- *Integration:* full turn with `emit_event` + bash + assistant text, `--debug` on. Pane shows the `emit_event` block inline between the others.

**Verification:** Run aiur in `--debug` and without `--debug`. With `--debug`, the chat pane shows aiur tool blocks. Without, it doesn't, but the events still fire (verify via the existing debug ticker on agent_list).

---

## System-Wide Impact

- **Interaction graph:** `agent_runner.ex` (codex notification funnel) → `AgentPubSub.broadcast_transcript` → `SessionWriter` (writes to opencode DB), `IssueLog` (writes to disk + ring buffer). Adds: `SubscriptionStore` (delivery seam) → `AgentPubSub.broadcast_received_event` → `SessionWriter`. Adds: `DynamicTool` (after tool handler) → `AgentPubSub.broadcast_transcript(:aiur_tool, ...)` → `SessionWriter` (debug-gated).
- **Error propagation:** SessionWriter insert failures already log + continue (`Logger.warning("opencode_session_writer write_failed ...")`). New part-insert calls keep the same posture — log + continue, never crash the writer.
- **State lifecycle risks:**
  - *Open turns at writer crash:* SessionWriter GenServer crash drops `turns` map; no rows orphaned because step-start was already written. Re-attach replay reconstructs (and finalizes open turns per OQ4).
  - *outputDelta accumulator leak:* if a `commandExecution` never gets an `item/completed` event (codex crash mid-command), the accumulator entry stays. Mitigation: clear accumulator on turn termination (since turn_completed implies any in-flight commands are abandoned).
  - *Replay double-write under U4:* dedup key in `seen_keys` ring; replay re-populates the ring as it writes, so any cached PubSub event arriving during replay collides on the key.
- **API surface parity:** `AgentEvents.transcript_event/3` gains a `:payload` opt — internal API only; no external consumers.
- **Integration coverage:** SessionWriter ↔ AgentPubSub ↔ DynamicTool path has no direct unit-test coverage today; add integration tests in `session_writer_test.exs` that exercise the full broadcast→write flow with fake codex notifications.
- **Unchanged invariants:** `Aiur.Opencode.Db` schema, `Aiur.Opencode.Protocol.assistant_message_data/1` field set (still mode/agent="build", same modelID format), `Aiur.IssueLog` disk format. ULID monotonicity (commit `2c4a5db`) is unchanged. Slot lifecycle is unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Turn-buffer state leaks if `turn_completed` never fires | Implement a timeout sweep in SessionWriter (e.g., turns older than 10 minutes get auto-finalized + dropped) — implementable during U1 if observed during manual verification, otherwise punt. |
| Mid-turn re-attach replay (OQ4 resolution) misorders parts | Synthetic step-finish is appended *after* the last real part for that turn; ULID monotonicity guarantees ordering since the synthetic finish is generated with the highest timestamp at replay time. |
| outputDelta accumulator grows unbounded on a runaway agent | 256 KB cap per item with truncation marker. |
| Dedup ring misses duplicates older than 200 events | Acceptable — the duplicate-render bug only shows up within seconds of boot; 200 events well exceeds that window. |
| `debug?` opt not threaded through every Slot spawn path | U6 includes Slot wiring as a file modification; manual verification step explicitly toggles `--debug` on/off to confirm. |
| `:meck` or test-mock setup grows complex | Prefer GenServer-direct `send(pid, msg)` tests over mocking codex; SessionWriter accepts synthetic transcript events natively. |

---

## Documentation / Operational Notes

- `elixir/AGENTS.md` and the in-repo `elixir/docs/notes/opencode-row-shapes-1.15.6.md` already document the SessionWriter / row-shape contract. Update the row-shapes note if any new part shape diverges from native opencode (reasoning + tool parts should match exactly).
- No new env vars, config flags, or Slack channels.
- No rollout/migration — change is invisible to operators except that the chat panes start rendering correctly. Existing rows in `~/.local/share/opencode/opencode.db` remain in their old shape; only new turns benefit. No backfill needed.
- PR body follows the template; include a Complexity routing block citing `complexity:4` rationale (cross-cutting SessionWriter + DynamicTool + SubscriptionStore touches).

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-25-aiur-chat-pane-native-parity-requirements.md`
- **Row-shape contract:** `elixir/docs/notes/opencode-row-shapes-1.15.6.md`
- **Foundation commit:** `2c4a5db` (Fix chat-pane empty-body bug via monotonic ULIDs) on this branch — gates correct lexical part ordering.
- **Events foundation:** `elixir/lib/aiur/events/{publisher,subscription_store,exchange,topic}.ex`, `elixir/lib/aiur/codex/dynamic_tool.ex` — surfaces R4 and R5 depend on.
- **Related issue:** #22 (events-foundation PR — this work lives on top of it).
