---
ticket_id: MP-R2-C6-T03
feature_id: MP-R2
chunk_id: MP-R2-C6
bucket: 1 (Bucket-2-enabling, RC-09)
title: Export retention by whole-segment deletion, oldest_seq/head_seq meta, and epoch rules (new epoch only when the journal is re-created or the instance changes)
status: ready
blocked_by: [DESIGN-R2 §2 (S1 retention, S4 reset), MP-R2-C6-T01, MP-R2-C6-T02]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-N4, MP-N5 (reset handling), MP-R1 (identity)]
prior_findings: []
size_owner: n/a (new code in events/export/*, ≤ 200 lines added)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C6-T03 — Retention, meta and epoch

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C6.** Off by default.
- **User value (later):** disk use stays bounded, and a phone that was
  offline longer than retention gets one clear `reset` instead of a burst
  of stale notifications (DESIGN-R2 S4).
- **Deliverable:** retention trim in the exporter that keeps `seq` dense and
  never rewrites a retained line; `export.meta.json` maintenance; the epoch
  rules; `Reader` returns `reset` for stale cursors and epoch changes.
- **Non-goals:** configurable trim schedule; compaction; any deletion of
  transcripts or Command records (contract D-3 — retention trims only the
  export copy).

## Dependencies and blockers

DESIGN-R2 §2 S1/S4; C6-T01 (keys `retention_days`, `retention_max_events`;
their *values* are KQ-R2-1, which C6-T01 carries); C6-T02 (layout: segments
`seg.<first_seq>.ndjson`, meta file). Concurrent with C6-T04, C6-T05.

## Verified starting point (45a290e3)

No export journal exists. Reused primitives:

| Fact | Evidence |
| --- | --- |
| DecisionLog never rewrites a file except to truncate a torn tail | `src/lib/aiur/decision_log.ex:13-28` |
| Atomic JSON write (rename) for meta | `Aiur.JsonStore.write!/2`, used e.g. `events/subscription_store.ex:715-720` |
| 8 MiB segment bound precedent (`AlertLedger`) | conversations contract §6 cites it; check `alert_ledger.ex` at implementation for the constant |
| Contract rules | `contracts/events-and-replay.md` §4.3 (`reset`), §6 D-3, §8 (trim keeps `seq` dense, moves `oldest_seq`) |

## Chosen design

**Why whole segments:** removing lines from the front of an append-only file
would rewrite retained lines (forbidden by contract §8 and by DecisionLog's
model). Deleting whole closed segments keeps every retained line
byte-identical. Granularity cost: up to one segment (≤ 8 MiB) beyond the
bound is kept; documented.

**Trim rule** (run by the exporter after each segment roll and once at boot,
in the exporter process so there is one writer):

- Candidate segments: all closed segments (never the active one).
- Delete the oldest closed segment while **either** (a) its newest record's
  `observed_at` is older than `now - retention_days`, or (b) records retained
  after deletion would still be ≥ `retention_max_events`. Stop at the first
  segment that satisfies neither.
- After deleting, set `oldest_seq` = first seq of the oldest remaining
  segment; write meta (atomic) **before** unlinking the file — so a crash
  between leaves a meta that claims less than is on disk (safe: a reader
  sees `reset` slightly early), never more.

**Meta:** `{"v":1,"epoch","instance","oldest_seq","head_seq"}`. `head_seq`
updated after each append batch (the segment is authoritative on boot,
C6-T02).

**Epoch rules (decision):** a new random `epoch` is created only when
(a) no meta and no segments exist (first enable or operator moved the
directory away), or (b) `meta.instance != InstanceRef.current()` (moved root
or identity reset, C5-T04). Then all old segments are moved into
`events/export/old-<epoch>/` (not deleted; operator evidence) and `seq`
restarts at 1. A daemon restart, an Exchange crash, or an exporter crash do
**not** change the epoch (they produce `gap`, C6-T02).

**Reader** (`Aiur.Events.Export.read/3`, C6-T02 interface; the client's
last epoch is compared by the caller, C7, which passes it as an option to
`Reader.read/4`):
- `epoch` given and ≠ current → `{:reset, %{oldest_seq, head_seq, epoch}}`.
- `after < oldest_seq - 1` → `{:reset, %{oldest_seq, head_seq, epoch}}`.
- `after > head_seq` → `{:reset, %{oldest_seq, head_seq, epoch}}` (cursor from a newer journal
  that no longer exists).
- else records with `seq > after`, at most `limit`, filtered by topic
  patterns (gap records are always included — a filter must not hide loss).

## Implementation steps

1. `Layout.trim!/2` (pure decision function over a segment list + meta +
   clock, returning the files to delete and the new meta) — unit-testable.
2. Exporter calls it after roll and at boot; writes meta then unlinks.
3. Epoch creation/archival in exporter boot.
4. `Reader` reset rules; gap records bypass topic filters.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Clock steps back | trim by age may pause (nothing looks old); count bound still applies |
| Clock steps forward | age trim may delete early; client sees `reset` — safe direction |
| Unlink fails | log warning, keep file, retry next trim; meta already moved `oldest_seq` forward (reader may `reset` early: safe) |
| Meta corrupt, segments readable | rebuild `oldest_seq`/`head_seq` from segment names and first/last lines; the old epoch is unknowable, so write a new random epoch **without** archiving segments; clients holding the old epoch get one `reset` (safe direction). Tested |
| Retention 0 / misconfig | prevented by C6-T01 validation |

## Compatibility and rollout

Off by default. Changing retention takes effect at the next trim. Rollback:
revert; segments remain readable.

## Verification

`test/aiur/events/export/retention_test.exs` (pure `trim!/2` with an
injected clock and synthetic segment metadata) and exporter integration:

1. `"trims whole closed segments by age and never the active one"`.
2. `"trims by count when age allows keeping more"`.
3. `"retained segment bytes are unchanged after trim"` — hash every retained
   file before/after. **Fails** if trim is implemented by rewriting.
4. `"meta oldest_seq moves before unlink"` — inject an unlink failure; meta
   already updated; reader returns `reset` for `after = old_oldest`.
5. `"stale cursor gets exactly one reset record"` (`after` below oldest) and
   `"cursor beyond head gets reset"`.
6. `"restart keeps the epoch; identity change creates a new epoch and archives segments"`.
   **Fails** if a restart regenerates the epoch (mutation).
7. `"gap records pass topic filters"`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/export/retention_test.exs test/aiur/events/export/exporter_test.exs
```

Mutation checks: regenerate epoch on every boot → test 6 fails; let the
topic filter drop `gap` → test 7 fails; unlink before meta write → test 4 fails.

## Completion and handoff

- [ ] Tests 1–7 added and mutation-checked.
- [ ] Docs: the `configuration.md` rows from C6-T01 already explain the
      reset; add one sentence to the C6-T02 "Export journal" paragraph on
      epoch/reset.
- Dependents: C6-T04 (reset handling), C7-T01/T02 (reset records),
  MP-N5 (no burst after reconnect).
