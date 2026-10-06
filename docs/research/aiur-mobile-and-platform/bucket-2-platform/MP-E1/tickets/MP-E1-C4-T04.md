---
ticket_id: MP-E1-C4-T04
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: Closed-prerequisite state_reason through a tracker callback
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T02, MP-E1-C3-T03]
prior_units: [U5]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F8, RQ-8]
size_owner: "GH_TRUST (github/issues.ex 1248 lines, one-line change; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T04 — Was the prerequisite completed, or closed as not planned?

> **Plan refresh (wave 0).** U5 rebases over the `:caller` option and the new
> callback and keeps them (RC-19).

## Identity and outcome

- Bucket 2, MP-E1, C4, T04. Resolves RQ-8.
- **User value:** a dependent is released only when its prerequisite was
  closed as completed; a "not planned" close holds it and alerts (D6, OQ-2).
- **Deliverable:** optional `Aiur.Tracker` callback
  `issue_closure(issue_id) :: {:ok, %{open?: boolean(), state_reason: String.t() | nil}} | {:error, term()}`;
  GitHub implementation with request attribution `build_queue_observe`;
  terminal results cached in the observer.

## Dependencies and blockers

- DESIGN-E1 (OQ-2), C2-T02, C3-T03.

## Verified starting point (`45a290e3`)

- A closed issue drops out of the open listing (F8); its reason needs one read.
- `src/lib/aiur/github/issues.ex:152-167` `fetch_issue_raw_conditional/2`
  returns the raw issue body (which carries `state_reason`) and says whether
  it was `:fresh` (no request), `:not_modified` (304) or `:fetched`
  (`:102-151`). The caller label is hard-coded: `caller: "issue_raw_conditional"` (`:197`).
- Webhook `issues` deliveries and `WriteThrough` keep the `:issue` record
  current, so a recently closed prerequisite is often `:fresh`.
- `aiur github-cost` attributes by caller (`website/docs-app/apis/github.md`).

## Chosen design

- Observer: a prerequisite that is open in the previous observation and absent
  from the current open listing (or never seen) → `issue_closure/1` once.
  Cache `{closed, reason}` as terminal; a later appearance in the open listing
  (reopen) clears the cache.
- GitHub implementation:
  `Issues.fetch_issue_raw_conditional(n, freshness_ms: observation_max_age_ms, caller: "build_queue_observe")`.
- `issues.ex:197`: `caller: Keyword.get(opts, :caller, "issue_raw_conditional")`
  (one line).

## Implementation steps

1. `issues.ex` one-line option.
2. `tracker.ex` callback; GitHub/memory/Linear implementations.
3. Observer cache.

## Non-happy paths

- Read error → `{:unknown, :closed_reason}`; retried next reconcile.
- `duplicate` → `unknown` + attention naming the cause (contract §2.1).

## Compatibility and rollout

Additive. Request cost: ≤ 1 read per newly closed prerequisite.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/github/issues_test.exs` "fetch_issue_raw_conditional passes the caller option to the request" | stub sees `caller: "build_queue_observe"` | the `:197` change |
| `src/test/aiur/build_queue/observer_test.exs` "a newly closed prerequisite is read once across 10 reconciles" | 1 call | the terminal cache |
| same, "completed → satisfied; not_planned → failed" | verdicts | callback mapping |
| same, "reopen clears the cache" | second call after reopen | cache invalidation |

Mutation check: remove the cache → test 2 sees 10 calls.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/github/issues_test.exs test/aiur/build_queue/observer_test.exs
```

## Completion and handoff

- [ ] Callback with attribution; cached.
- Docs: `apis/github.md` caller list gains `build_queue_observe`.
- Dependents: C4-T06, C9-T04.
