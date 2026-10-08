---
ticket_id: MP-R2-C5-T03
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Reserve planned namespaces and register the RC-08 topics in the catalog (owners, classes, allowlists)
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C5-T01]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-E1, MP-E2, MP-E7, MP-R1]
prior_findings: []
size_owner: n/a (catalog data file; website doc page ~106 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C5-T03 — Reserved namespaces and RC-08 registrations

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C5.** Inert.
- **Deliverable:** catalog entries (C5-T01 struct) for every topic that
  coordinator decision **RC-08** assigns to MP-R2's catalog, plus the
  namespace reservations of contract §9, each with owner feature, class,
  export flag and allowlists taken from the owning contract. A short
  "Reserved namespaces" section in `website/docs-app/concepts/message-bus.md`.
- **Why now, before the producers exist:** producers land in other
  features (MP-E1 wave 0, MP-E2 wave 2, MP-E7 wave 3/4). Registering them
  here once, with the owner named, keeps the grammar frozen (contract §9)
  and lets C6/C7 export them the day they appear, without an MP-R2 edit
  per producer.
- **Non-goals:** no producer code; an entry for a topic nobody publishes
  yet is data only (the catalog census test from C5-T01 must accept
  "registered, no producer yet" for entries flagged `reserved: true`).

## Dependencies and blockers

DESIGN-R2 §2; C5-T01. Each owner contract below is draft; if an owner
changes a topic name before this lands, follow the owner contract and
note it in the PR. Concurrent with C5-T02/T04, C6-T01.

## Verified starting point (owner contracts, research root)

| Topic (RC-08) | Owner / producer | Class | Source of shape |
| --- | --- | --- | --- |
| `ticket.<id>.agent.decision.human-needed` | MP-E2 (through DecisionStore) | journaled | `contracts/command-request-and-resolution.md` §8 (fields `decision_id, version, short_label, requester, blocking, urgency, cause`; **no question text**) |
| `ticket.<id>.agent.decision.routed`, `.native-released` | MP-E2 | journaled | same §8 table |
| `ticket.<id>.pr.closed_unmerged`, `ticket.<id>.issue.closed` | MP-E1 (E-A3), producer webhook normalizer/poll path | live | `contracts/queue-readiness-and-build-progress.md` §6 E-A3 |
| `ticket.<id>.queue.promoted|withdrawn|held|released|overridden|removed` | MP-E1 | live | queue contract §4.3 |
| `ticket.<id>.queue.attention.*` | MP-E1 | ledgered | queue contract §4.3 |
| `system.queue.<queue_id>.progress`, `system.queue.attention.<cause>` | MP-E1 | ledgered | queue contract §4.3 |
| `system.build_order.<root>.progress` (RC-08; no `.milestone` suffix, X-09) | MP-E1-C7 (producer); `Aiur.BuildProgress` belongs to build-orders (RC-40) | ledgered | queue contract §4.3, note §4.3 "MP-E1 chunk C7 implements the producer" |
| `ticket.<id>.agent.listen-mode.changed` | MP-E7 | live | `contracts/listener-mode.md:151-153` (`{requested, effective, effective_reason, version, actor}`) |
| `system.capabilities.changed` | MP-R1-C3-T05 | live | `contracts/identity-and-capabilities.md` §5 ("MP-R2 can carry `system.capabilities.changed` to remote subscribers") |
| Reserved, no topic yet: `executor.conversation.*` | MP-E3 (unused) | — | contract §9 |

Doc page today: `website/docs-app/concepts/message-bus.md` (106 lines;
sections end with "Commands and decisions" `:84` and "GitHub observation" `:97`).

## Chosen design

- Add a `reserved: true` field to `Catalog.Entry` (default `false`); the
  C5-T01 census test treats a reserved entry without a producer literal as
  valid, and a **non-reserved** entry without a producer as a failure
  (stale entry).
- Entries (pattern → export?, refs, attrs):
  - `ticket.*.agent.decision.human-needed` → export; refs `ticket,
    decision_id, decision_version`; attrs `blocking` boolean, `urgency`
    enum (values from the E2 contract), `cause` enum. `short_label` and
    `requester` are **never** feed attrs: `short_label` is agent-authored
    text (security m3, events contract §1 rule 3). It travels only inside the
    sealed push payload (MP-N4); feed clients read it from the Decision API.
  - `.routed`, `.native-released` → covered by the existing
    `ticket.*.agent.decision.#` entry (C5-T01); no new entry.
  - `ticket.*.pr.closed_unmerged`, `ticket.*.issue.closed` → export; refs
    `ticket, pr_number`.
  - `ticket.*.queue.#` → export; refs `ticket, queue_id`; attrs `cause`
    enum. `ticket.*.queue.attention.#` → ledgered, export, refs `ticket,
    prerequisite, blocked` (list of ids — allowlist type `{:list, :id}`
    added to the type set), attrs `cause`.
  - `system.queue.*.progress`, `system.build_order.*.progress` (the exact
    names MP-E1 publishes; the milestone is an attr, not a topic segment)
    → export; refs `queue_id`/`root`; attrs `milestone` enum `25|50|75|100`,
    `percent` integer, `generation` integer, `freshness` enum.
    RC-10: finer progress is a read API + internal signal, not more events.
  - `system.queue.attention.#` → ledgered, export, attrs `cause`.
  - `ticket.*.agent.listen-mode.changed` → export; attrs `requested`,
    `effective` enum `steer|sync|async` (listener-mode contract), `version`
    integer; `effective_reason` enum; `actor` **not** exported (identity).
  - `system.capabilities.changed` → export; attrs `revision` integer only
    (clients re-read `GET /api/v1/capabilities`; contract §1 "events are
    signals").
  - `executor.conversation.#` → reserved, not exported.
- Docs: a "Reserved namespaces" table in `message-bus.md` listing the
  namespace, owning feature and "events are signals; re-read the owner's
  API" (one sentence each). This documents existing reservation, not new
  behaviour, so it may ship ahead of the producers.

## Implementation steps

1. Extend `Entry` with `reserved` and the `{:list, :id}` attr type
   (update C5-T02's extractor for that type in the same PR — 10 lines).
2. Add the entries above to `entries.ex`, each with a comment linking the
   owner contract section.
3. Update the census test rule (reserved vs stale).
4. Add the docs section.

## Non-happy paths

- An owner later publishes a topic outside its reserved namespace: the
  C5-T01 census fails in that owner's PR (unknown topic), forcing a catalog
  entry — intended.
- An owner renames a reserved topic: stale-reserved entries are allowed, so
  the rename is caught only when the new name lacks an entry; the PR
  checklist for E1/E2/E7 tickets must include "update the MP-R2 catalog".
  Recorded as a dependent note in those features (handoff list below).

## Compatibility and rollout

Inert data. The docs change is accurate today (reservations are policy,
contract §9). Rollback: revert.

## Verification

1. `catalog_test.exs` `"RC-08 topics resolve to their registered entries"` —
   `lookup("ticket.9.agent.decision.human-needed").owner == "MP-E2"`,
   `lookup("ticket.9.pr.closed_unmerged").export? == true`,
   `lookup("system.build_order.abc.progress").owner == "MP-E1"`,
   `lookup("system.queue.q1.progress").export? == true` (the topics MP-E1
   publishes; a `.milestone`-suffixed pattern would not match them, X-09),
   `lookup("ticket.9.agent.listen-mode.changed").owner == "MP-E7"`,
   `lookup("system.capabilities.changed").owner == "MP-R1"`. **Fails
   without step 2** (they resolve to broader entries or the default).
2. `"a non-reserved entry without a producer fails the census"` — fixture
   catalog with one unreserved, unproduced entry → census reports it.
3. `"human-needed exports no text"` — `Envelope.to_external/2` on a
   payload with `short_label: "Deploy?"` and `question: "..."` → neither
   value appears in the JSON.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/catalog_test.exs test/aiur/events/envelope_test.exs
env -C <worktree>/website/docs-app bun install --frozen-lockfile && env -C <worktree>/website/docs-app bun run build   # same as .github/workflows/website.yml:49-54
```

Mutation check: remove the `human-needed` entry → test 1 fails; restore → pass.

## Completion and handoff

- [ ] All RC-08 topics resolve to an owned entry.
- [ ] `message-bus.md` has the reserved-namespace table (AGENTS.md "Docs ship
      with the change": documents the namespaces operators and agents will see).
- [ ] Tests 1–3 added and mutation-checked.
- Dependents and handoff notes: MP-E1 (C4 closed-unmerged producer, C7
  progress producer), MP-E2 (C1-T03 human-needed), MP-E7 (listen-mode event),
  MP-R1-C3-T05 (capabilities.changed) — each producer PR keeps its catalog
  entry accurate.
