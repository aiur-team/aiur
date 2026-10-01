---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created_at: 2026-10-01
author: claude-haiku-4-5-20251001
---

# Fix Stale Attention Alerts That Outlive Their Conditions

## Summary

Attention alerts (user-facing notifications requiring Executor action) are emitted when conditions occur but are never resolved when those conditions clear, causing stale attentions to persist forever in the alert ledger. This teaches operators to discount the alerts, making them useless for real problems.

This fix adds resolution emission logic for four critical attention types, ensuring each alert clears cleanly when its condition resolves.

**Scope:** Fix `state-label-missing` and `error-retry_exhausted` attentions (high-impact). Defer `unsupported_model` and `model_label_unresolved` to follow-up PR. Add pattern-detection tooling to prevent regression.

---

## Problem Frame

Three instances in 24 hours (#2799, #2811 open, #2819) of alerts that fire correctly but never clear, leaving stale attentions in the durable ledger. The alert ledger (`AlertLedger`) preserves attentions across restarts, so a missing resolution means the attention stays active forever—not for this session, but indefinitely.

Current pattern:
1. Condition occurs (ticket state label missing, retry exhausted, unsupported model)
2. Code emits attention alert with `needs_attention: true`
3. Condition resolves (label restored, ticket moved out of error, model supported)
4. **No resolved alert is emitted** → attention stays active in ledger
5. Operator learns to ignore the alert → real instances go unnoticed

---

## Requirements

1. Each attention type that fires must have a matching resolution path that emits with `.resolved` suffix and `needs_attention: false`
2. Resolution must be emitted exactly when the condition clears, not speculatively
3. Must not regress: future attention code should have obvious gaps detected early
4. Tests must prove both fire and clear paths work for each attention type

---

## Key Technical Decisions

- **Inline resolution emission** (not a post-hoc reconciler) — when the code that resolves the condition runs, emit the resolved alert immediately. This keeps the resolution logic at the point of knowledge.
- **Same module owner** — attentions and their resolutions live together. If module A emits an attention, module A must emit its resolution (or document why A depends on B for resolution).
- **Two-phase implementation** — Phase 1 (HIGH priority): state-label-missing, error-retry_exhausted. Phase 2 (deferred): unsupported_model, model_label_unresolved.

---

## High-Level Technical Design

```
Attention Lifecycle (after fix):

Condition fires
  ↓
emit_system("ticket.N.agent.attention.TYPE", needs_attention: true, ...)
  ↓
Condition persists [no change]
  ↓
Condition resolves
  ↓
emit_system("ticket.N.agent.attention.TYPE.resolved", needs_attention: false, ...)
  ↓
AlertLedger: active attention removed, resolution recorded as cleared state
```

### Resolution Triggers by Type

| Attention | Emitted When | Resolved When | Location |
|-----------|--------------|---------------|----------|
| `state-label-missing` | Ticket dispatch-invisible (no state label) | State label restored & confirmed stable | `issue_sync.ex` |
| `state-label-missing-no-evidence` | Attempted recovery of stranded ticket | No follow-up evidence of same problem | `issue_sync.ex` |
| `error-retry_exhausted` | Retry exhaustion moves ticket to error | Ticket moved out of error state | `retry_engine.ex` / state transition handler |
| `unsupported_model` | Agent model not in registry (deferred) | Model becomes available or ticket closed | `session_lifecycle.ex` |
| `model_label_unresolved` | Model label cannot be resolved (deferred) | Label becomes resolvable on next refresh | `model_label_refresh.ex` |

---

## Implementation Units

### U1. Fix `state-label-missing` attention resolution

**Goal:** Emit resolved alert when a missing state label is repaired and confirmed stable.

**Requirements:** R: attention clears when label restored

**Dependencies:** None (self-contained)

**Files:**
- `src/lib/aiur/orchestrator/issue_sync.ex` (modify alert emission + add resolution)
- `src/test/aiur/orchestrator/issue_sync_test.exs` (add test)

**Approach:**
1. Locate `alert_missing_state_label_repaired/2` where the initial attention is emitted (line ~516)
2. Add tracking: record that this attention was emitted for this ticket
3. On next poll cycle after repair: if the label is now stable and present, emit the resolved alert
4. Use `AlertFeed.active_ticket_attention?/2` to check if the original alert is still active before emitting resolution (prevents duplicate resolutions)

**Patterns to follow:**
- Mirror `pause_attention_topic` pattern in `operator_messages.ex` for topic naming
- Follow `emit_system` call signature from `status_report.ex` line 1345 (waiting_for_human resolution)
- Use `needs_attention: false` and `.resolved` suffix convention

**Test scenarios:**
1. **Happy path — alert fires and clears:** Ticket with no state label triggers attention, label is added, next poll emits resolution
2. **Edge case — alert fires but label still missing:** Ticket with no state label triggers attention, no follow-up repair, no resolution emitted
3. **Integration — resolution prevents re-firing:** After resolution emitted, a second missing-label incident fires a new attention (not duplicate of resolved one)

### U2. Fix `error-retry_exhausted` attention resolution

**Goal:** Emit resolved alert when a ticket moves out of error state (manual retry or Executor action).

**Requirements:** R: attention clears when error condition resolves

**Dependencies:** U1 (test pattern reference only, no code dependency)

**Files:**
- `src/lib/aiur/orchestrator/retry_engine.ex` (modify alert emission + add resolution)
- `src/lib/aiur/orchestrator/dispatcher.ex` or state transition handler (add resolution emit)
- `src/test/aiur/orchestrator/retry_engine_test.exs` (add test)

**Approach:**
1. Locate `retry_exhausted_error_suffix/1` context where error-retry_exhausted is emitted (line ~874)
2. When the ticket is moved OUT of error state (by manual retry, Executor action, or recovery), emit the resolved alert
3. Hook into the state-transition code that changes issue state FROM error → (todo/in-progress/etc)
4. Guard: only emit resolution if the original error-retry_exhausted attention was active

**Patterns to follow:**
- Follow `pause_attention_topic` pattern for topic naming (same as U1)
- Use `emit_system` signature from status_report.ex
- Mirror resolution guard pattern from operator_messages.ex line 941-943 (check `previous_pause_reason` before emitting `.resolved`)

**Test scenarios:**
1. **Happy path — error fired then manually retried:** Ticket hits retry exhaustion, attention emitted, manual retry changes state to "todo", resolution emitted
2. **Edge case — error fired but state doesn't change:** Exhausted ticket stays in error state, no premature resolution
3. **Integration — resolution blocks re-firing:** After resolution, if retry exhausts again, a new attention fires (not duplicate of old resolved one)

### U3. Add pattern-detection test helper

**Goal:** Make it obvious to reviewers when a new attention is emitted without a matching resolution path.

**Requirements:** R: prevent regression; catch missing resolutions in review

**Dependencies:** U1, U2 (will test against fixed code)

**Files:**
- `src/test/aiur/alerts_test.exs` (add new test module or section)
- Optional: add Credo rule or lint check if repo uses static analysis for this

**Approach:**
1. Create a test that searches `src/lib/aiur` for all attention emissions (grep for `.agent.attention.` in `Alerts.emit_*` calls)
2. For each attention found, verify a corresponding `.resolved` version exists in the codebase or is documented in a known-deferred list
3. Test must fail if new attentions are added without resolutions
4. Maintainable: hardcode the deferred list so the test knows which attention types are OK to leave unresolved (temporary)

**Patterns to follow:**
- Similar to existing `src/test/aiur/decision_metrics_test.exs` (line ~79) which patterns-matches alert topics
- Use `File.stream!` and `Regex` to find `Alerts.emit` calls
- Store known-deferred list as a module attribute so future PRs can update it

**Test scenarios:**
1. **Happy path — new attention has resolution:** Code adds `ticket.N.agent.attention.new_type` and `ticket.N.agent.attention.new_type.resolved`, test passes
2. **Fails — new attention without resolution:** Code adds `ticket.N.agent.attention.new_type` alone, test fails with "missing resolution for attention type: new_type"
3. **Documented defer — explicitly allowed:** Deferred list includes `unsupported_model`, test passes even though resolution is missing

---

## Scope Boundaries

### In Scope
- Fix resolution emission for `state-label-missing` and `error-retry_exhausted` (high-impact)
- Add tests demonstrating fire + clear for each type
- Pattern-detection tooling to prevent regression

### Deferred to Follow-Up Work
- Fix `unsupported_model` and `model_label_unresolved` (medium priority, same pattern)
- Operator tooling to manually clear stale attentions from existing ledgers (operational maintenance)
- Comprehensive audit of all other attention types in codebase (discovery work for future PR)

### Outside This Fix
- Changes to alert ledger persistence or retention (separate infrastructure concern)
- Dashboard/UI changes to surface attention states (if needed, separate PR)

---

## Verification Contract

Each implementation unit is complete when:

**U1 (state-label-missing):**
- ✅ Attention emits when label is missing and dispatch returns nil
- ✅ Resolution emits when label is restored and confirmed in next poll
- ✅ Resolution is not emitted speculatively (label removed again → no double-clear)
- ✅ Test: `test_state_label_missing_fires_and_clears` passes

**U2 (error-retry_exhausted):**
- ✅ Attention emits when ticket moved to error state via exhaustion
- ✅ Resolution emits when ticket state changes OUT of error (manual retry, recovery)
- ✅ Resolution guarded: only emits if original attention was active
- ✅ Test: `test_error_retry_exhausted_fires_and_clears` passes

**U3 (pattern detection):**
- ✅ New test runs in affected-test suite
- ✅ Test fails when a new attention lacks a `.resolved` counterpart
- ✅ Test passes when known-deferred list is updated
- ✅ Test: `test_attention_resolution_patterns_complete` passes

---

## Definition of Done

- [ ] Both implementation units (U1, U2) have matching resolve emits
- [ ] All new tests pass locally (`mix test --max-cases 4 <test-files>`)
- [ ] Affected-test suite passes (`mix aiur.affected_tests`)
- [ ] Pattern-detection test added and passing (U3)
- [ ] No refactoring: only add resolution logic, don't rename or restructure existing alert code
- [ ] PR body cites this plan and references ticket #2819

---

## Risk Analysis & Mitigation

| Risk | Mitigation |
|------|-----------|
| Missed resolution triggers | Pattern-detection test (U3) catches new gaps; review examines resolution-emission guards carefully |
| Over-eager resolution emission | Guard each resolution with `AlertFeed.active_ticket_attention?/2` so no duplicate resolutions |
| Regression on other attention types | Deferred list documented; future PR follows same pattern |

---

## Documentation & Operational Notes

- Update `CONTRIBUTING.md` section on attention lifecycle if it exists; otherwise add a note: "Attention alerts must have both fire and clear paths in the same module"
- No user-facing docs needed (internal engineering pattern fix)
- Alert definitions in `.aiur/alerts` are already generic; no changes needed there

---

## Sources & Research

- Code review of `alerts.ex`, `alert_ledger.ex`, `alert_feed.ex` (alert system mechanics)
- Investigation of 4+ attention emission sites
- Existing resolution patterns in `operator_messages.ex`, `status_report.ex`, `pause_resume.ex`
- Issue #2799, #2811, #2797 context (same pattern class)

