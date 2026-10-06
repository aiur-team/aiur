---
ticket_id: MP-E1-C4-T01
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: ExecutorList source - ordered list with "after #N" edges
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T01, MP-E1-C3-T03]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 D5]
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T01 — `Aiur.BuildQueue.Sources.ExecutorList`

> **Plan refresh (wave 0).** New file under `build_queue/sources/`; moves
> unchanged after MP-R1. This is the second `DependencySource` implementation
> that the R1 component map §4 requires.

## Identity and outcome

- Bucket 2, MP-E1, C4, T01.
- **User value:** a queue works with no Build Order at all: an ordered list
  plus optional "after #N" edges (D5). This is the gap where a pre-labelled
  ticket would simply start (plan §2 gap 1).
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/source.ex` (behaviour
  `members(queue, store_doc) :: {:ok, [Item], [Edge], freshness} | {:unavailable, reason}`)
  and `sources/executor_list.ex`; server mutation calls `add/3`, `remove/1`,
  `reorder/2`, `add_edge/2`, used by C6-T02.

## Dependencies and blockers

- DESIGN-E1 (verb semantics, refusal copy), C2-T01, C3-T03.

## Verified starting point (`45a290e3`)

- Contract §5 `Aiur.BuildQueue.Source`. No existing local list exists; the
  only list-like control is `aiur --todo [--only]` (`agent_control_cli.ex:854-893, 1082-1158`).

## Chosen design

- Items and positions live in the store (C3-T02). `members/2` reads them; its
  freshness is always `current` (local data).
- **One owner per issue:** `add` refuses an issue already in any queue with
  `{:error, {:already_queued, queue_name}}`.
- `add(ids, queue: name, at: pos, after: n)`: creates the queue if absent;
  inserts at `pos` (default end); `after: n` adds `Edge{prerequisite: n, dependent: id, source: :list}`
  for each id. `n` need not be in a queue (an outside prerequisite is observed
  like any other).
- `add` on a closed issue is refused `{:error, :closed}` (needs observation;
  `issue_closure/1`, C4-T04, or the open-issue snapshot).
- Each `add` issues a `mark` action (C3-T04); `remove` issues `unmark`.
- Positions are dense integers renumbered on every change.

## Implementation steps

1. `source.ex` behaviour; `sources/executor_list.ex` (≈ 90 lines).
2. Server `handle_call`s for the four mutations; each saves the store.

## Non-happy paths

- Store unavailable → mutations refused `{:error, :store_unavailable}`.
- Self edge → refused with `{:error, :self_edge}`; nothing is stored.
- An edge that makes a cycle of two or more items → accepted, and the planner
  marks the cycle `unknown` (visible; the operator removes it).

## Compatibility and rollout

No config.

## Verification

| Test (`src/test/aiur/build_queue/executor_list_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "add twice to different queues is refused with the owner's name" | `{:error, {:already_queued, "paseo"}}` | one-owner rule |
| "add --after creates list edges" | edges present; dependent `waiting` | edge creation |
| "reorder renumbers positions densely" | `[0,1,2]` | renumbering |
| "self edge refused" | `{:error, :self_edge}` | the guard |
| "add emits a mark action; remove an unmark" | actions | wiring |

Mutation check: drop the one-owner check → test 1 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/executor_list_test.exs
```

## Completion and handoff

- [ ] Behaviour + list source + mutations.
- Docs: verbs documented in C6-T02.
- Dependents: C4-T03, C6-T02.
