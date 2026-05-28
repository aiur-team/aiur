---
status: active
created: 2026-05-25
scope: standard
links:
  - docs/brainstorms/2026-05-25-aiur-chat-pane-native-parity-requirements.md
  - docs/plans/2026-05-25-001-feat-chat-pane-native-parity-plan.md
  - docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md
---

# Aiur chat pane — follow-ups after manual verification

## Problem frame

PR #98 shipped the event foundation and the first pass of chat-pane native parity (R1–R3 + R6 from the parity brainstorm). Manual verification revealed four issues the operator wants closed before the work is done:

1. Operator messages typed into the chat input box stay in the **QUEUED** state indefinitely. The agent eventually acts on them but the chat-pane status indicator doesn't reflect that — it sits on `QUEUED` until the bridge's 10-min watchdog. Expected behavior is the standard agent-CLI pattern (codex, claude code, opencode native): agent reads the message immediately OR finishes the current tool call and then reads it — within seconds, not minutes.
2. **Cross-ticket events don't appear inside chat panes.** They show up correctly in the agent_list sidebar live ticker, but the per-agent chat pane has no inline indication that an event arrived OR that the agent read/ingested it. U5/U6 from the parity plan (system-role ticker rows in chat) were not wired — `grep` for `:received_event` / `:emitted_event` returns zero hits across `session_writer.ex`, `agent_pubsub.ex`, `dynamic_tool.ex`, and `subscription_store.ex`.
3. **`aiur --test` requires the operator to remember `--force`.** Without it, a stale `_build/` carries over and feature work appears not to ship. The script already has `test_force` parsing; the two flags just aren't bound.
4. **Tool/command/build content renders with the same prominence as agent prose.** When commands and tool calls dominate the screen, finding the agent's actual narrative takes effort. Operator wants commands and tool/build content visually subdued (greyed out) so the eye lands on prose first.

## Users / actors

- **Operator** — the human watching agents work across chat panes and typing in nudges, corrections, and questions.
- **Agent** — codex (or future coding agents) emitting transcript events and publishing/subscribing aiur events.
- **Opencode TUI** (opencode-attach) — the renderer the operator sees. Owns the chat-pane styling vocabulary.

## Goals

1. Operator nudges feel instantaneous — no "is this stuck?" doubt. QUEUED clears as soon as the agent has accepted delivery (immediately if idle, after current tool call otherwise).
2. The chat pane is the operator's single surface for following an agent — including the cross-ticket coordination signals it cares about. No need to glance at the sidebar ticker to know what events are flowing.
3. `aiur --test` is the one command an operator types to get a clean test run — no separate `--force` ritual.
4. Chat-pane visual hierarchy makes the agent's narrative scannable: prose stands out; tool calls and build output stay subdued but legible.

## Requirements

### R1. Operator messages clear QUEUED within seconds

When the operator submits a message in the chat input:

