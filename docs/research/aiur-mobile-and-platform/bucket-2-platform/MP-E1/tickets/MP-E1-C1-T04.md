---
ticket_id: MP-E1-C1-T04
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: "Conditional promotion: expected_state :none on the existing state writer"
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U2, U5]
prior_boundaries: [DSP #13]
prior_features: []
prior_findings: [MP-E1 F2, RQ-4]
size_owner: "GH_TRUST / GitHub access (github/issue_state.ex; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T04 — `expected_state: :none`: promote only an issue with no state label

> **Plan refresh (wave 0).** Cites `45a290e3`. **RC-20:** the queue is a
> sanctioned caller of the single label-writer seam. Before U2 it calls this
> existing writer (`Aiur.Tracker.update_issue_state/3` → `GitHub.IssueState`);
> after U2 it calls U2's writer, which must keep the `:none` precondition.
> U5 rebases over this hunk and keeps it (RC-19).

## Identity and outcome

- Bucket 2, MP-E1, C1, T04. Resolves RQ-4.
- **User value:** the queue never overwrites a state label that a human, the
  Executor or an agent set between the queue's observation and its write.
- **Deliverable:** `update_issue_state(id, state, expected_state: :none)`
  succeeds only when the issue currently carries **no** state label; otherwise
  `{:error, {:stale_issue_state, :none, actual}}`. Implemented in
  `Aiur.GitHub.IssueState` and `Aiur.Memory.Tracker`.
- **Non-goals:** no new endpoint; no conditional *remove* (withdrawal is
  guarded by the ClaimProbe, C1-T06).

## Dependencies and blockers

- DESIGN-E1 (gate). Concurrent with all of C1 and C2. Consumer: C3-T04.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/github/issue_state.ex:14-36` `update_issue_state/3`;
  `:93-104` first read via `Issues.fetch_issue_raw_conditional/2`;
  `:106-122` `apply_issue_state_update/4` validates, re-reads
  (`revalidate_expected_state/2`, `:142-161`, `revalidate: true` → conditional
  request, `304` free) and refuses closed issues (`:111-117`, `:127-140`).
- `:170-188` `validate_expected_state/2`: binary only;
  `{:ok, _invalid}` → `{:error, :invalid_expected_state}`. `current_state/2`
  (`:190-197`) returns `nil` for zero state labels
  (`Issues.extract_state/3`, `github/issues.ex:1110-1134`).
- Swaps add before remove and keep markers (`:199-219`, `:289-310`).
- `src/lib/aiur/memory/tracker.ex:93-106, 131-151`: memory expected-state check;
  `normalize_state_slug(nil)` is `""` (`:183-195`).
- `src/lib/aiur/tracker.ex:86-107` facade; `github/tracker.ex:176-191`.
- Tests: `src/test/aiur/github/issue_state_test.exs:420-470` (expected_state
  `"ci-wait"` cases).

## Chosen design

- `validate_expected_state/2` gets a clause
  `{:ok, :none} -> if current_state(issue_body, prefix) == nil, do: :ok, else: {:error, {:stale_issue_state, :none, actual}}`.
  Because `Keyword.has_key?(opts, :expected_state)` is true, the existing
  revalidation runs, so the check is made on a fresh conditional read.
- Memory tracker: `{:ok, :none}` → compare `normalize_state_slug(current) == ""`.
- **Cost per promotion:** at most three conditional reads of
  `GET /issues/:n` (`:97`, `:148`, and the active-label recheck `:252`), each
  `304` when unchanged (no primary-limit cost, `github/issues.ex:115-118`),
  plus one `POST .../labels`. No saving is claimed.

## Implementation steps

1. `issue_state.ex`: new clause in `validate_expected_state/2` (≈ 8 lines).
2. `memory/tracker.ex`: accept `:none` in `update_issue_state/3` and
   `update_issue_state_if_current/3`.
3. `@spec` on `Aiur.Tracker.update_issue_state/3` documents
   `expected_state: String.t() | :none`.

## Non-happy paths

- **Race:** a state label appears between the first read and the revalidation
  → `:stale_issue_state`; nothing written; the queue re-observes (C3-T04).
- **Closed issue:** `{:error, {:no_state_label_written, _}}` (existing).
- **Two state labels already:** `current_state` resolves a winner (non-nil)
  → stale; the queue does not write.
- **Linear:** `update_issue_state/3` unsupported path unchanged; the queue is
  disabled there anyway.

## Compatibility and rollout

Additive option; existing callers unaffected. No config.

## Verification

| Test (`src/test/aiur/github/issue_state_test.exs` unless noted) | Expected | Fails without |
| --- | --- | --- |
| "expected_state :none writes todo on a marker-only issue" — stub bodies with labels `["agent:queued"]` | POST `{"labels":["agent:todo"]}`; no DELETE of `agent:queued`; `:ok` | the new clause (`:invalid_expected_state`) |
| "expected_state :none refuses when a state label appeared before revalidation" — first read marker-only, revalidation read carries `agent:in-progress` | `{:error, {:stale_issue_state, :none, "in-progress"}}`; no POST | the revalidation using the `:none` clause |
| "expected_state :none refuses a closed issue" | `{:error, {:no_state_label_written, _}}`; no POST of `agent:todo` | existing closed guard (regression guard; name it so) |
| `src/test/aiur/memory_tracker_test.exs` (PROPOSED if absent) ":none only matches an issue with no state" | `:ok` for `state: nil`; stale for `"todo"` | the memory clause |

Mutation check: delete the new clause → the first two tests fail. The closed
test is a declared regression guard and does not count toward this change.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/github/issue_state_test.exs
```

## Completion and handoff

- [ ] `:none` accepted by the GitHub and memory writers; tests as above.
- Docs: none (internal option).
- Dependents: C3-T04.
