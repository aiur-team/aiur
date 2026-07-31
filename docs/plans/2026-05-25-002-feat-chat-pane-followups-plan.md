---
title: "feat: Aiur chat pane follow-ups — QUEUED fix, event rows, --test/--force, dimmed styling, clean exit"
type: feat
status: active
date: 2026-05-25
deepened: 2026-05-25
origin: docs/brainstorms/2026-05-25-aiur-chat-pane-followups-requirements.md
---

# feat: Aiur chat pane follow-ups

## Overview

Five follow-up improvements after manual verification of PR #98.

- **R1.** Operator messages typed in the chat input clear `QUEUED` within seconds (not the bridge's 10-min watchdog) by closing the operator-message SSE on `AgentChat.send` accept.
- **R2.** Cross-ticket events render inline in the agent's chat pane — arrival `📥`, outgoing publish `📤`, read/ingested `📄` — sourced from the **existing `Aiur.Events.DebugLog`** lifecycle marks, delivered via a new bridge inline-injection path for live render plus a new SessionWriter `system`-role row for SQL persistence on re-attach.
- **R3.** `aiur --test` implicitly composes `--force` so stale `_build/` artifacts never silently mask shipped work.
- **R4.** Tool, command, and reasoning content render dimmed; agent prose stays at default weight so it scans first.
- **R5.** Foregrounded aiur (`q`, Ctrl+C, terminal close, SSH HUP, tmux kill) cleanly reaps every aiur-owned process. `aiur stop` is the `aiur --bg`-only command.

Strict non-regression: every unit preserves the PR #98 behaviors verified in manual testing (one-message-per-turn chrome, lifecycle on `aiur_turn_done`, ActiveTurns phantom guard, Server.terminate child reaping, SessionWriter rich-part writes for codex transcript events, events foundation publish/subscribe, `--test` reset machinery, manual-override).

**Plan v2 note.** This is a substantive revision after `ce-doc-review` surfaced multiple architectural assumptions in v1 that didn't match the code: `seen_keys` ring didn't exist, PATCH had been removed, `write_standalone` hardcodes `role: "assistant"`, `DebugLog` already covered two of three broadcast seams, `DynamicTool` had no agent identifier. v2 builds on what's actually there.

---

## Problem Frame

The events foundation + chat-pane parity work landed on PR #98 and was manually verified after `aiur --test --force` — real build details, prose, commands, and tool calls now render in chat panes. Five issues remain visible during real use:

1. The bridge's `stream_turn` (`elixir/lib/aiur/opencode/chat_completions.ex:239`) calls `AgentChat.send` and then waits on `stream_loop/4` for transcript events pinned to a *bridge-local* random `turn_id`. Codex never emits events with bridge-local turn_ids, so the pin never matches; opencode shows `QUEUED` until the 10-min watchdog. Operator confidence drops.
2. Cross-ticket events flow through `Aiur.Events.DebugLog` (publish/receive/read marks on `aiur:events:debug` topic) and render in the agent_list sidebar ticker. **`DebugLog` is the right broadcast source.** Chat panes are silent because nothing subscribes `DebugLog` → renders into chat. The plan wires both a live-render subscriber (the bridge) and a persistence subscriber (SessionWriter).
3. `aiur --test` without `--force` reuses prior `_build/`. The script parses `test_force` but the two flags aren't bound.
4. Commands and tool calls render with the same visual weight as agent prose.
5. After manual testing, leftover BEAM / opencode-serve / opencode-attach processes accumulate. Foregrounded exit should self-clean.

See origin: `docs/brainstorms/2026-05-25-aiur-chat-pane-followups-requirements.md`.

---

## Requirements Trace

- **R1.** Operator messages clear `QUEUED` within seconds: idle → delivered ~immediately, mid-tool-call → delivered after current tool returns. No `turn_id` pin codex won't satisfy.
- **R2.** Cross-ticket events render inline in the agent's chat pane: arrival `📥`, outgoing `📤`, read `📄`, all always-on (no `--debug` gate), all dedup-safe across re-delivery.
- **R3.** `aiur --test` implies `--force` with no extra flag needed.
- **R4.** Tool, command, and reasoning content render visibly subdued vs agent prose; event rows (R2) share the subdued treatment.
- **R5.** Foregrounded aiur cleanly stops everything on exit (all aiur-owned processes terminate on `q`, Ctrl+C, terminal close, HUP, tmux kill-session). `aiur stop` is documented as `--bg`-only.

**Origin acceptance examples:** AE1 (R1) — operator `hi` clears QUEUED within 1–2 s of current tool call returning; AE2 (R2.1–R2.3) — `📥` for incoming, `📤` for outgoing; AE3 (R2.4) — `📄` at digest-render time, visible arrival↔ingest gap; AE4 (R3) — `aiur --test` and `aiur --test --force` produce identical state; AE5 (R4) — agent prose visually obvious vs subdued tool/command/reasoning; AE6 (R5) — `pgrep` for aiur processes returns empty after every exit path.

**Non-regression carryover (from origin):** every unit preserves PR #98's verified behaviors. Each unit's verification re-runs the parity-plan acceptance examples AE1–AE6 from `docs/plans/2026-05-25-001-feat-chat-pane-native-parity-plan.md` in addition to the new AEs above.

---

## Scope Boundaries

- No new mid-tool-call interrupt machinery — R1 only fixes the indicator; AgentChat's existing `:interrupt` / `:queue_next` semantics are unchanged.
- No payload-rich event-card UI — event rows stay one line; deeper inspection lives in the per-issue log + dashboard.
- No per-event-type styling vocabulary — `📥/📤/📄` are uniform regardless of event surface.
- No operator-driven event filtering in chat ("mute X").
- No configurable color theme — R4 picks "noticeably subdued"; not a setting.
- We are not modifying opencode-attach. R4 styling uses whatever rendering vocabulary opencode-attach already honors (ANSI escapes, markdown). Fallback if neither works: a leading marker character + plain text.
- We are not building a new dedup ring — R2 uses DebugLog as a single broadcast source (no replay loop) plus a small in-memory `seen_event_ids` set on SessionWriter scoped to handle SubscriptionStore's at-least-once re-delivery only.
- We are not bringing back `PATCH /part`. Empirically, direct SQL writes and PATCH both fail to refresh opencode TUI mid-session. Live rendering uses bridge SSE inline injection only.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/events/debug_log.ex` — **already exists** and broadcasts three lifecycle marks (`:publish` / `:receive` / `:read`) on `aiur:events:debug` topic via `Phoenix.PubSub.local_broadcast`. The producer side is already wired:
  - `:publish` fires from `Aiur.Events.Publisher.publish/3` at `elixir/lib/aiur/events/publisher.ex:91`.
  - `:receive` fires from `Aiur.Events.SubscriptionStore.handle_info({:event, _})` at `elixir/lib/aiur/events/subscription_store.ex:289`.
  - `:read` fires from `Aiur.AgentRunner`'s digest renderer at `elixir/lib/aiur/agent_runner.ex:556` (the `queue_item_text/1` happy-path clause, lines 544–560 region).
- `elixir/lib/aiur/agent_runner.ex` — has **two** `queue_item_text` digest-render clauses. The first (~line 544) already calls `DebugLog.broadcast(:read, ...)`. The second (~line 562, fallback for missing `target_issue_identifier`) **does not**. R2.4 (U4) extends the second clause to also broadcast.
- `elixir/lib/aiur/opencode/chat_completions.ex` — bridge SSE handler. Three SSE paths today:
  - `stream_codex_turn/3` (line ~89): the per-turn marker SSE that streams transcript events as deltas. **This is the live render path for chat panes.** R2 live render hooks here.
  - `stream_turn/3` (line 239): the operator-message SSE that pins on a bridge-local `turn_id`. **R1/U2 simplifies this.**
  - `stream_loop/4` (line 287) and `collect_turn/4`: helpers for `stream_turn`. Removed/repurposed in U2.
  - `format_delta/2` (line 198 region) is the role → delta-string formatter. R4 (U5) wraps the body here.
- `elixir/lib/aiur/opencode/session_writer.ex` — per-identifier GenServer. Has **no `seen_keys` ring today**; v2 adds a minimal `seen_event_ids` MapSet scoped to `:receive`/`:publish`/`:read` rows only. `write_standalone/2` writes messages via `build_message_data(state, role) → Protocol.assistant_message_data(...)` which hardcodes `role: "assistant"`. **v2 adds `Protocol.system_message_data/1`** and a `write_system_standalone/2` helper to emit `role: "system"` rows without `▣ Build` chrome.
- `elixir/lib/aiur/opencode/protocol.ex` — `assistant_message_data/1` at line 253. v2 adds `system_message_data/1` mirroring the shape but with `role: "system"`, no `mode`, no `agent`.
- `elixir/lib/aiur/codex/dynamic_tool.ex` — does NOT have an agent identifier in scope; receives opaque handler closures via `opts`. v2 does **not** add broadcasts here. Outgoing `:emitted_event` for `emit_event`/`emit_alert` is already covered by `Publisher.publish/3 → DebugLog.broadcast(:publish, ...)`. `aiur_subscribe`/`aiur_declare_blocker`/etc don't generate event IDs and are not in scope for R2 ticker rows.
- `elixir/lib/aiur/agent_pubsub.ex` — single-source-of-truth broadcasts on agent topics. v2 does **not** add new helpers; the bridge and SessionWriter subscribe to `DebugLog`'s shared topic directly.
- `elixir/lib/aiur/agent_chat.ex:11` — `send/3` returns `{:ok, request_id}` synchronously when the message is accepted into the queue. R1/U2 closes the bridge SSE on this return.
- `scripts/aiur` lines 36–79 — `test_mode` and `test_force` parsing. R3 (U1) binds them.
- `scripts/aiur` lines ~1196–1221 — `__aiur_cleanup` EXIT/INT/TERM/HUP trap from commit `7f3089a`. R5 (U6) verifies coverage across all foreground-exit paths.

### Institutional Learnings

- **PATCH does not trigger live TUI render in opencode 1.15.x.** Empirically verified during the chat-pane parity work; PATCH was removed from SessionWriter. Direct SQL writes also do not trigger render. **Only the bridge SSE (chat-completion path) does.** This forces R2 live rendering to use inline injection into an active bridge stream, with SessionWriter writes providing only the re-attach view.
- The ULID-monotonic fix (commit `2c4a5db`) means parts within a message render in insertion order.
- `DebugLog.broadcast` is best-effort, no-op on no-PubSub, and uses `Phoenix.PubSub.local_broadcast` — already correctly guarded.

### External References

- No external research. opencode-attach (bubbletea/lipgloss) ANSI rendering verified empirically via running opencode in a real terminal — not just `tmux capture-pane`, which can produce false positives because tmux honors ANSI sequences at the cell-grid layer regardless of whether the upstream renderer (bubbletea) emitted them as intended. U5's probe explicitly verifies in a live opencode-attach pane.

---

## Key Technical Decisions

- **R2 broadcast source — reuse `Aiur.Events.DebugLog`.** It already broadcasts `:publish` (from Publisher), `:receive` (from SubscriptionStore), `:read` (from agent_runner's digest renderer) on `aiur:events:debug`. The plan adds two NEW SUBSCRIBERS to that topic — the bridge (for live render) and SessionWriter (for SQL persistence) — instead of creating parallel `AgentPubSub.broadcast_*_event` helpers. Single source of truth, no payload-shape drift.

- **R2 live render — bridge inline injection during `stream_codex_turn`.** When the bridge opens an SSE stream for a codex turn, it subscribes to `DebugLog.topic()` for the duration of that stream. Each DebugLog entry whose `identifier` matches the bridge's `identifier` triggers a delta chunk in the format `\n<formatted event row>\n` injected into the active assistant message. The row appears inline in the agent's currently-streaming response, visually separated by newlines and dimmed styling (R4). On `aiur_turn_done`, the bridge unsubscribes and closes as today. **Trade-off:** events arriving OUTSIDE an active codex turn don't render live — they appear on the next turn's stream OR via SessionWriter's persisted row on re-attach. Acceptable for v1; documented in the brainstorm's deferred-for-later (we keep R2 simple in the chat pane, the agent_list ticker is still the always-on operator surface).

- **R2 persistence — SessionWriter writes `system`-role standalone rows.** SessionWriter subscribes to `DebugLog.topic()` (no per-identifier filter — receives all marks, filters in handler by `identifier == state.identifier`). For each matching mark it writes one row via a new `write_system_standalone/2` helper that uses a new `Protocol.system_message_data/1` returning `role: "system"`. Re-attach renders these rows from SQL with whatever non-assistant styling opencode-attach gives `role: "system"` messages. No `▣ Build · issue-N` chrome.

- **R2 dedup — minimal `seen_event_ids` MapSet on SessionWriter for `:receive`/`:read` re-delivery.** SubscriptionStore's at-least-once delivery may re-broadcast `:receive` for the same event_id after restart; the agent's queue may re-deliver `events_digest` and trigger `:read` twice for the same event_id. SessionWriter keeps a per-mark `seen` MapSet keyed by `event_id`, capped at the 500 history-pull size (recent-only; old IDs evict). The bridge does NOT need dedup — its lifetime is one codex turn; no replay loop.

- **R1 mechanism — drop the turn_id pin, close SSE immediately after `send_operator` returns `{:ok, _}`.** Origin OQ1's option (a). The agent's reply streams back through the existing per-turn marker bridge (`stream_codex_turn`). The trade-off — losing the bridge's post-delivery error surface (turn_failed / turn_input_required / watchdog late signals) — is accepted: AgentChat returns `{:ok, _}` on accept, the per-turn bridge has its own watchdog for the response. Documented in the verification step.

- **R3 no escape hatch.** OQ4 resolved: simpler wins; if a fast-reset case appears later, add `--no-force`.

- **R4 dimming mechanism — ANSI dim (`\e[2m…\e[22m`) primary, leading `▸ ` Unicode marker fallback. Probe in a real opencode-attach pane (not just `tmux capture-pane`) before merging.** A small helper module `Aiur.Opencode.Style` exposes `dim/1` — wraps in ANSI by default, falls back to `▸ ` prefix if the empirical probe shows ANSI not honored by bubbletea's renderer. Centralized so changing the mechanism touches one site. Used by both `format_delta/2` (live SSE) and SessionWriter event-row writers (persistence).

- **Event-row format reused from the parity plan U5/U6:**
  - Incoming: `📥 <topic> · from #<source_ticket> · id=<event_id>` (or `from #?` if source missing, `id=?` if event_id missing).
  - Outgoing: `📤 <topic> · id=<event_id>` (from Publisher's `:publish` mark, which gives topic + id).
  - Read: `📄 <topic> · ingested · id=<event_id>` (with `ingested` framing chosen over `ingested at turn start` because `:read` fires when the digest is *folded into the prompt*, not after the agent has confirmed reading — see U4 semantic note).

- **Codex stream loop receive clauses — add explicit clauses for DebugLog messages.** When the bridge subscribes to `DebugLog.topic()` during a codex turn, its `codex_turn_stream_loop` mailbox starts receiving `{:event_debug, entry}` messages. v2 adds an explicit clause that chunks the formatted row and continues the loop. The existing `_other` clause silently drops, so without an explicit clause the new live-render path silently no-ops.

- **DynamicTool broadcasts are out of scope for R2.** `:publish` from `Publisher.publish/3` already covers `emit_event`/`emit_alert` (which are the only DynamicTool handlers producing event IDs). `aiur_subscribe` / `aiur_unsubscribe` / `aiur_declare_blocker` / `aiur_unblock` are coordination bookkeeping ops with no event_id — they do not produce `📤` rows. Operator sees these via the per-issue log + dashboard, not the chat pane.

---

## Open Questions

### Resolved During Planning

- **OQ1 (origin) — R1 mechanism.** Drop the turn_id pin (option a). Trade-off documented.
- **OQ2 (origin) — R2 read-indicator emit point.** Reuse the existing `DebugLog.broadcast(:read, ...)` at `agent_runner.ex:556` (the digest-render seam in `queue_item_text`). Add the missing broadcast in the second clause (~line 562) so both digest-render paths emit consistently.
- **OQ3 (origin) — R4 dimming mechanism.** ANSI dim primary, `▸ ` Unicode marker fallback. Verified during U5 in a real opencode-attach pane.
- **OQ4 (origin) — R3 escape hatch.** None.

### Deferred to Implementation

- Exact size of the `seen_event_ids` MapSet cap. Start with 500 (matches history-pull); tune if observed evictions occur on long-running agents.
- Exact line of the second `queue_item_text` clause in `agent_runner.ex`. Read the file at implementation time; the brainstorm cited "around line 562" but the file may have shifted.
- The Unicode marker character if ANSI fails — `▸ ` (light-grey right-pointing) is the working choice. Substitute if it doesn't render correctly in opencode-attach.

---

## Implementation Units

- [ ] **U1. `aiur --test` implies `--force`**

**Goal:** Operator running `aiur --test` gets full sandbox reset + fresh `_build/` automatically.

**Requirements:** R3 (R3.1, R3.3). AE4.

**Dependencies:** None. Smallest, ships first.

**Files:**
- Modify: `scripts/aiur` (lines 36–79 argument-parsing block).

**Approach:**
- In the `--test` parsing branch (around line 70), also set `test_force=1` unconditionally.
- Add one inline comment explaining the implicit composition.
- No `--no-force` flag (OQ4 resolved).

**Patterns to follow:** existing `test_mode` / `test_force` parsing conventions.

**Test scenarios:**
- *Manual happy path (AE4):* `aiur --test` produces identical first-boot behavior to `aiur --test --force` (rebuilds release, resets pinned tickets).
- *Manual edge case:* `aiur --test --force` still works identically.
- *Manual edge case:* `aiur --force` standalone (without `--test`) unaffected.

**Verification:** Run `aiur --test`; observe `_build/dev/rel/aiur/bin/aiur` mtime updates and the "rebuilding release" output.

**Non-regression touched:** `--test` reset machinery (pinned tickets, workspace rm, label reset). Preserved by leaving the reset path untouched.

---

- [ ] **U2. Bridge SSE for operator messages closes on delivery**

**Goal:** `dispatch_user_text` → `stream_turn` closes the SSE with `finish_reason: "stop"` as soon as `AgentChat.send` returns `{:ok, _}`. opencode-attach clears `QUEUED`. The agent's reply streams via the next per-turn marker bridge.

**Requirements:** R1 (R1.1–R1.4). AE1.

**Dependencies:** None.

**Files:**
- Modify: `elixir/lib/aiur/opencode/chat_completions.ex` — simplify `stream_turn/3` and `non_stream_turn/3`. Verify whether `stream_loop/4` and `collect_turn/4` have other callers via grep; if none, delete in the same commit (single-purpose helpers).
- Modify: `elixir/test/aiur/opencode/chat_completions_test.exs` — add tests for close-on-delivery semantics. The existing tests cover `build_chunk/2` only; no removal needed. **Test surface:** use `Plug.Test` to drive `dispatch_user_text` end-to-end with a stubbed `AgentChat.send` (via test-only `mox` or a module attribute swap — pick during impl).

**Approach:**
- `stream_turn/3`:
  - Call `send_operator/3`.
  - On `{:ok, _request_id}`: send one closing chunk with empty content + `finish_reason: "stop"`; close the chunked response; return.
  - On `{:error, reason}`: existing `emit_error_and_close` path.
- `non_stream_turn/3`: mirror — return `{:ok, %{... content: "", finish_reason: "stop"}}` on delivery success.
- The bridge-local `turn_id` becomes a request-tracking value passed through to `AgentChat.send` for AgentChat's own bookkeeping; no longer used for transcript matching.
- Verify `stream_loop/4` and `collect_turn/4` are unreferenced via grep + `mix compile --warnings-as-errors`. If unreferenced, delete in the same commit. If referenced elsewhere, leave intact and add a comment that `stream_turn` no longer uses them.

**Patterns to follow:** `empty_stream/1` already in `chat_completions.ex` — single closing chunk + return.

**Test scenarios:**
- *Happy path:* `dispatch_user_text` → `AgentChat.send` returns `{:ok, _}` → one SSE chunk with `finish_reason: "stop"` then close. Covers AE1.
- *Happy path (non-stream):* JSON response `%{choices: [%{message: %{role: "assistant", content: ""}, finish_reason: "stop"}]}`.
- *Error path:* `AgentChat.send` returns `{:error, reason}` → existing error chunk; close.
- *Edge case:* request body too large → existing 400 path unchanged.
- *Edge case:* unauthorized → existing 401 path unchanged.
- *Integration:* operator message → bridge closes quickly → agent's response streams via `stream_codex_turn` for the next codex turn.

**Verification:** Manual (per `AGENTS.md#manual-testing--the-only-definition`):
1. `aiur --test`, open OC pane, type `hi` in chat input.
2. Confirm the `hi` message moves from `QUEUED` → cleared within 1–2 s (verify what opencode-attach actually shows; if "DELIVERED" or no-status, document the observed state in the commit message).
3. Confirm the agent's response streams in via the per-turn marker bridge within a few seconds.
4. **Type a second message mid-tool-call** (e.g. while the agent is running `mix test`). Verify it clears QUEUED within ~1 s of the current tool returning, and the agent's reply streams in via the next turn.
5. **Verify no orphaned bridge SSE connections** via `lsof -p <BEAM pid> | grep TCP` — operator-message bridges should close, only per-turn bridges should remain.

**Trade-off accepted (from review):** The operator-message bridge no longer surfaces post-delivery codex failures (turn_failed / turn_input_required / watchdog). Those failures still surface via the per-turn marker bridge's own watchdog and via SessionWriter writes. The cost: a corner case where the agent dies between accepting the operator message and starting a turn now produces silent non-response. Mitigation: per-turn bridge watchdog catches this within 10 min; operator can re-send. Accepted because the regression to QUEUED-hangs-for-10-min is worse than this corner case.

**Non-regression touched:**
- One assistant message per codex turn (parity AE1) — preserved; the per-turn marker bridge is unchanged.
- Bridge SSE lifecycle on `aiur_turn_done` — preserved for the per-turn path.
- ActiveTurns phantom guard — preserved.
- Manual-override — preserved (SessionWriter persists user-message via the existing AgentChat → agent_runner path).

---

- [ ] **U3. `Protocol.system_message_data/1` + `SessionWriter.write_system_standalone/2`**

**Goal:** Add a `role: "system"` message-data helper and a SessionWriter write helper that uses it, so R2 event rows can be written without the `▣ Build · issue-N · chrome` of `assistant` rows.

**Requirements:** R2.5 (R2 ticker rows render without assistant chrome). Foundation for U4 and U5.

**Dependencies:** None.

**Files:**
- Modify: `elixir/lib/aiur/opencode/protocol.ex` — add `system_message_data/1`. Returns map with `"role" => "system"`, no `"mode"`, no `"agent"`, otherwise mirroring `assistant_message_data/1` (cwd, finish, time, tokens, etc. as needed — verify what opencode SQL schema requires for system messages by inspecting an existing system-role message in the DB if one exists, or by writing a probe row + capture-pane to verify rendering).
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` — add `write_system_standalone/2` mirroring `write_standalone/2` but calling `Protocol.system_message_data/1` and skipping role-based step-start/finish chrome. The body part is a single `text` part with the formatted row content.
- Test: `elixir/test/aiur/opencode/protocol_test.exs` — `system_message_data/1` returns the right shape.
- Test: `elixir/test/aiur/opencode/session_writer_test.exs` — `write_system_standalone/2` inserts the message + part rows; the message has `role: "system"`.

**Approach:**
- `Protocol.system_message_data/1` mirrors `assistant_message_data/1` (line 253) — same `identifier`, `parent_id`, `cwd`, `time` handling — but returns `%{"role" => "system", "id" => ..., "sessionID" => ..., "providerID" => "aiur", "modelID" => "issue-#{safe_id}", "time" => ..., "path" => ..., "finish" => "stop"}`. Omit `"mode" => "build"` and `"agent" => "build"` to avoid the build chrome.
- `write_system_standalone(state, %{body: body, dedup_key: key})`: insert message + step-start + text part + step-finish via existing `Db.with_transaction`. Return `{:ok, message_id}` or `{:error, reason}`.
- **Verification step in U3 itself (before U4 and U5):** write one probe row, run `aiur --test` with the probe trigger, capture pane, confirm the row renders without `▣ Build` chrome. If it does NOT render correctly (opencode SQL schema may reject `role: "system"`, or render it identically to assistant), document the actual rendering and decide whether to fall back to `role: "assistant"` with a distinct `modelID` (e.g. `"events"`) to get a different chrome label. The plan picks `system` because it's the natural choice; the probe validates the choice.

**Patterns to follow:** `Aiur.Opencode.Protocol.assistant_message_data/1` (line 253) — same field structure, different role.

**Test scenarios:**
- *Unit happy path:* `system_message_data(%{identifier: "99", parent_id: "msg_X"})` returns map with `"role" => "system"`, omits `"mode"`/`"agent"`.
- *Unit happy path:* `write_system_standalone(state, %{body: "hello", dedup_key: nil})` writes a message + text part to test DB; message has `role: "system"`.
- *Integration:* probe row written by SessionWriter renders in opencode-attach pane without `▣ Build` chrome. Verified manually via capture-pane on a live aiur run.

**Verification:** A probe row inserted via `SessionWriter.write_system_standalone/2` renders distinctly from a normal assistant row when viewed via `tmux capture-pane -p` of a live OC pane. Document the visual outcome in the commit message.

**Non-regression touched:**
- SessionWriter rich-part writes for transcript events — preserved; `write_system_standalone` is a sibling, not a replacement.
- Protocol's `assistant_message_data/1` — preserved; new helper sits alongside.

---

- [ ] **U4. Bridge + SessionWriter subscribe to DebugLog and render event rows**

**Goal:** Cross-ticket event rows appear live in chat panes (via bridge inline injection during a codex turn) and persist on re-attach (via SessionWriter writes). Both subscribers consume `Aiur.Events.DebugLog`'s existing broadcasts. Fix the second `queue_item_text` clause in agent_runner.ex to also broadcast `:read`.

**Requirements:** R2.1, R2.2, R2.3, R2.4, R2.5, R2.6. AE2, AE3.

**Dependencies:** U3 (uses `write_system_standalone/2` for persistence).

**Files:**
- Modify: `elixir/lib/aiur/agent_runner.ex` — second `queue_item_text` clause (the fallback at ~line 562) adds the matching `for event <- events do DebugLog.broadcast(:read, ...)` loop the first clause already has at lines 553–557. Without this, events ingested via the fallback path produce zero `📄` rows.
- Modify: `elixir/lib/aiur/opencode/chat_completions.ex` — in `stream_codex_turn/3` (line ~89), after subscribing to the agent topic, also call `Aiur.Events.DebugLog.subscribe/0`. Add a new clause in `codex_turn_stream_loop/4` (line ~129) matching `{:event_debug, %{identifier: ^identifier, kind: kind, topic: topic, id: id}}` for any `kind in [:publish, :receive, :read]`. Chunk a delta with the formatted row (e.g. `\n📥 #{topic} · from #? · id=#{id}\n` — refine source-ticket extraction during impl) and continue the loop. On `:aiur_turn_done`, call `DebugLog.unsubscribe/0`.
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` — in `handle_continue(:boot, ...)`, also call `DebugLog.subscribe/0`. Add `handle_info({:event_debug, %{identifier: this_identifier, kind: kind, topic: topic, id: id}}, state)` where `this_identifier == state.identifier`: dedup via `seen_event_ids` MapSet (state field, cap 500); if new, call `write_system_standalone/2` with the formatted row body. On `:event_debug` for a different identifier, no-op.
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` — add `seen_event_ids: MapSet.new()` to state initialization.
- Test: `elixir/test/aiur/agent_runner_test.exs` — **note: this file does NOT currently exist** per the doc review. Create the file with minimal setup (Issue struct + the queue_item_text function under test) and assert both digest-render clauses broadcast `:read`. If full agent_runner test setup is too heavy, extract `queue_item_text` into a small testable module or test via a thinner seam.
- Test: `elixir/test/aiur/opencode/chat_completions_test.exs` — assert the new clause in `codex_turn_stream_loop` chunks a formatted delta on `{:event_debug, _}`.
- Test: `elixir/test/aiur/opencode/session_writer_test.exs` — assert SessionWriter writes a system row on first `:event_debug` for its identifier; second with same event_id no-ops.

**Approach:**
- **Bridge live-render path:**
  - `stream_codex_turn(conn, identifier, aiur_turn_id)` subscribes to both `AgentPubSub.subscribe_agent(identifier)` (already in place) and `DebugLog.subscribe()`.
  - `codex_turn_stream_loop/4` adds a new receive clause:
    ```
    {:event_debug, %{identifier: ^identifier, kind: kind, topic: topic, id: id} = entry}
      when kind in [:publish, :receive, :read] ->
        delta = format_event_row(kind, topic, id, entry)
        conn = chunk(conn, completion_id, delta, nil)
        codex_turn_stream_loop(...)
    ```
  - `format_event_row/4` returns `\n#{emoji_for_kind(kind)} #{topic} · id=#{id}\n` wrapped via `Style.dim/1` (U5). Emoji map: `:publish → 📤`, `:receive → 📥`, `:read → 📄`. For `:receive`, include `from #<source_ticket>` if available in the DebugLog entry (verify the entry shape during impl — DebugLog's current `entry` map doesn't include source_ticket; either extend DebugLog's `:receive` broadcast or derive source from the topic prefix `ticket.<source>.…`).
  - On `aiur_turn_done`: call `DebugLog.unsubscribe()` before closing (cleanup).
- **SessionWriter persistence path:**
  - State adds `seen_event_ids: MapSet.new()` (capped at 500 — when at cap, drop oldest by re-creating from a `:queue` if needed; for v1 a simple MapSet is fine and we accept that very long sessions could re-process events).
  - In `handle_continue(:boot, ...)`: `DebugLog.subscribe()`.
  - New `handle_info({:event_debug, entry}, state)` clause: if `entry.identifier == state.identifier` and `entry.id not in state.seen_event_ids`, call `write_system_standalone/2` with the formatted body (same `format_event_row/4` helper extracted to a shared module — likely `Aiur.Opencode.EventRow` or kept private in both files initially; refactor only if duplication grows).
  - `seen_event_ids` is updated atomically with the write (only on success).
- **Agent_runner fix:**
  - The first `queue_item_text` clause (~line 544) has `for event <- events do DebugLog.broadcast(:read, ...) end` at lines 553–557.
  - The second clause (~line 562) builds the same `<aiur:events>…</aiur:events>` shape WITHOUT the broadcast loop.
  - Add the matching broadcast loop to the second clause.

**Patterns to follow:**
- `Aiur.Events.DebugLog.subscribe/0` — already exposed; same shape as Phoenix.PubSub subscribers used elsewhere.
- The first `queue_item_text` clause in `agent_runner.ex` (lines 544–560 region) — model for the second clause's broadcast loop.
- `session_writer.ex`'s existing `:alert` handler (write_standalone path) — system-row writing model (replace assistant call with the new system call).

**Test scenarios:**
- *Happy path (bridge):* `codex_turn_stream_loop` receives `{:event_debug, %{identifier: "99", kind: :receive, topic: "ticket.99.agent.progress.tests-green", id: 1779}}` → chunks a delta containing `📥 ticket.99.agent.progress.tests-green`. Covers AE2 (incoming live).
- *Happy path (bridge):* same loop receives `{:event_debug, %{kind: :publish, ...}}` → chunks `📤 ...`. Covers AE2 (outgoing live).
- *Happy path (bridge):* loop receives `{:event_debug, %{kind: :read, ...}}` → chunks `📄 ...`. Covers AE3 live.
- *Edge case (bridge):* `{:event_debug, %{identifier: "100", ...}}` while bridge is for `identifier: "99"` → no chunk; loop continues.
- *Edge case (bridge):* receives `{:event_debug, ...}` after `aiur_turn_done` already broadcast → loop has exited, no spurious chunks.
- *Happy path (SessionWriter):* first `{:event_debug, %{identifier: "99", id: 1779, ...}}` matching `state.identifier == "99"` → `write_system_standalone` called, row inserted, `1779` added to `seen_event_ids`. Covers R2.6 (write-once on first delivery).
- *Edge case (SessionWriter):* second `{:event_debug, %{id: 1779, ...}}` arrives → no-op. Covers R2.6 dedup.
- *Edge case (SessionWriter):* `{:event_debug, %{identifier: "100", id: 1779, ...}}` arriving at SessionWriter for `identifier: "99"` → no-op.
- *Happy path (agent_runner second clause):* fold an events digest via the fallback path → broadcasts `:read` per event_id (just like the first clause).
- *Integration:* Ticket 100's agent has subscribed to ticket 99. Ticket 99 emits `progress.tests-green`. During ticket 100's next codex turn, the bridge SSE chunks `📥 ticket.99.agent.progress.tests-green …` inline in the open assistant message. AND SessionWriter persists a system-role row to ticket 100's session SQL. Re-attach to ticket 100's pane shows the row in scrollback.
- *Integration:* Ticket 100 emits `progress.unblocked` via `emit_event`. Publisher → DebugLog broadcasts `:publish`. Ticket 100's bridge SSE chunks `📤 ticket.100.agent.progress.unblocked …`. SessionWriter writes the row.

**Verification:** Manual (per `AGENTS.md#manual-testing--the-only-definition`):
1. `aiur --test`, observe all 3 sandbox tickets coordinate via `aiur_declare_blocker` / `emit_event`.
2. In each chat pane, observe `📥` rows arriving inline during active turns.
3. In each chat pane, observe `📤` rows for emits the agent makes.
4. Observe a `📄` row at the start of the next turn after `📥` rows arrived (the visible arrival↔ingest gap).
5. Detach and re-attach to a chat pane; observe the same event rows persist in scrollback (SessionWriter wrote them to SQL).

**Non-regression touched:**
- Events foundation (publish/subscribe surfaces) — preserved; this unit only adds two new subscribers to DebugLog's existing topic.
- SessionWriter rich-part writes for transcript events — preserved; new handler is additive.
- Codex stream loop happy path (parity AE1) — preserved; new receive clause sits before the catch-all `_other`, doesn't change transcript-event handling.

---

- [ ] **U5. Dimmed styling via `Aiur.Opencode.Style.dim/1` (with empirical probe in live pane)**

**Goal:** Commands, tool calls, reasoning, and event ticker rows render visibly subdued; agent prose stays at default weight. Empirically verify the dim mechanism in a real opencode-attach pane (not just tmux capture-pane).

**Requirements:** R4 (R4.1–R4.4). AE5.

**Dependencies:** U3 (uses SessionWriter's system-row writer), U4 (uses bridge event-row formatter).

**Files:**
- Create: `elixir/lib/aiur/opencode/style.ex` — small public module exposing `dim/1` that wraps a string in the chosen dimming mechanism. **Public** so tests can assert on the output.
- Modify: `elixir/lib/aiur/opencode/chat_completions.ex` — `format_delta/2` for `:command`, `:tool`, `:reasoning` wraps the body via `Style.dim/1`. Refactor: extract the role → delta-string mapping into a public `format_delta/2` (already public-by-test-need anyway), OR introduce `Aiur.Opencode.DeltaFormatter` with public functions for testability. **Picking the smaller change:** rename the current `defp format_delta/2` to `def format_delta/2` (with `@spec`). Adds a public surface but doesn't restructure modules.
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` — event-row writers in U4 wrap the body via `Style.dim/1` before passing to `text_part_data`.
- Test: `elixir/test/aiur/opencode/style_test.exs` (new) — `dim/1` wraps with the chosen mechanism.
- Test: `elixir/test/aiur/opencode/chat_completions_test.exs` — `format_delta(:command, ...)` returns a string containing the dim wrapper; `format_delta(:assistant, ...)` does not.

**Approach:**
1. **Probe step (implementer runs before merging U5):**
   - `aiur --test` to bring up a known-good chat pane (issue 99, 100, or 101).
   - Use the SessionWriter test helpers (or a Mix task / IEx scratch) to write a probe row containing `\e[2mhello dim world\e[22m`, then a sibling row containing `▸ hello marker world`.
   - View the live opencode-attach pane in a real terminal (not just `tmux capture-pane`). `capture-pane` shows the cell grid as tmux resolved it, which can produce false positives because tmux respects ANSI dim even if opencode-attach's bubbletea/lipgloss renderer stripped or transformed the escape upstream.
   - **Decision rule:** if the ANSI dim row renders visibly subdued in the real terminal, use ANSI dim. If it renders as literal `\e[2m` text or as same-weight prose, fall back to the `▸ ` marker. Document the chosen mechanism + the probe outcome in a comment on `Style.dim/1`.
2. **`Aiur.Opencode.Style`:** small module with `@spec dim(String.t()) :: String.t()`. Body wraps in chosen mechanism. Single function, easy to swap implementation.
3. **`format_delta/2`:** apply `Style.dim/1` to bodies for `:command`, `:tool`, `:reasoning`. Leave `:assistant`, `:user`, `:system`, `:alert` untouched.
4. **Event-row writers (U4):** wrap the formatted row body via `Style.dim/1` before passing to `text_part_data`.
5. **Failed-emission visual treatment:** for `:publish` marks that correspond to a *failed* emission (if DebugLog distinguishes — it currently doesn't), prefix the row with `⚠ ` and **do not dim**. v1 likely doesn't have access to success/failure status at the DebugLog seam since Publisher.publish only fires `:publish` on success. Document: failed emissions are silent in the chat pane (operator sees them via the per-issue log + DynamicTool's error return shown in the tool result). Move full failed-emission visibility to a follow-up if it becomes an issue.

**Patterns to follow:**
- `Aiur.Opencode.ChatCompletions.format_delta/2` — clause-per-role conventions stay.

**Test scenarios:**
- *Unit happy path:* `Style.dim("hello")` returns the wrapped string (assert against the chosen wrapper; if ANSI, `"\e[2mhello\e[22m"`; if marker, `"▸ hello"`).
- *Unit happy path:* `format_delta(:command, "git status")` contains the dim wrapper.
- *Unit happy path:* `format_delta(:tool, "edit foo.ex")` contains the dim wrapper.
- *Unit happy path:* `format_delta(:reasoning, "thinking")` contains the dim wrapper (replacing the current markdown italics `_…_`).
- *Unit happy path:* `format_delta(:assistant, "Hello")` does NOT contain the dim wrapper.
- *Unit edge case:* `Style.dim("")` returns the wrapped empty string (no crash).
- *Integration:* SessionWriter's `📥` row body is dim-wrapped; capture-pane verifies rendering on probe.

**Verification:** Manual: `aiur --test`, observe a chat pane during an agent turn with prose + multiple commands + tool calls + at least one `📥` event row. Agent prose is the most visually prominent; commands, tools, reasoning, event rows are clearly subordinate. **In a real terminal, not just `tmux capture-pane`.**

**Non-regression touched:**
- Bridge SSE delivery — preserved; only body wrapping changes.
- SessionWriter writes — preserved; only text body content gains wrapper.
- One-message-per-turn chrome — unchanged.

---

- [ ] **U6. Foregrounded aiur cleanly stops on exit (verification + minor gaps)**

**Goal:** Pressing `q`, Ctrl+C, terminal close, SSH HUP, or `tmux kill-session` takes down every aiur-owned process and clears sockets/lock files. `aiur stop` is documented as `--bg`-only.

**Requirements:** R5 (R5.1–R5.4). AE6.

**Dependencies:** None.

**Files:**
- Modify: `scripts/aiur` — help text for `aiur stop` updated to say "for backgrounded `aiur --bg` runs only; foregrounded runs clean up automatically on exit". (One-line edit.)
- Verify: `scripts/aiur` `__aiur_cleanup` trap at lines ~1196–1221 (from commit `7f3089a`). Add missing signal handlers if any of the four exit paths in test scenarios below leak processes.
- Verify: `elixir/lib/aiur/agent_list/app.ex` `q` handler. Confirm it ultimately triggers `Aiur.Shutdown.shutdown/1` (which calls `System.halt`) so the BEAM exits cleanly, which closes the tmux window, which closes the tmux session, which causes the bash trap to fire.
- Test: manual only (signal handling is hard to unit-test).

**Approach:**
- This is primarily a verification unit. Existing `__aiur_cleanup` trap from commit `7f3089a` was designed for this purpose. The brainstorm noted "might still have gaps" — the work is to find them by running each exit path and confirming clean process state.
- The exit chain (verified by the doc-review):
  - `q` keypress → `AgentList.App` → `Aiur.Shutdown.shutdown/1` → `Aiur.Shutdown.cleanup` (deletes opencode sessions) → `Supervisor.stop(Aiur.Supervisor)` → `System.halt(code)` → BEAM exits → tmux window dies → tmux session closes (single-window session) → outer bash detaches → bash EXIT trap fires → `__aiur_cleanup` runs (`tmux kill-session`, SIGTERM stragglers, reap opencode-serves).
  - Ctrl+C → bash receives SIGINT → INT trap fires → re-kills script with SIGINT → EXIT trap fires → same cleanup.
  - SSH HUP → bash receives SIGHUP → HUP trap fires → same cleanup.
  - `tmux kill-session` → tmux client (in the outer bash) exits → bash continues → EXIT trap fires.
- Update the help text first (one-liner). Then run the four manual verification scenarios. If any leaks processes, debug and fix in the same unit.

**Patterns to follow:** existing `__aiur_cleanup` trap.

**Test scenarios:** (all manual, per `AGENTS.md#manual-testing--the-only-definition`):
- *Manual happy path 1:* `aiur --test`, wait for boot, press `q` in TUI → `pgrep -f "beam.smp.*aiur-orangekid"`, `pgrep -f "opencode serve --port 0"`, `pgrep -f "opencode attach"` all return empty within 3 s. Covers AE6.
- *Manual happy path 2:* `aiur --test`, Ctrl+C from foreground terminal → same outcome.
- *Manual happy path 3:* `aiur --test` from SSH, disconnect SSH (terminal close) → same outcome (HUP trap fires).
- *Manual happy path 4:* `aiur --test`, from a separate terminal `tmux kill-session -t aiur-orangekid-default` → outer bash exits, trap fires, processes gone.
- *Manual non-regression:* `aiur --bg`, `aiur stop` still works as today (kills BG processes, leaves no orphans).

**Verification:** After EACH of the four exit paths above:
```
pgrep -fa "beam.smp.*aiur-orangekid"
pgrep -fa "opencode serve --port 0"
pgrep -fa "opencode attach"
ls -la ~/.local/state/aiur/aiur.pid 2>&1 || echo "ok: no pid file"
```
All process commands return nothing. PID file absent or empty.

**Non-regression touched:**
- `aiur stop` for `--bg` runs — unchanged; only help text clarified.
- Server.terminate child reaping (commit `7f3089a`) — preserved; this unit verifies it's still working across all exit paths.
- Boot reaper (commit `7f3089a`) — preserved; the cleaner exit-time behavior means the boot reaper finds less to do.

---

## System-Wide Impact

- **Interaction graph:** R2 reuses `Aiur.Events.DebugLog` as a single broadcast source. Two new subscribers (bridge `codex_turn_stream_loop`, SessionWriter `handle_info`) both filter by `identifier == this_identifier`. R1 simplifies bridge `stream_turn` to fire-and-forget after `AgentChat.send/3` accept; the per-turn marker bridge (`stream_codex_turn`) is unchanged. R4 wraps text bodies via `Aiur.Opencode.Style.dim/1` in two sites (bridge `format_delta`, SessionWriter event-row writers).
- **Error propagation:** SessionWriter insert failures continue to log + continue. The bridge's new DebugLog clauses no-op on bad payload (defensive). `Style.dim/1` is total: input string → output string. `AgentChat.send` errors flow through the existing `emit_error_and_close`.
- **State lifecycle risks:** SessionWriter gains `seen_event_ids: MapSet`; grows unbounded if cap isn't enforced — start with 500 cap (matches history pull). Bridge subscribes to a NEW topic (`DebugLog.topic()`) during each codex turn — unsubscribe on close to avoid stale subscriptions if the BEAM stays up.
- **API surface parity:** `AgentChat.send/3` interface unchanged. `DynamicTool` handler shape unchanged (no broadcasts added). `Aiur.Workflow` / config unchanged. `scripts/aiur` gains implicit `--test`→`--force` and an updated help string.
- **Integration coverage:** End-to-end manual verification covers SubscriptionStore → DebugLog → bridge (live render) AND → SessionWriter (persistence) for `:receive`; Publisher → DebugLog → both subscribers for `:publish`; agent_runner queue_item_text → DebugLog → both subscribers for `:read`.
- **Unchanged invariants:** opencode SQL schema (other than the new `role: "system"` message rows), `Protocol.assistant_message_data/1`, IssueLog disk format, ULID monotonicity (commit `2c4a5db`), Slot lifecycle, ActiveTurns registry, Server.terminate child reaping, manual-override. Per-turn marker bridge (`stream_codex_turn`) is structurally unchanged — only adds a new receive clause for `:event_debug` and a new subscribe/unsubscribe pair around its lifetime.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| R1 close-on-delivery → operator sees a blank assistant message bubble after every input (opencode-attach treats `finish_reason: "stop" + empty content` as a real empty turn rather than message acceptance) | U2 manual verification explicitly tests this. If blank bubble appears, options: (a) send a short ack delta (e.g. a single space) before close so opencode renders a non-empty message; (b) revert to a minimal `stream_loop` that closes on first `:transcript_event` of any role; (c) probe opencode-attach version-specific behavior. Picked during verification. |
| R2 events arriving outside an active codex turn don't render live (bridge SSE is per-turn) | Documented in Key Technical Decisions as accepted trade-off; events appear on next turn AND persist to SQL via SessionWriter for re-attach. The agent_list sidebar ticker remains the always-on operator surface. |
| ANSI dim escapes don't render in opencode-attach | U5's probe step verifies in a real opencode-attach pane (not just capture-pane); fallback is `▸ ` Unicode marker. Either way, U5 ships with verified visual subordination. |
| `Protocol.system_message_data/1` produces rows opencode-attach doesn't render (or renders identically to assistant) | U3's probe step verifies before U4/U5 build on it. If unworkable, fall back to `role: "assistant"` with a distinct `modelID` (e.g. `"events"`) to get a different chrome label. |
| Replay race on re-attach: SessionWriter replays IssueLog history, which doesn't include DebugLog marks, so event rows don't appear in re-attach scrollback from replay | Acceptable for v1 — event rows are written at `:event_debug` receipt time, so any chat pane open at the time gets the row in SQL. New chat panes (mid-session re-attach to a long-running session) miss the historical events but see future ones. If this is unacceptable, follow-up adds an IssueLog event-row format and replay support. |
| Bridge's new DebugLog subscription during a codex turn creates a message storm if many events fire in one turn | DebugLog broadcasts are local and cheap; the bridge chunks each as a small SSE delta. opencode-attach handles a continuous stream of deltas already (that's the codex transcript path). No additional mitigation needed. |
| Removing `stream_loop` / `collect_turn` breaks a test or caller I missed | Grep + `mix compile --warnings-as-errors` before deletion. Keep deletion in a separate commit from the refactor to make revert easy. |
| `seen_event_ids` MapSet grows unbounded on a long-running agent | 500-entry cap; oldest IDs evict (via `:queue` augmentation if MapSet alone isn't enough — pick during impl based on actual event volume). For v1, a plain MapSet without eviction is acceptable if memory profile shows < 1 MB per identifier. |
| U6's verification finds gaps the brainstorm didn't anticipate | Fix in the same unit; if scope balloons (e.g. tmux-attach-detach reaping), split into a follow-up. |

---

## Documentation / Operational Notes

- No new env vars, config flags, or CI changes.
- No migration — change is invisible except: chat panes gain `📥/📤/📄` rows + dimmed tool/command/reasoning; operator messages clear QUEUED quickly; `aiur --test` rebuilds without `--force`; foregrounded exit auto-reaps.
- Update `elixir/docs/notes/opencode-row-shapes-1.15.6.md` to add the new `role: "system"` row shape from U3 if the probe confirms opencode-attach renders it distinctly.
- PR body follows the template. Complexity routing: `complexity:3` — focused follow-ups cross-cutting chat_completions, session_writer, agent_runner, debug_log, protocol, scripts/aiur, agent_list/app.ex but each surface narrow.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-25-aiur-chat-pane-followups-requirements.md`
- **Prior parity plan (for AE re-run on each unit's verification):** `docs/plans/2026-05-25-001-feat-chat-pane-native-parity-plan.md`
- **Events foundation brainstorm:** `docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md`
- **Manual-testing definition:** `AGENTS.md#manual-testing--the-only-definition` (committed in `c3d58f0`)
- **PR #98:** `https://github.com/aiur-team/aiur/pull/98`
- **ce-doc-review findings (round 1) that drove this v2 revision:** captured inline above in Key Technical Decisions and Risks & Dependencies.
