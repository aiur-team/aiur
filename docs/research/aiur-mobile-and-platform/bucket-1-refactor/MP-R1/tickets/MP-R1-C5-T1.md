---
ticket_id: MP-R1-C5-T1
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Rename the crash-safe append journal Aiur.DecisionLog to kernel Aiur.Journal and update its 17 callers
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2, U6-decision-journal]
prior_units: [U6]
prior_boundaries: ["K #1", "DEC #27", "BUS #10", "USG #25", "EXE #26", "PRJ #28", "ING #9", "CA #20", "PRL #15"]
prior_features: [MP-R2]
prior_findings: [loose-1-02, loose-1-03]
size_owner: n/a (decision_log.ex is 279 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T1 — Journal primitive to the kernel

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5 (kernel and signal port). Step S1
  (prior carve order §7 step 1).
- **User value:** none visible. Seven non-Decision boundaries stop depending on the
  Commands component to get a durable append log, which is the largest kernel-level
  inversion after the signal port.
- **Deliverable:** `git mv src/lib/aiur/decision_log.ex src/lib/aiur/journal.ex`, module
  `Aiur.DecisionLog` → `Aiur.Journal` (moduledoc generalised: "append-only NDJSON journal";
  the Decision-specific paragraph moves to `Aiur.DecisionStore`'s moduledoc); update every
  caller; move `test/aiur/decision_log_test.exs` → `test/aiur/journal_test.exs`. No
  function, option, fsync, truncation or symlink behaviour changes.
- **RQ-3 of MP-R2 answered:** the journal primitive lives in the `kernel` component as
  `Aiur.Journal`; MP-R2-C3-T01's `Aiur.Events.Journal` builds on it.
- **Non-goals:** U6's outcome matrix (must already have landed), on-disk format, file
  paths, the Decision projection.

## Dependencies and blockers

- **U6 decision-journal outcome matrix** (prior plan
  `docs/plans/2026-09-29-001-refactor-production-readiness-plan.md` U6; interlock
  [migration-plan.md §3](../migration-plan.md): "U6's journal outcome matrix lands first;
  S1 moves the primitive without changing fsync or append semantics"). Use the merged U6
  version of `decision_log.ex` as the starting point.
- DESIGN-R1 §1; C1-T2 (allowlist proves edges removed).
- **Concurrent:** C5-T2, C5-T3. **Dependents:** MP-R2-C3-T01.

## Verified starting point (`45a290e3`)

- `Aiur.DecisionLog` (279 lines) public API: `prepare/3` (`:45-46`), `ensure_directory/1`
  (`:59-60`), `append/2` (`:126-127`), `replay/2,3` (`:160-166`); depends only on
  `Aiur.Fs` (`:35`).
- Callers (walker, 17 files, 8 prior boundaries): `allowed_contributors/audit.ex`,
  `app_server/tool_call_ledger/storage.ex`, `current_run_membership/store/paths.ex`,
  `current_run_membership/store/recovery.ex`, `decision_metrics/log.ex`,
  `decision_projection.ex`, `decision_store.ex`, `event_publication_log.ex`,
  `executor_events.ex`, `executor_wake_inbox.ex`, `recent_merge_store.ex`,
  `usage_aggregate/paths.ex`, `usage_compaction/paths.ex`, `usage_ledger/paths.ex`,
  `usage_ledger/recovery.ex`, `usage_ledger/store.ex`, `webhooks/delivery_log.ex`.
- `Aiur.Fs.sync_filesystem/0` doc names `Aiur.DecisionLog.append/2` (`fs.ex:72`);
  update the reference.
- Test: `src/test/aiur/decision_log_test.exs` (symlink refusal, torn tail truncation,
  interior corruption halts replay, first-creation sync).

## Chosen design

Pure rename; no delegate module (all callers are updated in the same PR, so a delegate
would only preserve a misleading name). Grep gate: after the change,
`rg -n 'DecisionLog' src/` matches only `DecisionLog`-unrelated names (for example
`Decision` event modules), never `Aiur.DecisionLog`.

## Implementation steps

1. `git mv` + module rename + moduledoc split.
2. Update the 17 callers (`alias Aiur.DecisionLog` → `alias Aiur.Journal`; call sites).
3. Move the test file; rename `describe` blocks; no assertion changes.
4. `components.json`: `src/lib/aiur/journal.ex` → `kernel`, add `Aiur.Journal` to kernel
   facades.
5. Checker: allowlist entries `* → Aiur.DecisionLog` become stale; delete.

## Non-happy paths

- A caller missed → compile error (`--warnings-as-errors`, CONTRIBUTING), never runtime.
- Release upgrade: aiur ships whole releases, not hot code upgrades, and journal records
  are plain JSON that never name a module, so the rename leaves on-disk state valid.

## Compatibility and rollout

No file path or format changes. Rollback: revert.

## Verification

- Moved suite `test/aiur/journal_test.exs` (same 18+ cases) green.
- Caller suites green: `test/aiur/decision_store_test.exs`,
  `test/aiur/executor_wake_inbox_test.exs`, `test/aiur/usage_ledger/*_test.exs`,
  `test/aiur/webhooks/delivery_log_test.exs`, `test/aiur/recent_merge_store_test.exs`
  (CONTRIBUTING sibling-file rule: run `rg -n --fixed-strings 'DecisionLog' src/test/`
  and account for every hit).
- Golden check: a `decisions.ndjson` written by the pre-change binary replays identically
  after (test fixture file committed under `test/fixtures/journal/`).
- Command: `$TESTCMD test/aiur/journal_test.exs test/aiur/decision_store_test.exs test/aiur/executor_wake_inbox_test.exs`.
- Mutation check: n/a for a rename (no behaviour added). The golden replay test is a
  regression guard and is named as such.
- Checker: kernel has no new outbound edge; every `→ Aiur.DecisionLog` allowlist key (one per
  source component) removed.

## Completion and handoff

- [ ] U6 merged first; rename merged; allowlist pruned.
- [ ] Docs: none.
- **Dependents:** MP-R2-C3-T01, C8 (Commands component move).
