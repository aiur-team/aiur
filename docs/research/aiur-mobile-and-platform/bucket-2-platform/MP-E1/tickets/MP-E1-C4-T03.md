---
ticket_id: MP-E1-C4-T03
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: Native blocked_by of ExecutorList items through a tracker callback
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C4-T01, MP-E1-C2-T02]
prior_units: [U5]
prior_boundaries: [BO #30, DSP #13]
prior_features: []
prior_findings: [MP-E1 F3, RQ-2]
size_owner: "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T03 — Respect GitHub dependencies set outside the queue

> **Plan refresh (wave 0).** U5 rebases over the new `Aiur.Tracker` callback
> and keeps it (RC-19). After MP-R1 the GitHub implementation moves to
> `aiur_github`; the callback is the stable port.

## Identity and outcome

- Bucket 2, MP-E1, C4, T03. Resolves RQ-2.
- **User value:** a list item that also has a GitHub "blocked by" dependency is
  not promoted while that blocker is open, so `agent:todo` keeps meaning ready.
  (The dispatcher would hold it anyway, `dispatch_policy.ex:1000-1008`; this
  avoids promoting a ticket that cannot start.)
- **Deliverable:** optional `Aiur.Tracker` callback
  `blocked_by(issue_id) :: {:ok, [String.t()]} | {:error, term()}`; GitHub
  implementation; memory implementation; observer use.

## Dependencies and blockers

- DESIGN-E1, C4-T01, C2-T02.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/github/bounded_blocked_by.ex:63-94` `fetch/2`: serves the held
  `:issue_blocked_by` list while younger than `max_age_ms/0` (15 min,
  `:61-73`), re-reads unconditionally when stale, and uses the open-issue
  snapshot as a close signal; fail-closed on read errors.
- Build Order members already carry native edges in the projection (C4-T02),
  so only ExecutorList items need this.

## Chosen design

- Called **lazily**: only for ExecutorList items whose list-edge verdicts are
  all `:satisfied` (about to be promoted). Result edges are added with
  `source: :native`; their prerequisites are observed like any other.
- GitHub: `BoundedBlockedBy.fetch/2` → map each blocker to its number string
  (same-repository only; a cross-repository blocker → `{:unknown, :external_edge}`).
- **Cost bound:** ≤ 1 `blocked_by` read per candidate per 15 min — the same
  bound the dispatch gate already pays for a todo ticket. No saving is claimed.
- Error → that item's native edges `unknown` → no promotion.

## Implementation steps

1. `tracker.ex` callback + facade; `github/tracker.ex` implementation
   (≈ 15 lines); `memory/tracker.ex` from `Issue.blocked_by`.
2. Observer in `build_queue/observer.ex` (PROPOSED) calls it for candidates.

## Non-happy paths

Read failure or budget hold → `unknown`, no write; retried next reconcile
within the same 15-minute bound.

## Compatibility and rollout

Additive callback. Linear: `{:error, :unsupported}` (queue already disabled).

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/build_queue/observer_test.exs` (PROPOSED) "a list item whose native blocker is open stays waiting" | no promote | the callback use |
| same, "blocked_by is not called for an item whose list prerequisite is pending" | zero calls | the lazy guard |
| same, "blocked_by error → unknown, no promote" | `{:unknown, _}` | error mapping |
| `src/test/aiur/github/tracker_blocked_by_test.exs` (PROPOSED) "a held edge list younger than max age costs no request" | request recorder count 0 | delegation to `BoundedBlockedBy` (a direct `DependenciesApi` call would read) |

Mutation check: call `blocked_by` for every item → test 2 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/observer_test.exs test/aiur/github/tracker_blocked_by_test.exs
```

## Completion and handoff

- [ ] Callback, implementations, lazy use; cost bound stated in the PR body.
- Docs: `website/docs-app/apis/github.md` gains one line: the queue reuses the
  dispatch gate's bounded `blocked_by` read for list items.
- Dependents: C9-T04 (measurement).
