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
  "result": { "id": 4287, "topic": "ticket.42.agent.progress.tests-green" }
}
```

Or, on failure:

```jsonc
{ "error": { "message": "`emit_event.name` must match the agent vocabulary: ...", "examples": [...] } }
```

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

For a declared blocker, `ticket.N.branch.push` is an action cue. Load
`stub-then-fetch.md`, fetch `origin/aiur/N`, inspect the pushed diff/exports, and
stack on the branch when it contains the needed API. Treat an irrelevant push and
a usable push differently: record the concrete inspected reason if it is still
unusable; remove any temporary stub and rebase/merge when it is usable.

So you only need explicit `aiur_subscribe` for **watch use cases** — e.g., tracking a sibling ticket that isn't a blocker.

## Don't do

- Don't bind a pattern just to read it once. Subscriptions are for ongoing watch; if you want a one-time read, `aiur --logs <id>` is the right tool.
- Don't bind `#` (everything) — you'll drown in noise.
- Don't pair `aiur_declare_blocker(N)` with `aiur_subscribe("ticket.N.#")` — the blocker declaration handles the auto-subscription already.
