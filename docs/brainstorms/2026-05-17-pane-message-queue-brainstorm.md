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

## Open Questions for the next research pass

These need code-level confirmation before we commit to Option C:

1. **Does codex fire an `[agent]` transcript event at the end of every
   turn?** Need to confirm the PubSub stream the pane sees actually
   contains a reliable "agent just said something" signal — vs only
   firing for some methods.
2. **What's the granularity of `:assistant` events?** Streaming chunks
   vs whole messages. Draining on every chunk would over-fire; need to
   drain only on full message boundaries.
3. **Does the per-agent translation (codex vs claude) matter for
   Option C?** If both emit `:assistant` role events on the same
   normalized topic, Option C works for both; if not, we may need to
   gate on `turn/completed` or `agent_message` specifically.
4. **What does claw-code's permission-prompt-eats-stdin behavior teach
   us about pane safety?** They have a known bug where typed input
   can become a permission answer. Our pane is independent of
   permission prompts (which run on the agent process, not the pane),
   but worth confirming our raw-stdin reader has no analogous footgun.
5. **What happens to the pane's local queue if the agent crashes /
   pane is closed mid-queue?** Mirror to per-issue log on add is
   probably sufficient, but verify recovery flow.

## Out of scope for v1

- Backend `AgentQueue` policy changes (Option C works with existing
  `:checkpoint` policy)
- Web UI parity
- Cross-pane visibility of one pane's queue
- Editing a queued line after it's been submitted
- Up/down history navigation through past queue submissions

## Recommendation

Implement **Option C (drain after agent message)** for v1. It's the
smallest change, uses existing PubSub plumbing, handles the
`sleep 300` case naturally, and has the clearest UX semantics. Force-
send via `Shift+Enter` can be added in v2 if operators actually need
it.
