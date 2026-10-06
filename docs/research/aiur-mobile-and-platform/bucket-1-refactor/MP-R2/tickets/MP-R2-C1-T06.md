---
ticket_id: MP-R2-C1-T06
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Record today's outbound dependencies of the event-bus members as a shrinking allowlist
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U7, U8]
prior_boundaries: [BUS #10, ORC #12, GHD #8, RUN #18, K #1, signal port #11]
prior_features: [MP-R1 (component map, checker)]
prior_findings: []
size_owner: n/a (test-only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T06 — Boundary baseline (ratchet allowlist)

## Identity and outcome

- **Bucket 1, MP-R2, C1, T06.**
- **Value.** Each C2 seam ticket must prove that it removed one edge. This ticket
  records every forbidden edge that exists today, with the ticket that removes it,
  in a test that fails both when a new edge appears and when a removed edge is
  still listed.
- **Deliverable.** `src/test/aiur/events/bus_boundary_test.exs` (PROPOSED).
- **Non-goals.** It is not the long-term gate. C4-T03 moves these rules into MP-R1's
  `scripts/check-components.py` (MP-R1-C1) and deletes this test. No production
  change.

## Dependencies and blockers

- DESIGN-R2 §1. Concurrent with other C1 tickets.
- Does not wait for MP-R1-C1 (RC-11 precedent: a feature may ship its own
  source-scan test until R1's checker exists).

## Verified starting point (45a290e3)

Members (MP-R1 `component-map.md` event-bus row plus `debug_log.ex`, see
CONTRACT-REQUESTS): `src/lib/aiur/events/{exchange,topic,publisher,id_generator,subscription_store,subscription_store_supervisor,universal_subscriptions,agent_subscription_policy,debug_log}.ex`
and `src/lib/aiur/ticket_observation.ex`.

Outbound references to non-member `Aiur*`/`Phoenix.PubSub` modules, computed from
code with docs and comments stripped:

| Member | Reference | Evidence | Kernel/config (allowed) or edge to remove | Removed by |
| --- | --- | --- | --- | --- |
| publisher.ex | `Aiur.GitHub.AgentMarker`, `Aiur.GitHub.Config` | `publisher.ex:42-43,405-465` | remove | C2-T06 |
| publisher.ex | `Aiur.GitHub.ResourceStore` | `:44,236-246` | remove | C2-T06 |
| publisher.ex | `Aiur.Webhooks` | `:46,171-180` | remove | C2-T06 |
| publisher.ex | `Aiur.IssueLog` | `:355` | remove | C2-T03 |
| id_generator.ex | `Aiur.Executor.StatePaths`, `Aiur.LaunchStateAdoption` | `id_generator.ex:64-66,295,333` | remove | C2-T07 |
| id_generator.ex | `Aiur.Config.Paths`, `Aiur.JsonStore` | `:63,65` | allowed (kernel/config) | — |
| subscription_store.ex | `Aiur.Orchestrator` | `subscription_store.ex:594-610` | remove | C2-T01 |
| subscription_store.ex | `Aiur.Alerts` | `:507-513` | remove | C2-T01 |
| subscription_store.ex | `Aiur.IssueLog` | `:424,449` | remove | C2-T03 |
| subscription_store.ex | `Aiur.Config.Paths`, `Aiur.JsonStore` | `:65,67` | allowed | — |
| universal_subscriptions.ex | `Aiur.Config` | `universal_subscriptions.ex:6` | allowed | — |
| debug_log.ex | `Phoenix.PubSub`, `Aiur.PubSub` | `debug_log.ex:49-98` | remove | C2-T05 |
| ticket_observation.ex | `Aiur.TrackerIdentity`, `Aiur.OpaqueIdentifier` | `ticket_observation.ex` struct/type refs (`:50-62`) | **unassigned** — tracker types in the L1 spine | CONTRACT-REQUESTS (MP-R1 decides: shared type in kernel, or allowed edge) |
| exchange.ex, topic.ex, agent_subscription_policy.ex, subscription_store_supervisor.ex | none | — | — | — |

Not members, so not scanned: `Sanitizer`, `BranchRefStore`, `CommentFilter`,
`EventPublicationLog`, `Orchestrator.EventTopics`, `Orchestrator.AutoSubscriptions`
(C2-T11 records them in the manifest outside event-bus). No member references any
of them at base.

## Chosen design

Pure source-scan ExUnit test (no processes):

- `@members` — the list above.
- `@allowed_prefixes` — `Aiur.Events.`, `Aiur.TicketObservation`, `Aiur.Config`,
  `Aiur.JsonStore` (kernel/config per MP-R1 component map: event-bus deps are
  kernel and config).
- `@ratchet` — map `{member_file, referenced_module} => removing_ticket`, exactly
  the "remove"/"unassigned" rows above.
- Reference extraction: strip `@moduledoc`/`@doc` heredocs and `#` comments; collect
  fully qualified `Aiur(.Web)?.X…` names, aliased names expanded from `alias`
  lines (including `alias A.{B, C}` and `as:`), and `Phoenix.PubSub`.
- Assertions: (1) every reference is allowed or in `@ratchet`; (2) every `@ratchet`
  entry is still present (so the removing ticket must delete its entry — that
  deletion is the proof the seam ticket asks for).

## Implementation steps

1. Create the test with the helpers above; keep helpers private to the test file.
2. Assertion messages print `member -> module (remove in <ticket>)`.
3. Comment: "Temporary ratchet until C4-T03 moves these rules into
   scripts/check-components.py (MP-R1-C1). Deliberately green on main."

## Non-happy paths

- Alias forms not covered (for example `alias __MODULE__.X`) are member-internal
  and ignored; `import` of a non-member module is treated as a reference.
- A false positive from a type-only reference is still an edge (compile-time
  coupling); it stays listed until moved.

## Compatibility and rollout

n/a — test-only.

## Verification

Tests:

- `"event-bus members reference only kernel, config, members, or recorded ratchet edges"`.
- `"every recorded ratchet edge still exists (remove the entry when the seam lands)"`.

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/events/bus_boundary_test.exs
```

Mutation check: add `alias Aiur.Orchestrator.State` plus a call to it in
`events/topic.ex` in a worktree; test 1 must fail. Delete the
`Aiur.Webhooks.record_activity` call at `publisher.ex:176`; test 2 must fail.
Record the commands and `git status --porcelain`.

## Completion and handoff

- [ ] Two tests green on main; both mutations fail them.
- [ ] `TicketObservation -> TrackerIdentity/OpaqueIdentifier` recorded in
      CONTRACT-REQUESTS for MP-R1.
- Docs: none.
- Dependents: C2-T01, T03, T05, T06, T07 (each deletes its ratchet rows);
  C4-T03 (replaces this test with the checker rule).
