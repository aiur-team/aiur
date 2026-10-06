---
ticket_id: MP-E6-C4-T02
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Read-port behaviours and host wiring for worker targets
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E4-C2]
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

- **Predecessors:** C4-T01; MP-E4-C2 (`list_entries/2`) — optional: without it the
  conversation port uses `LiveConversation`.

## Verified starting point (base `45a290e3`)

| Source | API |
| --- | --- |
| Bounded live conversation | `Aiur.LiveConversation.snapshot/2` → `%{messages: [%{id, role, title, body, occurred_at, observed_at}], state, freshness, truncated?, …}` (`live_conversation.ex:23-47,96-97`); 80 messages / 64,000-byte cap (`live_conversation/retention.ex:6-8`) |
| Full history (future) | `list_entries(ConversationRef, tail: true, limit: n)` and `after: pos` (`contracts/conversations-transcripts-anchors.md` §7) — resolves RQ-E6-8 |
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

- Worker targets: conversation via E4 `list_entries` when its capability is available,
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
