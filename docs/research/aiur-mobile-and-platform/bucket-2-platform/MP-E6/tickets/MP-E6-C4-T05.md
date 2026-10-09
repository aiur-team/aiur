---
ticket_id: MP-E6-C4-T05
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Live, non-interrupting context updates from the event bus during a conversation
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E6-C4-T03, MP-R2-C5-T01, MP-R2-C5-T03]
prior_units: []
prior_boundaries: [VOX, EVT]
prior_features: []
prior_findings: []
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T05 — Live context updates

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4.
- **User value:** if the agent opens a new Command, finishes a phase or a Command is answered
  elsewhere while the operator is talking, the assistant knows, without interrupting itself.
- **Deliverable:** `Aiur.VoiceConversation.LiveContext` (PROPOSED) — per session, subscribes
  to `Aiur.Events.Exchange` patterns for the target, turns relevant events into one-line
  updates, records each as a `context` record (fsync) and calls
  `Provider.send_context/2` (`contextual_update`, non-interrupting). Also feeds the
  `events` block of C4-T03 (last 10 milestones) and marks drafts stale (C5-T02).

## Dependencies and blockers

- **Predecessors:** C4-T01, C4-T03; MP-R2-C5-T01 (topic catalog) and MP-R2-C5-T03 (registers the E1/E2/E7
  topics, RC-08). R2-C5 ships at the start of wave 4 (RC-31). Patterns below use only catalogued topics.

## Verified starting point (base `45a290e3`)

- `Aiur.Events.Exchange.subscribe(pattern, server)` with `*`/`#` wildcards; delivery is
  `send(pid, {:event, event})` fire-and-forget (`events/exchange.ex:1-38,69-77,92-112`).
- Exchange is supervised in the app (`aiur.ex` child `{Aiur.Events.Exchange, name:
  Aiur.Events.Exchange}`, near `:355-360`).

## Chosen design

| Target | Patterns | Kept events → update text |
| --- | --- | --- |
| worker `ticket` | `ticket.<id>.#` | `decision.human-needed` (E2) → "New Command: <question>"; Command resolved → "Command <id> resolved" (+ mark draft stale); PR opened/merged/closed; phase change; agent ended → session `target_gone` |
| executor | `system.#`, `executor.#` | blocker counts, build-order progress (`system.build_order.<root>.progress`, RC-08), Executor state changes |

- Rate limit: at most one `contextual_update` per 5 s per session (coalesce; the transcript
  records every event even when coalesced).
- Update text passes `SecretRedactor` (C4-T03 rule).
- Unknown event shapes are ignored (bus payloads are opaque to the exchange, `:47-51`).

## Implementation steps

1. Subscriber process linked to the session; pattern table per target kind.
2. Event → text mappers; coalescing; transcript append then provider send.
3. Tests with a private Exchange instance (`server` argument).

## Non-happy paths

- Event burst (e.g. reconnect replay) → coalesced; never interrupts the assistant.
- Exchange not running → no live updates; `gaps` gets "Live updates unavailable".

## Compatibility and rollout

Internal. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "a new Command on the ticket reaches the provider as a contextual update" | FakeProvider `send_context` once; transcript has the `context` record first |
| "events for other tickets are ignored" | none sent |
| "a burst is coalesced to one update per 5 s" | injected clock |
| "a resolved Command marks its open draft stale" | draft status `stale` (with C5-T02) |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/live_context_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Subscribe to `ticket.#` instead of `ticket.<id>.#`: the "other tickets"
test fails.

## Completion and handoff

- [ ] Live updates with coalescing and stale marking.
- **Dependents:** C5-T02, C5-T05.

## Amendment 2026-10-08 — fast voice over a slow agent

Source: [../realtime-convo-research.md](../realtime-convo-research.md) (Kevin's request of
2026-10-08: voice with high-effort agents is "extremely slow and broken up"). Context-handoff
requirement: the voice assistant must be able to answer from a current briefing in about one
second, without stopping or waiting for the coding agent.

- Also subscribe to `ticket.<id>.agent.progress.status` (MP-E6-C10-T01). Each relevant event
  recomputes the status card (MP-E6-C10-T02) and sends only the **changed lines** as the
  `contextual_update`.
- A consult answer, a side-query answer or a refreshed note is **announce-worthy**: the
  session asks the provider to speak it at the next pause (provider event "say when idle",
  MP-E6-C2-T01 amendment), not only to hold it silently in context.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.LiveContext`. It subscribes through `BriefingSource.subscribe/2`,
  `AgentChannel.subscribe/2` and `CommandSource.subscribe/2`, not through
  `Aiur.Events.Exchange`. A port that returns `:unsupported` leads to a refresh on tool calls
  only (the old "without R2" fallback).
- The aiur implementations subscribe to `ticket.<id>.*` / `executor.*` on the Exchange and
  push a new `%Briefing{}`. The 5 s coalescing and the `announce` rules stay in the core.
