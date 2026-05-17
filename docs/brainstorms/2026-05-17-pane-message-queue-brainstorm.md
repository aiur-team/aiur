---
date: 2026-05-17
topic: Pane-side message queue with instant-vs-queued submit modes
branch: feat/cli-pane-rearchitecture
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
an explicit instruction. The user wants two distinct submit experiences
co-existing in one composer.

## Requirements

1. **Mode A — Instant submit.** When the agent is "between turns" (idle
   waiting for the next operator message, or just finished a response
   and not running any tool), Enter posts immediately. This is today's
   path; only the trigger logic changes.
2. **Mode B — Pane-queued submit.** When the agent is mid-tool-call
   (shell command running, file edit in progress, model is still
   streaming a reply), pressing Enter does NOT interrupt. Instead the
   message appears in a queue section *above* the composer input, the
   composer clears, and the operator can keep typing more messages —
   each one stacks below the previous queued line.
3. **Queue drain.** When the agent finishes its current activity and is
   ready to read the next operator message, the entire queue drains as
   one bundled message to the agent, joined with blank lines so it
   reads as a single multi-paragraph turn. The queue lines also enter
   the transcript as `[user]` events at drain time (not before).
4. **Visible queue lines.** The queue renders directly above the input
   row, styled like the input background but with a slightly different
   tint (or a small left gutter marker) so the operator sees what is
   pending. Queue lines wrap the same way as transcript user lines.
5. **No silent loss.** If the agent crashes or the pane closes before
   drain, queued lines must persist to the per-issue log so the
   operator can recover them.

## Key Decisions

### Trigger for Mode A vs Mode B

The choice is driven by **agent activity state**, not by user
configuration. The pane already receives lifecycle events:

- `[cmd] $ ...` events without a paired exit → agent is running a
  command.
- `[agent] ...` events stop arriving for >N seconds while the model is
  streaming → agent is thinking.
- A `task.todo` or "ready" alert / a paired `[cmd] $ ... [exit=N]`
  followed by an `[agent]` text response → agent is idle.

Track a single `agent_state ∈ {:idle, :busy}` value in the
`Conversation` GenServer, recomputed on each PubSub event. The
heuristic for `:busy`:

- `:command` event with no matching `[exit=N]` → `:busy`
- `:assistant` event within the last 2s with no follow-up `[exit=...]`
  pending → debounce; treat as `:idle` after 2s of silence
- Otherwise → `:idle`

A small idle-debounce (e.g. 1500 ms) avoids the bouncy case where the
agent is just between two quick tool calls.

### Where the queue lives

Option 1 — purely in the `Conversation` GenServer:
- Simpler: no orchestrator changes.
- Lost if the pane crashes.
- But: pane crashes are rare and the per-issue log already mirrors the
  operator's pre-drain queue if we log queue-add events as
  `[queued] ...` lines.

Option 2 — in the orchestrator's `AgentQueue` with a new
`:queue_only_until_drain` policy:
- Survives pane crashes naturally.
- But: requires new orchestrator state, new policy code, and the pane
  has to re-query "what's queued for me right now?" on open.

**Recommendation: Option 1** for the first cut, with a `[queued]`
mirror line written into the per-issue log on every queue-add so the
operator can recover by tailing the log if the pane dies before drain.

### Drain semantics

Two sub-options:

a. **Single bundled message.** Join all queue lines with `\n\n` and
   submit one operator message. The agent reads one turn that contains
   N paragraphs. This is closest to what a human reviewer would do.
b. **Multiple ordered submits.** Submit each queue line as its own
   operator message in order, with a small delay so the agent sees
   them as N distinct turns.

(a) is the right default — it matches how the user thinks (they were
typing one continuous stream of thought, just over wall-clock seconds)
and avoids triggering N turn-by-turn agent responses.

### Submit-bypass for forced interrupt

The user should still be able to actually interrupt the agent (e.g.
when the agent is stuck or going the wrong way). Reserve a modifier
keystroke — `Shift+Enter` to send instantly even while busy. The help
row gets updated:

```
 Ctrl+C close   Tab cycle   Shift+Enter force-send
```

(Or vice versa: bare Enter always queues, Shift+Enter always sends. The
"smart" mode A/B is the default; modifier overrides it.)

## Scope Boundaries

### In scope

- `Conversation` GenServer state for queue + agent_state
- Viewport rendering of a queue section above the composer
- PubSub-driven agent-state classifier
- Drain logic that bundles queued lines and forwards via existing
  `PaneRPC.send_operator_message`
- Help-row update for the new keystroke
- Per-issue log mirroring of queue-add events

### Out of scope

- Backend `AgentQueue` policy changes
- Web UI parity
- Cross-pane visibility of one pane's queue
- Editing a queued line after it's been submitted (operator deletes
  with backspace on the queue itself — separate future work)

## Open Questions

1. **What exact signals classify busy/idle reliably?** Codex emits
   different events than Claude. Need a single classifier that handles
   both. Look at `AgentRunner` event normalization.
2. **What's the longest reasonable idle debounce?** 1500 ms feels too
   tight if the agent does a long single-line edit; 5000 ms feels too
   loose if the user is replying quickly.
3. **Should the visible queue echo into the transcript on add, or only
   on drain?** Drain-only is cleaner for the agent (no duplicate
   `[user]` rendering) but means the transcript jumps when the queue
   is finally drained. Suggest: queue-only-visible, then a single
   transcript event on drain with the merged body.
4. **How does Ctrl+C interact with a non-empty queue?** Suggest the
   pane prompts "drop N queued messages?" once before exiting.

## Notes for Planning

- This sits on top of the existing pane rearchitecture
  (`feat/cli-pane-rearchitecture`) and does not need to wait on the
  ongoing visual cleanup (tags-above-body, arrow keys, user margin).
- The classifier is the riskiest piece. Implement it as a pure
  function over the event stream first, then wire it into the
  `Conversation` state machine, so it can be unit-tested with
  recorded event fixtures from issue 25.
