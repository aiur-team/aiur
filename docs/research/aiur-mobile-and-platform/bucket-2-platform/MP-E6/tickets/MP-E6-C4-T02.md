---
ticket_id: MP-E6-C4-T02
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Read-port behaviours and host wiring for worker targets
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E4-C2-T01, MP-E6-C11-T01]
prior_units: []
prior_boundaries: [VOX, DEC, PRJ]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T02 — Read ports

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4.
- **User value:** the assistant knows what the worker is doing (recent conversation, open
  Commands, run status) without the voice component depending on orchestrator internals —
  so it stays reusable and an absent part degrades to a stated gap, not a crash.
- **Deliverable (PROPOSED):** behaviours `Ports.ConversationRead`, `Ports.CommandRead`,
  `Ports.StatusRead`, `Ports.ExecutorRead` in `src/lib/aiur/voice_conversation/ports/`, and
  host implementations `Aiur.VoiceConversation.Host.*` wired by the composition root
  (MP-R1) or app env `:voice_conversation_ports`.
- **Non-goals:** Executor implementation (C4-T06); context formatting (C4-T03).

## Dependencies and blockers

- **Predecessors:** C4-T01; MP-E4-C2-T01 (`list_entries/2`; every call passes `principal:` (conversations contract §7; a call without it raises `ArgumentError`, security M5)) — optional: without it the
  conversation port uses `LiveConversation`.

## Verified starting point (base `45a290e3`)

| Source | API |
| --- | --- |
| Bounded live conversation | `Aiur.LiveConversation.snapshot/2` → `%{messages: [%{id, role, title, body, occurred_at, observed_at}], state, freshness, truncated?, …}` (`live_conversation.ex:23-47,96-97`); 80 messages / 64,000-byte cap (`live_conversation/retention.ex:6-8`) |
| Full history (future) | `list_entries(ConversationRef, principal: p, tail: true, limit: n)` and `after: pos`; `principal:` required (`contracts/conversations-transcripts-anchors.md` §7) — resolves RQ-E6-8 |
| Commands | `Aiur.DecisionStore.get/2`, `list/1` (`decision_store.ex:387-395`), struct fields `decision_status`, `version`, `options`, `question`, `ticket.identifier` (`decision.ex:100-125,168-184`) |
| Status | `Aiur.Orchestrator.StatusReport.snapshot_api/2`, `status_api/2` (`orchestrator/status_report.ex:112-124`) |

## Chosen design

```elixir
@callback recent_messages(target, limit :: pos_integer()) ::
            {:ok, [%{role, text, at}], meta :: %{source: :journal | :live, complete?: boolean}} | {:error, :unavailable}
@callback open_commands(target) :: {:ok, [%{decision_id, version, question, options}]} | {:error, :unavailable}
@callback status(target) :: {:ok, map(), observed_at :: DateTime.t()} | {:error, :unavailable}
@callback target_alive?(target) :: boolean() | :unknown
```

- Worker targets: conversation via E4 `list_entries(ref, principal: :internal, …)` when its
  capability is available (`:internal` only because this text goes no further than the
  provider path, which runs `SecretRedactor` in C4-T03; anything rendered back to a device
  client reads with `principal: {:device, device_id}`, masked; arity stays `list_entries/2`),
  else `LiveConversation.snapshot/2` (meta `source: :live, complete?: false`); commands =
  `DecisionStore.list/1` filtered to the ticket and answerable statuses; status from
  `StatusReport.snapshot_api/2` filtered to the ticket.
- Every port call has a 2 s timeout and rescues exits to `{:error, :unavailable}`.
- A port that is not configured is `nil`; the session records "X unavailable".

## Implementation steps

1. Behaviours; 2. host implementations; 3. wiring; 4. tests with stub ports and a
   `DecisionStore` started on a temp dir.

## Non-happy paths

- Orchestrator down → status `:unavailable` (never an empty map that reads as "idle").
- E4 absent → live source with `complete?: false`, surfaced in the context header.

## Compatibility and rollout

Internal. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "worker open commands are filtered to the ticket and answerable statuses" | two decisions, one other ticket, one resolved → one returned |
| "an orchestrator exit is unavailable, not an empty status" | stub exits → `{:error, :unavailable}` |
| "without E4 the live snapshot is used and marked incomplete" | meta `source: :live, complete?: false` |
| "target_alive? is :unknown when the status port fails" | not `false` |
| "with E4, the worker port reads history with `principal: :internal`" (security M5) | fake History records the `principal:` opt; a call without it raises `ArgumentError` in the fake, as in the contract |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/ports_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Return `{:ok, %{}}` on orchestrator exit: the unavailable test fails.

## Completion and handoff

- [ ] Ports and host wiring for worker targets.
- **Dependents:** C4-T03, C4-T05, C4-T06, C5-T01, C5-T05.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- **Re-scoped.** The four read-port behaviours (`ConversationRead`, `CommandRead`,
  `StatusRead`, `ExecutorRead`) are replaced by the host ports `BriefingSource` (with
  `details/3` for conversation, PR, CI and plan sections) and `CommandSource` (plan §17.4).
  The behaviours are defined in C11-T01.
- This ticket now builds the **aiur implementations**: `Aiur.VoiceConverse.Host.BriefingSource`
  for worker targets (E4 `list_entries(…, principal: :internal)` or `LiveConversation` for
  `details("conversation")`; `StatusReport` for status) and
  `Aiur.VoiceConverse.Host.CommandSource` (DecisionStore reads filtered to the ticket). The
  2 s timeout and the "unavailable, not empty" rule are now enforced by the core caller.
  Keep the aiur-side tests: ticket filtering, `principal: :internal`, and `:unknown` liveness.
- Added predecessor: MP-E6-C11-T01.
