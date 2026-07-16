# Aiur Events — Emit and subscribe

## `emit_event(name, message, payload?)`

```jsonc
{
  "name": "progress.tests-green",
  "message": "All 47 tests green on aiur/42",
  "payload": { "ticket": 42, "test_count": 47 }   // optional
}
```

Validates that `name` is in the allowlist (`event-taxonomy.md`). Returns:

```jsonc
{
  "ok": true,
  "name": "progress.tests-green",
  "message": "All 47 tests green on aiur/42",
  "result": {
    "status": "pending",
    "topic": "ticket.42.agent.progress.tests-green"
  }
}
```

`pending` means Aiur accepted the event for keyed background processing. No
event ID exists at admission time; publication assigns it later. A terminal
background failure is written to the ticket/daemon logs and does not rewrite
the already-returned tool response.

Or, on failure:

```jsonc
{ "error": { "message": "`emit_event.name` must match the agent vocabulary: ...", "examples": [...] } }
```

### Acknowledging a delivered Decision answer

A durable answer message includes a Decision ID, the request version it
answered, and an action ID. Treat the message as replayable and do not apply it
twice. Once observed, acknowledge that exact action:

```jsonc
{
  "name": "decision.acknowledged",
  "message": "Applying the selected option",
  "payload": {
    "decision_id": "dec_abc123",
    "action_id": "act_def456",
    "expected_version": 2
  }
}
```

After the governed work is complete, emit `decision.resolved` with the same
three fields. These two exact names go through the durable DecisionStore, not
the generic event publisher. An exact retry returns `duplicate`; a wrong
ticket, action, or version is rejected. Queue delivery or turn completion does
not acknowledge a Decision for you.

## `aiur_subscribe(topic_pattern)`

Persistent — the subscription survives BEAM restarts. Use AMQP topic-exchange wildcards:

- `*` — exactly one segment
- `#` — zero or more segments

Examples:

```jsonc
{ "topic_pattern": "ticket.42.#" }              // everything about ticket 42
{ "topic_pattern": "*.*.branch.push" }          // any push on any ticket
{ "topic_pattern": "ticket.42.agent.decision.*" } // every decision from ticket 42
```

Returns `{ "ok": true, "topic_pattern": "ticket.42.#" }`.

## `aiur_unsubscribe(topic_pattern)`

Exact-match removal. No-op if the pattern wasn't subscribed.

## Default subscriptions (you don't subscribe to these explicitly)

When you start working on a ticket, Aiur automatically subscribes you to:

- `system.<default-branch>.branch.push` — pushes to the repo's default branch
- (After `aiur_declare_blocker(N)`:) a useful subset of `ticket.N.*` events — the blocker's progress, decisions, branch pushes, and unblock signals

For a declared blocker, `ticket.N.agent.unblocked` is the readiness signal that
resumes a parked consumer through the mid-turn checkpoint drain. Load
`stub-then-fetch.md`, then use the latest `ticket.N.branch.push` payload only to
fetch and inspect its validated ref (never a guessed `origin/aiur/N`; use
`scripts/resolve-ticket-branch N` when no event ref is available). Do not infer
readiness from `branch.push` alone. Record the concrete inspected reason if the
explicitly-unblocked dependency is still unusable; otherwise remove any
temporary stub and stack on the blocker branch.

`blocked` and `unblocked` are required single-attempt, fire-and-forget emissions:
enqueue each once and continue without waiting, polling, or retrying.

So you only need explicit `aiur_subscribe` for **watch use cases** — e.g., tracking a sibling ticket that isn't a blocker.

## Don't do

- Don't bind a pattern just to read it once. Subscriptions are for ongoing watch; if you want a one-time read, `aiur --logs <id>` is the right tool.
- Don't bind `#` (everything) — you'll drown in noise.
- Don't pair `aiur_declare_blocker(N)` with `aiur_subscribe("ticket.N.#")` — the blocker declaration handles the auto-subscription already.
