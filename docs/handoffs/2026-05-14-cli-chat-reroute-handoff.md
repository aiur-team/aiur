# CLI Chat Reroute Handoff

Created: 2026-05-14
Branch: `symphony/agent-pubsub`

## Why This Handoff Exists

The current CLI chat implementation has been debugged through several small fixes without resolving the core operator experience. Repeated cycling indicates the checkpoint-first model is the wrong abstraction for this problem. This handoff is intended to let a new agent restart from the revised product model instead of continuing to patch the old one.

## Revised Direction

The new source of truth is:

- `docs/brainstorms/2026-05-14-cli-pending-input-and-operator-delivery-requirements.md`

That requirements doc changes the interaction model in two key ways:

1. Typing should be rendered in a separate composer layer, decoupled from the dashboard refresh/render loop.
2. Operator message delivery should be interrupt-first. The visible grey queued-input section stays, but only as a short-lived honest buffer while the app immediately pings the agent.

## What The User Reported Most Recently

1. Typing still lags and fills in periodically instead of feeling completely real-time.
2. Pressing Enter still causes the log pane and top nav to disappear briefly before returning.
3. Queued input is not draining reliably into the canonical log.
4. In a paused case, sending `"test"` logged the message twice and left it stuck in pending.

## Important Interpretation

These are not just edge-case bugs. They point to a model mismatch:

- The current implementation still assumes the main dashboard render path owns the composer experience.
- Delivery is still conceptually queue/checkpoint driven, even where we tried to make it feel faster.
- Canonical log confirmation is not well-defined enough for pending-state removal.

## Useful Learnings From The Abandoned Iteration

The last implementation pass explored several ideas against the older checkpoint-first model. The next agent should not copy that code blindly, but these learnings are worth preserving:

- Cached log content helped typing responsiveness somewhat, but as long as the composer still depended on the dashboard render path, typing could still visibly batch.
- Local pending-preview reconciliation based only on orchestrator queue state was not enough. Pending removal needs a stronger acceptance signal tied to actual delivery/log confirmation.
- Synthetic operator-log insertion reduced the "message never appears in log" failure mode, but it also introduced duplicate/confirmation complexity. The next design should decide this path deliberately rather than as a patch.
- Queue/checkpoint delivery logic became hard to reason about across normal turns, paused turns, and resume paths. This reinforced the need to move to interrupt-first semantics instead of improving the old timing model further.

## Recommendation For The Next Agent

Do not continue from the current implementation by stacking more small fixes onto the same model.

Instead:

1. Re-plan from the revised brainstorm doc.
2. Treat the prior checkpoint-first implementation as discarded exploration, not as the implementation baseline.
3. Make an explicit architecture choice for the composer:
   - separate terminal layer / direct input rendering
   - or equivalent decoupled rendering path that avoids full dashboard redraw on each local edit
4. Make an explicit transport choice for interrupt-first delivery:
   - true `turn/interrupt` + send
   - or pause-send-resume
   - or equivalent immediate delivery path
5. Define a single confirmation rule for queue drain:
   - what exact event or acknowledgement moves a message from grey queued-input to canonical log

## Specific Things To Preserve

- Keep the grey queued-input section in the UI.
- Do not append operator messages directly to the main chat log on Enter.
- Keep backend queueing available as a fallback/durability mechanism if needed.
- Keep PubSub out of scope for this branch.

## Specific Things To Challenge

- Any logic that waits for a passive "opportune checkpoint" as the normal delivery path.
- Any approach that requires the whole dashboard body to re-render for local typing.
- Any pending-removal logic that relies only on eventual snapshot reconciliation without a strong acceptance signal.

## Branch Remote State

This branch now contains the revised requirements doc and this handoff note so a new agent on another machine can restart from the new model without needing any local-only context.