- **R1.1** If the agent is idle (between turns / between tool calls), the message renders as `DELIVERED` (or whatever opencode's "the agent has it" state is) within ~1 second. The agent then ingests it on the very next turn.
- **R1.2** If the agent is mid-tool-call, the message stays `QUEUED` until that tool call returns, then transitions to `DELIVERED` within ~1 second. The agent ingests it on the immediately-following turn boundary or interrupt point — not minutes later.
- **R1.3** The bridge SSE response that backs the chat-completion finishes (`finish_reason: "stop"`) once delivery is confirmed, not when the agent has produced a full reply. The operator sees the rendered user message + the agent's response *streaming* in the same pane, but the `QUEUED` indicator is gated on delivery, not on agent reply completion.
- **R1.4** Bridge does not hold the chat-completion open on a `turn_id` pin codex will never satisfy. Either the pin is dropped, AgentChat publishes a bridge-tagged delivery event the bridge can match on, or QUEUED simply transitions to DELIVERED as soon as `AgentChat.send` returns `{:ok, _}` and the bridge closes the SSE.

### R2. Cross-ticket events render inline in the agent's chat pane

For every event delivered to a subscriber agent's inbox (R4 from the parity brainstorm) and every event the agent publishes itself (R5):

- **R2.1** A short system-role row appears in the agent's chat pane, distinct from agent prose and tool/command parts. Inbox arrivals use `📥` (inbox); outgoing publishes use `📤` (outbox).
- **R2.2** Inbox arrivals show topic, source ticket, and event id on one line. Example: `📥 ticket.99.agent.progress.tests-green · from #99 · id=1779…`. Payload details belong in the per-issue log + dashboard, not the chat ticker.
- **R2.3** Outgoing publishes show tool, key topic/argument, and event id. Example: `📤 emit_event · progress.brainstorm-end · id=1779…`. Failed emissions are prefixed with `⚠`.
- **R2.4** A **second row** appears when the agent actually *reads/ingests* an event — i.e., when the inbox digest is rendered into the agent's prompt at turn start. Style mirrors the inbox arrival but uses `📄` (read). Lets the operator see the delay between "event arrived" and "agent saw it". Example: `📄 ticket.99.agent.progress.tests-green · ingested at turn start · id=1779…`.
- **R2.5** Rows always show, no `--debug` gate (matches the parity plan's U5/U6 decisions).
- **R2.6** Rows are write-once per (event_id, kind). Replay across re-attach does not regenerate them; the SessionWriter dedup ring (already in place for transcript events) covers event rows too.

### R3. `aiur --test` implies `--force`

- **R3.1** Running `aiur --test` (with no other reset flags) behaves identically to today's `aiur --test --force`: full sandbox reset, fresh build, no stale `_build/` carry-over.
- **R3.2** An explicit `aiur --test --no-force` (or equivalent escape hatch) is acceptable but not required — the failure mode of stale builds appearing to break features is the dominant pain. If escape-hatch is added, default and naming are a planning decision.
- **R3.3** No new flag for the existing behavior. Anyone with `aiur --test` in muscle memory or scripts keeps working; they just get the cleaner behavior automatically.

### R5. Foregrounded `aiur` cleanly stops everything on exit

When the operator exits the aiur TUI (Ctrl+C, `q`, closing the tmux session, terminal close), all aiur-owned processes go away — opencode-serves, opencode-attach panes, the BEAM, any orphaned tmux sessions. The operator should never need to run `aiur stop` after a foregrounded run.

- **R5.1** Pressing `q` (or whatever the TUI's "quit" key is) shuts down the BEAM, closes the tmux session, kills the opencode-serves and attach panes, and removes any sockets/lock files. Zero leftover processes on `ps aux`.
- **R5.2** Same behavior on Ctrl+C from the foregrounded aiur process.
- **R5.3** Same behavior on terminal/SSH close (HUP signal).
- **R5.4** `aiur stop` continues to exist solely for the `aiur --bg` use case — when aiur was backgrounded with no UI to send signals to. Foregrounded runs don't need it. The doc/help text on `aiur stop` should explicitly say this so an operator running foreground doesn't reach for it expecting it to do something useful.

### R4. Visual hierarchy: agent prose stands out

- **R4.1** Agent-message text (`assistant_message` role) renders in opencode-attach's default text color — currently the brightest/most prominent style. No change to today.
- **R4.2** Command, tool, and reasoning content renders in a dimmed/greyed style that opencode-attach's TUI honors. The exact mechanism (ANSI escape codes in the SSE delta, a markdown convention, or a tool-part field opencode TUI styles by) is a planning decision; the requirement is "noticeably subdued vs prose".
- **R4.3** Inbox/outbox/read event rows (R2) are dimmed similarly — they're context, not agent narrative.
- **R4.4** Existing chrome (the `▣ Build · issue-N · timing` header) is unchanged.

## Acceptance examples

- **AE1 (R1):** Operator types `hi` while the agent is mid-`mix test`. `hi` renders as `QUEUED` momentarily, then within 1–2 s of `mix test` returning, transitions to `DELIVERED`. The next agent turn opens with the agent responding to `hi`. No 10-minute hang on `QUEUED`.
- **AE2 (R2.1–R2.3):** Ticket 100's agent runs while ticket 99's agent emits `progress.tests-green`. Ticket 100's chat pane shows a `📥 ticket.99.agent.progress.tests-green · from #99 · id=…` row at the time of arrival. When ticket 100's agent calls `emit_event("progress.unblocked", …)`, its own chat pane shows `📤 emit_event · progress.unblocked · id=…`.
- **AE3 (R2.4):** Ticket 100's chat pane shows `📥` rows as events arrive in real time, then a corresponding `📄` row appears at the start of the next agent turn (when the digest is folded into the prompt). The operator can read the gap and see "arrived 12:01:03, ingested 12:01:18".
- **AE4 (R3):** `aiur --test` and `aiur --test --force` produce identical state on disk and identical first-boot behavior. `_build/` is rebuilt either way.
- **AE5 (R4.1–R4.2):** On a turn containing one assistant_message + three commands + one reasoning block, the assistant_message text is visually obvious; the `$ git status`, `$ mix test`, `$ gh pr list` lines and the reasoning block are clearly subdued. The operator can find the prose without reading line by line.
- **AE6 (R5.1–R5.3):** `aiur --test`, press `q` in the TUI (or Ctrl+C the foreground), then `ps aux | grep -E "beam.smp.*aiur|opencode (serve|attach)"` shows zero results. Same outcome after `kill -HUP <terminal>`. No leftover sockets in `~/.local/state/aiur/`.

## Scope boundaries

### In scope

- Bridge SSE QUEUED-state lifecycle fix (R1).
- Cross-ticket event rows in chat panes — arrival, outgoing, and read indicator (R2).
- `--test` → `--force` implicit composition (R3).
- Tool/command/reasoning subdued styling in chat panes (R4).
- Clean foreground-exit semantics (R5) — foregrounded aiur self-cleans without needing `aiur stop`.

### Deferred for later

- **Operator-message interrupt path beyond what AgentChat already provides.** R1 only requires the *status indicator* to clear — actual mid-tool-call interrupt semantics are AgentChat's existing contract; no new interrupt machinery here.
- **Payload-rich event cards.** R2 keeps event rows to one line. A full event-card UI (with payload expansion, click-through to source ticket) belongs to a later dashboard pass.
- **Per-event-type styling vocabulary.** R2.5 says all event rows share the `📥/📤/📄 …` shape. Distinct styling per event surface (`branch.push` vs `agent.attention`) is a later polish.
- **Operator-driven event filtering in chat.** "Mute these event types" or "show only blockers" is out of scope.
- **Color-theme negotiation.** R4 picks "noticeably subdued"; the exact palette is a planning decision, not a configurable theme.

### Outside this product's identity

- We are not modifying opencode-attach. R4 styling uses whatever rendering vocabulary opencode-attach already honors (ANSI codes, markdown, or part-state fields). If none of those work for the styling we want, R4 falls back to a leading dim-marker character + plain text, not a TUI patch.

## Non-regression constraints

The work that just shipped on PR #98 was hard-won and just got manually verified. These behaviors **must continue to work** after this follow-up lands:

- One opencode assistant message per codex turn (R1 from the parity plan). No regression to "many empty Build chrome headers".
- Bridge SSE lifecycle closes on `aiur_turn_done`, not on codex's internal turn boundary, so operator messages injected mid-turn flow through the existing stream without orphans.
- ActiveTurns registry guards against phantom chat-completion requests from opencode-serve replaying stale `__aiur_turn__:<id>` markers.
- Server.terminate + boot reaper keep opencode-serve children tied to the BEAM's lifetime (no PID=1 orphans across reboots).
- SessionWriter writes rich tool/command/reasoning parts to SQL (the source of truth for re-attach).
- Events foundation: `emit_event`, `emit_alert`, `aiur_subscribe`, `aiur_subscribe`, `aiur_declare_blocker`, `aiur_unblock` tool surface unchanged. The publish path (Exchange + IdGenerator + SubscriptionStore) is untouched.
- `aiur --test` reset machinery: pinned-ticket allowlist, workspace rm, branch close, label reset to `agent:todo`, `--allow-remote` guard.
- Agents continue to run independently of opencode-serve being attached. SQL via SessionWriter remains the source of truth; if opencode-serve is down, the agent keeps working.

Every implementation unit in the plan must explicitly call out which non-regression constraint it touches (if any) and how it preserves the prior behavior. Manual verification at the end of each unit re-runs the AE acceptance examples from the parity plan + brainstorm, not just the new AEs above.

## Dependencies / assumptions

- **AgentChat's delivery semantics** continue to work as today: `:interrupt` policy with `:queue_next` fallback, returns `{:ok, request_id}` synchronously when the message is accepted. R1 leans on this — we're fixing the indicator, not the delivery.
- **The event foundation** (SubscriptionStore, AgentPubSub, Exchange, IdGenerator, DynamicTool) is stable on `aiur/22-events-foundation`. R2 hooks into the existing delivery + emit seams.
- **Opencode-attach's TUI** renders SSE deltas as markdown-ish text and honors at least *some* dimming syntax (ANSI dim escape `\e[2m...\e[22m`, or markdown emphasis the rendering reduces). The exact mechanism is verified during planning by capture-pane on a synthesized row.
- **SessionWriter's dedup ring** (commit `8a8dafb` family) is already in place and bounded; R2.6 reuses it.

## Open questions for planning

1. **R1 mechanism.** Three viable shapes: (a) drop the turn_id pin in `stream_loop` and close the SSE immediately after `send_operator` returns `{:ok, _}`; (b) have `AgentChat.send` publish a bridge-tagged `:operator_delivered` event the bridge matches on; (c) keep the pin but use the agent's first transcript event after delivery as the "yes, picked up" signal. Tradeoffs: (a) is simplest but the chat-completion finishes before the agent has actually responded — does that break opencode-attach's rendering of the assistant reply? (b) is the cleanest but adds a new PubSub topic. (c) leaks the bridge's turn_id semantics into agent_runner. Plan picks one.
2. **R2 read-indicator emit point.** When exactly does the `📄 ingested` row fire? Options: (i) at digest-render time inside `agent_runner.ex`'s prompt builder; (ii) at the start of the turn the digest is bundled into; (iii) at agent prompt-receipt (i.e., when codex acknowledges the turn input). (i) is most accurate; (ii) is simplest. Plan decides.
3. **R4 dimming mechanism.** Capture-pane during planning to confirm what opencode-attach honors. Hypothesis: ANSI `\e[2m...\e[22m` works because opencode-attach is built on bubbletea/lipgloss which respects 256-color and dim. If not, plan falls back to a leading `▸` or grey-block character to visually subordinate without color.
4. **R3 escape hatch needed?** Does anyone benefit from `aiur --test` *without* `--force` (faster repeat reset when only labels changed, build is known good)? If yes, plan adds `--no-force`. If no, drop the question.
