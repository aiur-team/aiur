---
date: 2026-05-17
topic: Pane-side message queue with instant-vs-queued submit modes
branch: feat/cli-pane-rearchitecture
issue: https://github.com/its-everdred/symphony/issues/31
status: ready-for-planning
---

# Pane-side message queue with instant-vs-queued submit modes

## Problem Frame

Issue 25 logs show the current "interrupt-first" delivery model literally
interrupts the agent mid-command. Two reproducible examples from
`symphony.25.log`:

- Agent was running `sleep 300` for a deliberate 5-minute wait. The user
  typed a message; the running `sleep` was cancelled and the agent had
  to acknowledge the interruption ("your message interrupted the running
  `sleep 300` command, so the 5-minute wait did not complete").
- Agent was running a 30-second shell loop appending to a temp file. The
  user typed "hi". The loop was cancelled at 12 of 30 iterations.

This is fine when the user is steering the agent away from a wrong
direction, but actively destructive when the agent is mid-execution of
an explicit instruction.

## Comparison: claw-code vs Symphony

`ultraworkers/claw-code` (Rust CLI agent harness) was reviewed for
inspiration. **It has no user-message queue at all** — the REPL is
strictly sequential:

```
loop {
    editor.read_line()        // blocks
    cli.run_turn(input)       // blocks for the entire model+tool loop
}
```

While `run_turn` is executing, typed bytes go to the OS terminal buffer
and may be consumed by the next `read_line()` *or* by a permission
prompt mid-turn (`CliPermissionPrompter::decide` reads stdin
synchronously). Their UX advantage is not queueing; it's that a single
human is driving a single agent and turns end fast enough that blocking
feels OK. We can't copy that model because Symphony runs many agents in
parallel and operator messages routinely need to wait for an active
turn.

## What Symphony already has (existing infra)

Worth knowing before designing — most of the plumbing already exists:

1. **`AgentQueue.operator_message/3`** supports two policies:
   `:checkpoint` (queued, drained at a safe boundary) and `:interrupt`
   (force-stop the in-flight tool). Today the pane uses `:interrupt`.
2. **`safe_checkpoint_handler` (`agent_runner.ex:553`)** drains
   `:checkpoint`-policy queue items **mid-turn** — every notification
   AND every `item/tool/call` boundary invokes the handler. So
   `:checkpoint` messages do not wait for the turn to fully end; they
   land at the next clean point inside the running turn.
3. **`drain_operator_messages` (`agent_runner.ex:434`)** runs after
   each turn completes and starts a fresh turn for every queued
   operator message in order.
4. **PubSub broadcasts** every transcript event (`{:transcript_event,
   event}`) to the pane already, so the pane can observe `:assistant`,
   `:command`, etc. events without new wiring.

The historical "minutes-long wait for turn end" complaint was specific
to `:checkpoint` policy *before* intra-turn drain was wired. Today the
remaining stall case is **a single long-running tool with no
intermediate output** (e.g. `sleep 300`) — no notifications fire while
the tool runs, so no checkpoint drains either.

## Decisions confirmed with operator

- **Default policy on Enter while busy:** always `:checkpoint`, never
  interrupt. The cancelled-sleep behavior is unacceptable.
- **Multiple queued messages:** bundle into one merged drain (single
  combined operator message joined with blank lines). The agent reads
  the whole stream as one thought.
- **Queue location:** pane-local only, mirrored to per-issue log on
  add so a pane crash doesn't lose typed text.
- **Drain trigger:** open question — see options below.
- **Idle (no-agent-running) case:** open question — see below.

## Drain-trigger options

The pane queues every submit locally. The remaining design question is
*when* the queue drains to the orchestrator. Three candidate triggers:

### Option A — Pane-side busy/idle classifier

The Conversation GenServer maintains an `agent_state ∈ {:idle, :busy}`
inferred from PubSub events:

- `:command` event without paired `[exit=...]` → `:busy`
- `:assistant` event followed by 1.5s of silence → `:idle`
- Otherwise → previous state

Enter behavior **switches based on state**:

- `:idle` → submit immediately (today's path)
- `:busy` → stack in the visible queue; drain when state flips back to
  `:idle`

**Trade-offs:**

- (+) Operator sees instant submit when the agent is genuinely idle.
- (−) Classifier is heuristic and *will* be wrong (agent pauses 4s
  between two quick tool calls → falsely "idle" → next submit
  interrupts the next tool).
- (−) Two different Enter behaviors the operator has to model.
- (−) Codex and Claude emit different events; classifier needs a
  per-agent translation layer.

### Option B — Drain at every orchestrator checkpoint

The pane always queues locally for visibility, and submits each
queue-add as a `:checkpoint`-policy item to the orchestrator
immediately. The existing `safe_checkpoint_handler` drains it at the
next notification/tool boundary.

**Trade-offs:**

- (+) Reuses existing infrastructure entirely; no new state machine in
  the pane.
- (+) Idle agent → drain happens at the next event (essentially
  instant).
- (−) Messages drain one-by-one at successive checkpoints — operator
  types 3 lines, agent sees 3 distinct turns interleaved with its own
  replies. Bundling into one merged drain conflicts with this model
  (orchestrator would need a "hold off until N more are queued" hint).
- (−) Single long-running tools (`sleep 300`) still hold the queue
  because no checkpoints fire.

### Option C — Drain after agent message (recommended for v1)

The pane always queues locally. The **drain trigger is a single
PubSub event**: when the pane receives a `{:transcript_event,
%{role: :assistant}}` for this issue, it submits the merged queue as
ONE `:checkpoint`-policy operator message.

**Trade-offs:**

- (+) Simplest possible mental model: "your queued messages get sent
  right after the agent finishes talking."
- (+) Implementation is tiny: ~20 lines in `Conversation` —
  `handle_info({:transcript_event, %{role: :assistant}}, …)` checks
  if queue is non-empty and submits.
- (+) No classifier, no heuristics, no per-agent translation.
- (+) Naturally handles the `sleep 300` case: when the sleep returns
  and the agent says "done", the queue drains immediately. No
  cancelled commands.
- (+) Bundling fits naturally — accumulate queue, drain on next
  `[agent]` event, one merged message goes to the agent.
- (−) If the agent is silently generating a long response (5 paragraphs
  streaming), the queue waits until the message lands. Acceptable —
  the operator was going to wait anyway and at least sees their queued
  lines stacked while waiting.
- (−) No way to force-drain if the operator wants to interrupt. Mitigation:
  add `Shift+Enter` as `:interrupt`-policy force-send in v2.

## Idle (no-agent-running) sub-question

When the operator opens a pane on an issue whose agent isn't currently
running, what does Enter do?

- **A.** Same as today — `PaneRPC.send_operator_message` RPC submits and
  the orchestrator decides (might start a new agent run, might just
  queue). Pane queue is only meaningful while an agent IS running.
- **B.** Pane queues locally either way; waits indefinitely for an
  agent to come up before draining.

Option A is the smaller change and avoids the orphaned-queue case. The
pane's local queue only kicks in when there's something to be busy
*about*.

## Resolved Questions (from `ce:brainstorm` research pass)

Code-level evidence gathered for each of the original open questions:

1. **Does codex fire an `[agent]` transcript event at the end of every
   turn?** YES, but it actually fires per *agent message chunk* within
   a turn, not only at turn end. The transcript stream is generated by
   `assistant_message_from_codex/1` (`agent_runner.ex:103-112`), which
   matches `item/completed` notifications with `item.type ==
   "agentMessage"`. A single codex turn can emit multiple agent
   messages (intermediate progress + final answer), each triggering
   a separate `:assistant` transcript event. Option C drains on the
   FIRST one — usually fine, since that's the earliest moment the
   agent is "talking to the operator", but means turns with progress
   messages drain early.
2. **Granularity (streaming chunks vs whole messages)?** Whole messages
   only. The matcher gates on `item/completed`, not on streaming-delta
   methods (`agent_message_delta`, `agent_message_streaming`,
   `agent_message_content_streaming`). `event_humanizer.ex:96` lists
   the streaming variants but `agent_runner.ex` does not surface them
   into transcript events. Safe to drain on every `:assistant`.
3. **Per-agent translation (codex vs claude)?** Mostly handled. For
   codex the dedicated `assistant_message_from_codex` matcher fires.
   For claude, `transcript_event_from/1` falls through to
   `legacy_transcript_event/1` which maps event kinds
   `agent_message | assistant_message | task_finished | task_complete`
   to `:assistant` (`agent_runner.ex:194-204`). **Open sub-question:**
   confirm the claude session driver actually emits one of those
   `event` discriminators on its message events — quick check in
   `lib/symphony_elixir/claude/coding_agent.ex` when implementing.
4. **Pane raw-stdin safety vs claw-code's permission-prompt bug?**
   Non-issue. Symphony's permission prompts are server-side and never
   read pane stdin; the pane's `read_loop` (`conversation.ex:227`)
   only forwards bytes to its own GenServer.
5. **Pane / agent crash recovery?** Mirror queue-adds to per-issue
   log as `[queued] ...` lines via `IssueLog`. If the pane dies, the
   operator can recover by tailing the log. If the agent dies before
   draining, the queue dies with the pane (acceptable for v1).

## Findings that change the design

The research surfaced a much smaller fix that should land *first*:

- **The cancelled-`sleep` bug is one line.** `AgentChat.send/3`
  (`agent_chat.ex:14`) defaults `delivery_policy: :interrupt`.
  `PaneRPC.send_operator_message/2` (`pane_rpc.ex:30`) calls it with
  no opts, so today every pane submit interrupts. Changing the
  default — or having `PaneRPC` pass `delivery_policy: :checkpoint,
  fallback: :queue_next` — eliminates the cancelled-sleep behavior
  without touching the pane UI at all.
- **The orchestrator already supports the right policy.** With
  `:checkpoint + fallback: :queue_next`, messages drain at the next
  notification/tool boundary; when the agent is idle the next
  boundary is the start of the next turn (essentially instant); when
  the agent is running a single long tool (`sleep 300`) the message
  waits until that tool returns.
- **`AgentChat.send` already broadcasts the `:user` transcript event
  on success** (`agent_chat.ex:27-30`), independent of when the agent
  actually reads the message. So the pane's `[user]` echo behavior
  doesn't change at all — the only difference is *when the agent sees
  it*.

This implies a two-step rollout:

1. **Step 1 (one-line fix):** flip the default policy. Solves the
   destructive-interrupt bug for everyone immediately.
2. **Step 2 (visible queue UI, Option C):** add pane-side queue
   rendering + bundle-on-drain. Gives the operator the "I can see
   what's pending" UX.

Step 2 is an enhancement layered on Step 1; it should not block the
Step 1 fix from shipping.

## Missed alternatives surfaced

### Option D — Pure default-policy flip (no queue UI)

Just change `AgentChat.send/3`'s default to `:checkpoint`. No new pane
state, no queue rendering. The operator types, the message goes to the
orchestrator's existing queue, and the agent reads it at the next
checkpoint.

- (+) One-line change. Ships immediately.
- (+) Solves the destructive-interrupt problem completely.
- (−) Operator has no visibility into "is my message pending?" — they
  see their `[user]` echo land in transcript but no signal whether the
  agent has actually read it yet.
- (−) Multiple rapid messages get delivered one-per-checkpoint, not
  bundled. Each is its own agent turn.

**Verdict:** ship as Step 1. Insufficient on its own for the
multi-message-bundle UX, but a strict prerequisite for everything else.

### Option E — Orchestrator-side merged drain

Same UX as Option C but the merging happens in the orchestrator: the
queue holds N pending operator messages, and the `safe_checkpoint_handler`
drains them ALL into one merged `send_operator_message` call when it
fires.

- (+) Pane code stays trivially simple.
- (+) Works the same for any consumer (web UI parity).
- (−) Bigger backend change; touches `agent_queue.ex` and
  `agent_runner.ex`.
- (−) Loses pane-side visibility ("what is queued *right now*") — the
  pane would have to RPC the orchestrator to render the queue.

**Verdict:** worse than Option C for the CLI-only v1. Reconsider when
we add web parity.

## Trade-off matrix

| Axis | A: classifier | B: every checkpoint | **C: after agent msg** | D: policy flip only | E: orchestrator merge |
|---|---|---|---|---|---|
| LoC | ~150 | ~80 | ~60 | ~5 | ~120 |
| Files touched | conversation.ex, viewport.ex | conversation.ex, viewport.ex, pane_rpc.ex | conversation.ex, viewport.ex, pane_rpc.ex | agent_chat.ex *or* pane_rpc.ex | agent_queue.ex, agent_runner.ex, pane_rpc.ex |
| Per-agent (codex/claude) work | classifier per agent | none (uses checkpoint handler) | confirm claude `:assistant` event kind | none | none |
| `sleep 300` behavior | message waits | message waits | message waits | message waits | message waits |
| 3 rapid messages | 3 separate sends if classifier flips | 3 separate sends (one per checkpoint) | **1 merged send** | 3 separate sends | 1 merged send |
| Pane crash | queue lost | nothing to lose | queue lost (mitigated by `[queued]` log mirror) | nothing to lose | nothing to lose |
| Agent crash | queue lost | queue cleared on agent_finished | queue lost | nothing to lose | queue cleared on agent_finished |
| Idle gap detection | needed | not needed | not needed | not needed | not needed |
| Mental model | "depends on classifier state" | "wait briefly, message gets in soon" | "queued until agent next replies" | "submit and wait" | "queued until agent next replies" |

## Race conditions to handle in Option C

1. **Double-drain on rapid `:assistant` events.** If the agent emits
   two assistant messages back-to-back and the operator queued
   something between them, the queue could drain twice. Mitigation:
   the pane atomically clears its queue before issuing the
   `send_operator_message` RPC.
2. **Submit while draining.** If the operator hits Enter while an
   in-flight `send_operator_message` RPC is mid-flight, the new line
   should land in a fresh queue (not be silently merged into the
   already-submitted batch).
3. **Drain on stale agent message.** If the pane was just opened and
   reloads history (including past `:assistant` events from
   `IssueLog`), it must NOT drain the queue on those historical
   events. Mitigation: only drain on events that arrive *after* the
   pane finished its initial history load.

## Out of scope for v1

- Backend `AgentQueue` policy changes (Option C works with existing
  `:checkpoint` policy)
- Web UI parity
- Cross-pane visibility of one pane's queue
- Editing a queued line after it's been submitted
- Up/down history navigation through past queue submissions

## Recommendation (updated)

Two-step rollout:

- **Step 1 — flip the default delivery policy** (Option D). Either
  change `AgentChat.send/3`'s default from `:interrupt` to
  `:checkpoint`, or have `PaneRPC.send_operator_message/2` pass
  `delivery_policy: :checkpoint, fallback: :queue_next`. This is a
  one-line fix that solves the destructive `sleep 300` interruption
  for every consumer. Should ship on its own first.
- **Step 2 — add pane-side queue with drain-after-agent-message**
  (Option C). Implement the queue rendering, the local bundling, and
  the `:assistant`-event drain trigger. Layered on top of Step 1.

Skip Options A (classifier — too heuristic), B (every-checkpoint —
loses bundling), and E (orchestrator merge — too much for CLI-only
v1).

Force-send via `Shift+Enter` can be added in v2 if operators actually
need to override the queue and interrupt.
