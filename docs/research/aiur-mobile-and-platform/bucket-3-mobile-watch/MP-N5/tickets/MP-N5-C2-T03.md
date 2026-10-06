---
ticket_id: MP-N5-C2-T03
feature_id: MP-N5
chunk_id: MP-N5-C2
bucket: 3-mobile-watch
title: Progress rules — per-device 10/25/50 % thresholds from the E1 read API and progress signal
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C2-T01, MP-N5-C1-T02, MP-E1-C7]
prior_units: []
prior_boundaries: [BO #30, new #41 candidate push-relay]
prior_features: [MP-E1]
prior_findings: [RC-10, queue-readiness contract §4.1-§4.3, root_summary.ex:6 progress_resolution]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C2-T03 — Progress rules

## Identity and outcome

Bucket 3, MP-N5, chunk C2. Rule module `Aiur.Push.Policy.Rules.Progress` (PROPOSED)
implementing N5 plan §5.2 per RC-10: on each E1 progress-changed signal, read
`Aiur.BuildQueue.progress/1` facts and, per device with progress enabled and per scope
`{build_order, root} | {queue, id}` and generation, compute
`crossed = floor(percent / step) * step`; if `crossed > last_notified_pct`, emit **one**
intent for `crossed` (`progress.milestone`, or `progress.complete` at 100 / completed),
update `last_notified_pct`. Facts with `resolution` other than `resolved` are ignored
(E1 rule). Decreases never emit and never lower the tracker. A new generation starts at 0.

`dedup_key = <bo|q>:<id>:<generation>:m<crossed>` or `…:complete`; `stream =
<bo|q>:<id>`; `seq` = crossed (monotonic within generation; completion uses 101);
`expires_at = now + 2 h`; destination `target.kind: build_order`, `root_id`.

**The Phase B 60-second `CatalogStore` fallback is dropped:** MP-E1-C7 is a hard
predecessor (RC-10), and a second progress computation would let notifications disagree
with the dashboard (E1 contract §4.1 "not recomputed, so the dashboard and notifications
agree").

## Dependencies and blockers

- **MP-E1-C7** (`Aiur.BuildQueue.progress/1` + internal progress-changed signal + the
  25 % milestone topics). CR-N5-4 asks MP-E1 for the signal's exact name and payload
  (`{scope, generation}` is all N5 needs).
- C2-T01 (Source, ledger), C1-T02 (effective step; masked when `build_queue` or
  `build_orders` absent).
- DESIGN-N5 D-5 (re-notify when a reopened root completes again): implemented as the
  constant `@renotify_new_generation true` (proposal); if D-5 = no, the constant flips and
  the tracker ignores generation for `complete` only — both paths are tested, so the
  answer does not change the code shape. D-8 (queue milestones share the build-order
  setting) likewise: one setting drives both scopes (proposal).

## Verified starting point

- `RootSummary.progress :: non_neg_integer() | nil`, `progress_resolution ::
  :resolved | :partial | :unresolved | :unknown`, `completed?`
  (`src/lib/aiur/build_order/root_summary.ex:6,8-27`).
- Queue-readiness contract §4.1 (facts `{scope, completed, resolved, total, percent,
  resolution, observed_at, freshness}`), §4.2 (no bursts, no repeats per generation, none
  from unresolved/unknown), §5 (`Aiur.BuildQueue.progress/1`).
- Existing test file for progress semantics: `src/test/aiur/build_order/root_summary_progress_test.exs`.

## Chosen design

- Tracker state `{device_id, instance_id, scope, id, generation} → last_notified_pct`
  persisted with the ledger (C2-T01). Baseline on enable/step change: C1-T04.
- Step 25 uses the same computation (not the E1 milestone topic), so all steps share one
  code path; the E1 milestone topic is used only as an additional wake-up signal.
- Stale facts (`freshness: stale|unknown`) → skip this evaluation (no notification from
  stale data).

## Implementation steps

`policy/rules/progress.ex` (PROPOSED), table-driven tests.

## Non-happy paths

- `build_queue` not installed → rule inactive; settings show unavailable (C1-T02).
- Restart at 80 % → tracker persisted; nothing emitted (E1 "restart at 80 % emits
  nothing").
- Two instances sharing a root? Not possible: one instance per repository (brief §3);
  scope ids are per instance.

## Compatibility and rollout

No config.

## Verification

`src/test/aiur/push/policy/rules/progress_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"20→70→60→76→100(completed) at step 25 yields 50, 75, complete"` (AC-N5-3) | exactly those | emit every crossed threshold |
| `"20→70 at step 10 yields only 70"` (V-PR1 analogue) | one | loop over thresholds |
| `"drop then re-cross 50 does not repeat"` (V-PR2) | none | lower tracker on decrease |
| `"partial resolution never emits"` | none | ignore resolution |
| `"new generation re-notifies completion when constant true, not when false"` | both cases | hard-code one path |
| `"stale facts are skipped"` | none | evaluate stale |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/rules/progress_test.exs`.

## Completion and handoff

- [ ] AC-N5-3 covered; D-5/D-8 constants set from DESIGN-N5 at approval.
- Dependents: C1-T04, C3-T01.
