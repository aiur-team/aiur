---
title: "Bounded Alert Ledger - Plan"
type: fix
created_at: 2026-08-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Bounded Alert Ledger - Plan

## Goal Capsule

- **Objective:** Keep project alert persistence and every control-path read bounded while prioritizing unresolved attentions and visibly degrading if actionable state alone exceeds the ceiling.
- **Authority:** Issue #1661 and the existing `Aiur.AlertLedger` / `Aiur.AlertFeed` lifecycle semantics are authoritative.
- **Stop conditions:** Do not add operator configuration, scan workspace transcripts on normal reads, or change firing/resolution behavior within the retained window.
- **Tail ownership:** Implementation includes focused persistence and feed tests, the scoped local gate, draft PR self-review, and CI handoff.

---

## Product Contract

### Summary

The project alert ledger uses a fixed internal byte ceiling. Appends that would cross it atomically replace the file with a compacted projection, while alert-feed callers decode only a bounded tail.

### Problem Frame

The project ledger removed control-RPC scans of multi-gigabyte agent transcripts, but it is itself append-only. Boot backfill can seed its full history, and every `AlertFeed.list/1` or condition-state query currently streams the entire ledger.

### Requirements

- R1. Keep the live project ledger at or below a fixed byte ceiling after every successful append or explicit boot compaction; reject an indivisible alert record larger than that ceiling.
- R2. Compact by atomic replacement under the existing per-path append lock so concurrent appends are not lost and readers never observe a partial rewrite.
- R3. Retain the newest record and currently unresolved attention records first, then fill the remaining retention budget with the newest history in chronological order; if active state alone exceeds the budget, retain the newest active records and log a warning naming the dropped count.
- R4. Make normal feed, attention, and condition-state reads consume no more than the fixed ledger byte ceiling while preserving malformed-line fail-soft behavior.
- R5. Run compaction during boot backfill even when the durable backfill marker already exists, so installations upgrade without waiting for another alert.
- R6. Treat resolved-condition state as retained history: once its latest transition ages out, `condition_state/2` may return `:unknown` and a restarted emitter may publish one fresh resolution transition.

### Acceptance Examples

- AE1. Appending across a small injected ceiling rewrites the ledger at or below that ceiling and preserves the new alert.
- AE2. An unresolved attention older than the recent history survives compaction; once a later resolution exists, it no longer receives retention priority.
- AE3. A concurrent append cannot disappear while another process triggers compaction.
- AE4. A feed read of an oversized legacy file drops a partial prefix, decodes only complete retained-tail records, and preserves chronological presentation.
- AE5. Appending one encoded alert larger than the ceiling returns a record-too-large error and leaves the previous ledger unchanged.

---

## Planning Contract

### Key Technical Decisions

- KTD1 — Bound bytes, not only record count. The incident is multi-gigabyte control-plane I/O, so the on-disk and read limits use one fixed internal byte ceiling; this avoids a new configuration and directly caps the dependency.
- KTD2 — Compact before the append becomes visible. Under the existing path-keyed append lock, append normally below the ceiling or atomically write a compacted projection that already includes the new record. This avoids exposing an oversized intermediate file.
- KTD3 — Preserve actionable state before history. Compaction derives current unresolved attentions from chronological alert records, reserves space for those records and the newest event, then uses remaining space for recent history. If actionable records alone exceed the budget, keep the newest records that fit and log the overflow; do not silently claim lossless retention.
- KTD4 — Reuse established filesystem patterns. Follow `Aiur.DecisionMetrics.Log` for bounded EOF-tail reads and `Aiur.Fs.atomic_write/3` for replacement rather than introducing another persistence primitive.
- KTD5 — Reject oversized records. An indivisible alert larger than the ceiling cannot be both persisted and read within the same strict byte bound, so return an explicit error before mutating the ledger.

### Risks & Dependencies

- Retention necessarily forgets old resolved-condition state. Duplicate-resolution suppression remains exact inside the retained window and may permit one fresh transition after that state ages out.
- Compaction is a rare full-ledger operation on the write/backfill path; normal control reads remain bounded and do not perform semantic compaction.

### Sources & Research

- `src/lib/aiur/alert_ledger.ex` owns path-keyed re-entrant append locking and the independent backfill lock.
- `src/lib/aiur/decision_metrics/log.ex` provides the existing raw EOF-tail and atomic compaction pattern.
- `src/lib/aiur/fs.ex` guarantees old-or-complete visibility for sibling-temp-file replacement.
- No `CONCEPTS.md` or `docs/solutions/` corpus exists in this checkout. External research is unnecessary because the repository already contains the required persistence primitives.

---

## Implementation Units

### U1. Bound and compact ledger persistence

- **Goal:** Enforce the byte ceiling while preserving the newest actionable projection.
- **Requirements:** R1, R2, R3, R5, R6
- **Files:** `src/lib/aiur/alert_ledger.ex`, `src/lib/aiur/alert_feed.ex`, `src/test/aiur/alert_feed_test.exs`
- **Approach:** Add lock-aware compaction and bounded-tail helpers to `AlertLedger`; select retained decoded records by newest event, active attention state, and recent-history priority; invoke explicit compaction from boot backfill before deciding whether legacy seeding is complete.
- **Test Scenarios:** Cross an injected small ceiling and assert the latest record plus unresolved attention survive; add a resolution and assert the resolved attention loses priority; overflow the active-state budget and assert the newest active records survive with a warning; reject a single oversized encoded record without changing the file; run simultaneous appends where one triggers compaction and assert both retained records remain; compact an already-backfilled oversized ledger during boot.
- **Verification:** Focused alert-feed tests prove file bounds, atomic lifecycle preservation, and boot upgrade behavior.

### U2. Route feed reads through the bounded tail

- **Goal:** Remove full-ledger reads from all control paths.
- **Requirements:** R4
- **Dependencies:** U1
- **Files:** `src/lib/aiur/alert_feed.ex`, `src/test/aiur/alert_feed_test.exs`
- **Approach:** Replace whole-file `Jsonl.stream/1` calls for project-ledger reads with the shared bounded-tail decoder while leaving legacy backfill scans full-history and fail-soft.
- **Test Scenarios:** Read an oversized file whose byte boundary begins inside a record and assert only complete tail records appear; include malformed tail lines and assert they are skipped; prove `list/1`, `condition_state/2`, and duplicate-resolution detection use retained records in chronological order.
- **Verification:** Focused tests fail against the current whole-file implementation and pass with bounded reads.

---

## Verification Contract

- Compile with `cd src && mise exec -- mix compile --warnings-as-errors`.
- Run `cd src && mise exec -- mix format --check-formatted`.
- Compute the deterministic scope with `cd src && mise exec -- mix aiur.affected_tests`, then run every emitted test command with `mix test --max-cases 4`.
- Inspect the final diff for unrelated config or documentation surfaces; this internal control-plane fix should not require user-facing docs.

---

## Definition of Done

- R1-R6 and AE1-AE5 are implemented and exercised by collected tests.
- Normal alert-feed reads cannot stream beyond the internal ledger ceiling.
- Successful appends and boot backfill leave the ledger compacted without losing retained concurrent writes.
- Unresolved attention priority, visible active-state overflow, post-resolution eviction, and bounded resolved-state aging are covered.
- Scoped compile, format, and affected tests pass.
- The final diff contains no abandoned compaction variants or unrelated changes.
