---
ticket_id: MP-E1-C1-T03
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: Keep open-issue labels from the existing poll and expose them through the tracker contract
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U5]
prior_boundaries: [ORC #12, BUS #10]
prior_features: []
prior_findings: [MP-E1 F8, RQ-5]
size_owner: "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T03 — Open-issue label observation at zero new requests

> **Plan refresh (wave 0).** Cites `45a290e3`. U5 rebases over the
> `record_open_issues/3` hook and keeps it (RC-19). After MP-R1 the snapshot
> moves with `aiur_github`; the `Aiur.Tracker` callback is the stable interface.

## Identity and outcome

- Bucket 2, MP-E1, C1, T03. Resolves RQ-5.
- **User value:** the queue sees every queued ticket's labels after each
  tracker poll without spending a GitHub request.
- **Deliverable:**
  1. `Aiur.GitHub.OpenIssueSnapshot` also records, per complete listing, a map
     `%{issue_id => %{labels: [String.t()], updated_at: DateTime.t() | nil}}`.
  2. After each complete listing it broadcasts
     `{:open_issues_recorded, taken_at_ms}` on Phoenix PubSub topic
     `"tracker:open_issues"`.
  3. A new optional `Aiur.Tracker` callback `open_issue_labels(max_age_ms)`
     returning `{:ok, %{id => entry}, taken_at_ms} | :none | {:error, :unsupported}`.
     Implemented by `Aiur.GitHub.Tracker` (reads the snapshot) and
     `Aiur.Memory.Tracker` (from configured issues). `Aiur.Linear.Tracker`
     answers `{:error, :unsupported}`.
- **Non-goals:** no new read; no change to which issues dispatch sees.

## Dependencies and blockers

- DESIGN-E1 (gate). No ticket predecessor. Concurrent with every other C1
  ticket and C2.
- Consumers: C3-T03 (trigger + observation), C4 tickets.

## Verified starting point (`45a290e3`)

- Both candidate polls list `issues?state=open&per_page=100` unfiltered and
  call `record_open_issues/3` only after every page was read
  (`src/lib/aiur/github/issues.ex:381-393, 396-432, 434-441`).
  `record_open_issues/3` stores only ids: `OpenIssueSnapshot.put(owner, repo, Enum.map(issues, & &1.id))` (`:438`).
- Each normalized `%Issue{}` already carries `labels` (downcased names,
  `:1013`) and `updated_at` (`:1016`).
- `src/lib/aiur/github/open_issue_snapshot.ex:1-82`: public named ETS table
  owned by its own process; `put/3` (`:37-47`), `fetch/3` (`:53-59`),
  `reset/0`; a missing table drops writes and reads answer `:none`.
- `src/lib/aiur/tracker.ex:8-32` callbacks and `@optional_callbacks`;
  `:56-73` the `Code.ensure_loaded?` + `function_exported?` dispatch pattern;
  `:162-168` `adapter/0` by `tracker.kind`.
- `src/lib/aiur/linear/tracker.ex:139-142` already answers
  `{:error, :unsupported}` for `add_label/remove_label`.
- PubSub broadcast pattern: `build_order/graph_projection.ex:1517-1519`
  (guards on `Process.whereis(Aiur.PubSub)`).
- Existing snapshot test: `src/test/aiur/orchestrator/dispatcher_blocked_by_cost_test.exs:49-53, 368, 411`.

## Chosen design

- Extend `put/3` to `put/4` (`put(owner, repo, numbers, labels_by_id \\ %{})`)
  and keep the ETS row `{key, set, taken_at_ms}` plus a second row
  `{{:labels, key}, labels_by_id, taken_at_ms}` so `fetch/3` and
  `BoundedBlockedBy` (`bounded_blocked_by.ex:85`) are untouched.
- Add `fetch_labels(owner, repo, max_age_ms)` with the same age rule.
- `record_open_issues/3` passes
  `Map.new(issues, &{&1.id, %{labels: &1.labels, updated_at: &1.updated_at}})`
  and broadcasts after the insert.
- Memory: about 30 open issues × a few labels; the poll already holds them.
  No titles or bodies are kept (plan §6 Privacy).
- `Aiur.Tracker.open_issue_labels/1` dispatches like
  `fetch_issue_states_by_ids_conditional/2`; an adapter without the callback
  answers `{:error, :unsupported}`.

## Implementation steps

1. `open_issue_snapshot.ex`: `put/4`, `fetch_labels/3`, `reset/0` clears both
   rows, broadcast helper.
2. `github/issues.ex:437-441`: pass labels; ≤ 6 lines (U8 debt).
3. `tracker.ex`: `@callback open_issue_labels(pos_integer())`, add to
   `@optional_callbacks`, facade function.
4. `github/tracker.ex`: implementation using `Transport.parse_repo/0` then
   `OpenIssueSnapshot.fetch_labels/3`.
5. `memory/tracker.ex`: implementation from `issue_entries/0`,
   `taken_at_ms = System.system_time(:millisecond)`.
6. `linear/tracker.ex`: `{:error, :unsupported}`.

## Non-happy paths

- **Partial or failed listing:** nothing is recorded (existing rule); the
  queue sees the previous snapshot ageing, and `max_age_ms` turns it into
  `:none` → `unknown`, never "no labels".
- **Snapshot process down:** `:none`; the queue writes nothing (plan §6 Stale).
- **TestTicketScope** filtering (`issues.ex:476`) does not apply to the
  recorded snapshot, which already names every open issue (`:434-436`).

## Compatibility and rollout

No config. Additive API. Rollback removes an unused row.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/github/open_issue_snapshot_test.exs` (PROPOSED) "fetch_labels returns the labels of the latest complete listing" | `{:ok, %{"7" => %{labels: ["agent:queued"]}}, _}` | `put/4` storing labels |
| same, "a listing older than max_age reads :none" | `:none` | the age check in `fetch_labels/3` |
| `src/test/aiur/github/issues_test.exs` "candidate poll records labels and broadcasts" — stub `request_fun` with two open issues; subscribe to `"tracker:open_issues"` | snapshot holds both label lists; `assert_receive {:open_issues_recorded, _}`; request count unchanged vs the same poll before the change (assert exact count from the stub recorder) | the `issues.ex` hunk |
| `src/test/aiur/tracker_test.exs` (PROPOSED if absent) "linear answers unsupported" | `{:error, :unsupported}` | the Linear clause / facade fallback |

Mutation check: revert the `issues.ex` hunk → the poll test fails; revert
`fetch_labels/3`'s age check → the stale test fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/github/open_issue_snapshot_test.exs test/aiur/github/issues_test.exs \
  test/aiur/orchestrator/dispatcher_blocked_by_cost_test.exs
```

## Completion and handoff

- [ ] Labels recorded at zero extra requests; signal broadcast; tracker
      callback for GitHub, memory and Linear.
- [ ] `dispatcher_blocked_by_cost_test.exs` still passes (close signal intact).
- Docs: none (internal). `website/docs-app/apis/github.md` is unaffected
  because no request changes.
- Dependents: C3-T03, C4-T01, C4-T02.
