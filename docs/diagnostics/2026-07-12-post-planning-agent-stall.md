# Post-planning agent stall diagnosis

Issue: #1024

Implementation follow-up: #1041

## Conclusion

The observed stall is primarily an agent/prompt-contract deadlock at the
planning-to-work boundary, not a missing normal-turn scheduler.

The Compound Engineering `ce-plan` workflow requires an explicit user choice
after planning and says not to begin follow-up work without another user prompt.
Aiur's autonomous continuation prompt says to keep working, but it does not say
that an active build/rework ticket authorizes the recommended `ce-work` handoff
or suppresses interactive skill menus. The model therefore finishes planning,
asks or waits for implementation direction, and can repeat that terminal
planning behavior on continuation turns. An operator `message` works because it
is the explicit user directive the skill contract requires.

`max_turns: 12` and `stall_timeout_ms: 3600000` amplify the problem. They bound
how many non-productive continuation turns can occur and how long a silent live
runner remains visible, but neither creates the planning boundary deadlock.

## Evidence

### #987: planning contract reproduced in the transcript

The app-server transcript at
`~/code/aiur-workspaces/aiur-team/aiur/987/logs/agent.ndjson` records:

- 13:45-14:35Z: repeated progress turns remain at 10-20% in `plan`.
- 14:35:32Z: the agent reports `Reviewed plan is published and awaiting
  implementation direction`.
- 14:37:51Z, 14:38:34Z, and 14:39:02Z: completed turns are followed by more
  turns that repeat the same waiting-for-direction state.
- 14:44:32Z: after consuming a provider contract, it again reports `awaiting
  implementation direction`.
- 14:46:57Z: that turn completes. No implementation turn begins until a new
  session starts at 15:52:04Z, 65m07s later.
- 15:56:02Z: the new turn finally reports `Starting implementation from the
  reviewed OCC plan`; `phase.work.start` follows at 15:59:16Z.

This matches `ce-plan`'s handoff rules exactly: it presents an interactive
choice whose recommended option is `Start /ce-work`, and its `Done for now`
route says not to start follow-up work without an explicit further user prompt.

The 65-minute gap also matches the configured 60-minute stall watchdog plus
poll/restart overhead. The last completed turn was not a long-running command
or load-throttled implementation; it explicitly ended at a plan handoff.

### #980: resume and message are different inputs

The #980 transcript records three resume attempts:

- session start 15:33:16Z -> `worker_paused` 13s later;
- session start 15:38:46Z -> `worker_paused` 11s later;
- session start 15:38:58Z -> `worker_paused` 23s later.

Each pause says `Agent paused by operator`. A later session starts at 15:47:16Z;
after the operator message, real turns begin and the agent reports reworking the
review findings. Commits follow at 16:17Z and 16:23Z local time.

The code explains the behavioral delta. `resume` sends only a
`{:resume_agent, request_id}` control message. An operator message both resumes
a paused entry and enqueues text, then broadcasts an `agent_queue_updated` wake.
The former supplies no new task instruction; the latter does. A resumed thread
whose last durable instruction was a terminal skill handoff can therefore
re-pause/end again, while `message` provides the missing explicit authorization.

## Hypotheses

1. **Generic daemon re-trigger gap: refuted.** Normal completed turns recurse
   while the issue is active in `AgentRunner.TurnLoop`. When a runner task exits
   normally, `Orchestrator.RetryEngine` also schedules a one-second active-state
   continuation check. There are two continuation paths, not zero.
2. **Completion-signal wedge: confirmed, narrowed.** The wedge is not the event
   tool call itself. The transcript shows those calls completing. The agent
   repeatedly returns to the terminal `ce-plan` handoff and waits for direction.
3. **Turn-budget exhaustion: contributing, not root cause.** The cap can end a
   run after repeated planning-only continuations, but the transcript shows the
   wrong phase decision before any cap consequence. Raising the cap would buy
   more repetitions, not authorize implementation.
4. **`resume` no-op: partly confirmed.** Resume does wake the parked runner, so
   it is not a transport no-op. It does not enqueue a directive, which makes it
   semantically insufficient for a thread parked at an interactive skill
   handoff. Message resumes and adds work, so it succeeds.

## Causal chain

1. An active build ticket selects `ce-plan`.
2. `ce-plan` finishes the plan and requires a user-selected next action.
3. The agent ends its turn at `awaiting implementation direction`.
4. Aiur sees an active issue and sends generic continuation guidance.
5. The guidance does not explicitly resolve the skill's user-choice boundary,
   so the resumed model preserves the handoff instead of selecting `ce-work`.
6. Repeated completions consume turn budget or the live entry becomes silent.
7. The one-hour watchdog eventually restarts a silent working entry; deliberately
   paused entries are excluded and wait indefinitely for resume/message/event.
8. A direct operator message supplies explicit implementation authorization and
   immediately starts productive work.

## Recommended fix

Make autonomous pipeline authority explicit in the Aiur prompt contract:

- In an active Aiur build/rework ticket, a completed planning phase authorizes
  the agent to choose the recommended `Start /ce-work` route without waiting for
  another operator prompt.
- Interactive handoff menus from phase skills must not terminate an autonomous
  ticket turn; select the recommended next phase unless a material operator
  decision is actually required.
- Add the same wording to cold-start, in-process continuation, and resumed-thread
  prompts so restart behavior cannot regress.

Add defense in depth separately:

- Surface `last_turn_completed_at`, runner turn number/cap, and parked reason in
  status/logs so planning deadlocks are immediately attributable.
- Treat a completed turn on an active ticket that makes no workspace progress as
  a short-interval continuation concern rather than waiting 60 minutes.
- Keep `message` and `resume` distinct, but offer `resume --continue` (or make the
  operator-facing resume command enqueue a standard continue directive) when
  the desired UX is “wake and continue the ticket.”
- Do not merely raise `max_turns`; that masks the prompt conflict.

## Regression coverage

Add a prompt-contract test that asserts cold, continuation, and resumed prompts
all explicitly authorize the planning-to-work transition for active autonomous
tickets. Add an integration test with a fake agent that ends turn 1 at a plan
handoff: turn 2 must receive the autonomous phase-transition directive and begin
work without an operator message. A separate pause/resume test should prove that
plain resume preserves its control-only semantics while resume-with-continue
enqueues exactly one directive.
