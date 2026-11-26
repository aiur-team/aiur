---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created: 2026-10-01
title: Fix Operator Refusal Durability
---

# Fix Operator Refusal Durability

Make refusals of trusted operator input durable and visible to operators regardless of whether `--debug` is enabled.

---

## Goal Capsule

**Objective:** Replace silent Logger.info refusal records with durable alert emission, so operators can distinguish "comment never arrived" from "comment arrived but was refused" without needing to enable `--debug`.

**Success:** Five refusal sites in `comment_wake.ex` and any other refusal-only Logger sites emit structured alerts with actionable remedy guidance, independent of logging configuration.

**Authority:** Issue #2797; motivated by two 2026-09-24 incidents where refusal silence blocked diagnosis.

**Open Blockers:** None.

---

## Problem Frame

When Aiur receives a trusted operator instruction (e.g., a comment requesting rework, a review state change) and decides not to act on it, that refusal is recorded **only** via `Logger.info`. Without `--debug`, both file and console log handlers are removed, leaving no durable trace anywhere.

An operator who sees no response cannot know whether:
- The comment never arrived (needs troubleshooting at the integrations layer)
- The comment arrived but was refused by a gate (needs to adjust their request or accept the decision)

These are opposite problems with opposite fixes. A refusal recorded only in Logger is worse than no record at all — the absence proves nothing.

**Cost:** Incident 1 (2026-09-24) found a ticket held by dispatch authorization `:deferred` (no alert, no status record). Incident 2 found six tickets stuck on rework-gate refusals with no visible signal whether the comments reached the daemon at all. Both required `--debug` restart to diagnose.

---

## Requirements

### Functional Requirements

1. **Durability:** Refusals are recorded and queryable regardless of `--debug` state. No dependency on Logger file/console handlers.
2. **Structured:** Refusal records carry issue ID, source (comment author, Executor, etc.), reason (gate category), remedy (what to do instead), and timestamp.
3. **Visibility:** Refusals surface as alerts in the Executor's dashboard and alert feed, not only in offline logs.
4. **Discoverability:** Operators can search refusal alerts by issue, source, or reason using existing alert subscriptions and topic patterns.
5. **Actionability:** Remedy field includes specific guidance per gate. Example: rework gate refusal includes `"use: gh pr review --request-changes"`.

### Scope

1. Identify and convert the five refusal sites named in #2797 (comment_wake.ex):
   - "#{source} ignored for idle issue: … reason=…"
   - "#{source} rework gate skipped; issue state could not be resolved: …"
   - "#{source} ignored for inactive issue: …"
   - "#{source} rework transition skipped; state update failed: …"
   - "#{source} waking without rework write: …"

2. Sweep the codebase for other `Logger.info` / `Logger.warning` calls that are the **sole record** of a refusal. Convert all found refusals.

3. Write tests validating alerts emit without `--debug`.

### Non-Goals

- Changing `--debug` behavior or logging defaults
- Adding new logging modes or log levels
- Storing refusals in a separate database or event stream beyond the existing alert infrastructure
- Changing how ordinary chatter (non-refusal logs) are handled

### Acceptance Examples

1. **AE1:** Operator makes a comment requesting rework. The rework gate refuses because the issue is paused. An alert fires with topic `comment_wake.refused.paused` and payload containing the issue ID, reason, and remedy. The operator sees the alert in the dashboard.
2. **AE2:** Operator makes a comment on an inactive issue. The wake gate refuses. An alert fires with topic `comment_wake.refused.inactive` and payload containing issue ID and remedy. The operator can query refusal alerts and find this event.
3. **AE3:** A sweep of the codebase finds 2 other refusal-only Logger sites in orchestrator code. They are converted to alert emission using the same pattern.
4. **AE4:** Test suite runs with `--debug` off. Refusal alerts still emit and are captured by the test alert spy. Test passes.

### Success Criteria

- [ ] Five comment_wake.ex refusal sites emit structured alerts instead of Logger.info
- [ ] Codebase sweep finds and converts all other refusal-only Logger sites
- [ ] Refusal alerts are queryable via topic and issue ID
- [ ] Test coverage validates alert emission without `--debug`
- [ ] All existing tests pass (no regressions)

---

## Product Contract

### Key Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Use `Alerts.emit_custom` for refusal recording | Proven pattern already in use in dispatch_authorization.ex and dispatcher.ex; immediately visible to operators; independent of logging configuration; no new infrastructure |
| D2 | Alert topic naming: `<source>.refused.<reason>` (e.g., `comment_wake.refused.idle_issue`, `dispatch.refused.unauthorized`) | Follows existing dispatch_authorization pattern; scoped by source module for discoverability; distinct from dispatch_decline topics |
| D3 | Payload structure: `{issue_id, source, reason, remedy, timestamp}` | Matches dispatch_decline precedent established in #2793; remedy field addresses #2798 feedback for actionable guidance |
| D4 | Reason categorization: use structured atoms (`:idle_issue`, `:inactive_issue`, etc.) not string literals | Enables reliable filtering and aggregation; consistent with existing gate reason categorization |

### Scope Statement

**In Scope:**
- Replace Logger.info calls recording refusals with `Alerts.emit_custom` calls
- Design and implement alert topic naming and payload schema
- Identify and convert all refusal-only Logger sites via codebase sweep
- Add test coverage for alert emission without `--debug`

**Deferred for Later / Out of Scope:**
- Changing the `--debug` flag behavior or creating new logging modes
- Storing refusals in event-publications.ndjson or a separate event stream (future enhancement if alert volume warrants)
- Alerting on non-refusal Logger.info calls (separate feature if useful)

---

## Implementation Units

### U1. Design Alert Topic and Payload Structure

**Goal:** Establish naming convention and payload schema for refusal alerts, validated against existing Aiur alert patterns.

**Requirements Addressed:** All; foundational for U2, U3

**Dependencies:** None

**Approach:**
- Study existing alert patterns in dispatch_authorization.ex (lines 666–694) and dispatcher.ex (lines 1312–1330)
- Review precedent: comment_wake.ex:892–898 already includes remedy guidance in alert payloads
- Define refusal alert topic namespace: `ticket.<id>.agent.attention.comment_wake_<reason>` (following existing ticket.agent.attention pattern)
- Design payload with `Alerts.emit_custom` keyword options: `issue:`, `reason:`, `needs_attention:`, `severity:`, `event_source:`
- Include remedy guidance in the `reason:` field as narrative explanation

**Patterns to Follow:**
- dispatch_authorization.ex:668–675: `Alerts.emit_custom(topic, message, issue:, reason:, needs_attention:, severity:)`
- dispatcher.ex:1318–1326: dispatch_decline pattern with `issue:`, `reason:`, `needs_attention:`, `event_source:`
- comment_wake.ex:892–898: existing remedy guidance example in alert reason field

**Files:** None (research and design only)

**Technical Design:**
```
Alert Topic Format (following existing ticket.agent.attention pattern):
  ticket.<issue_id>.agent.attention.comment_wake_<reason>

Examples:
  ticket.123.agent.attention.comment_wake_idle_issue
  ticket.123.agent.attention.comment_wake_inactive_issue
  ticket.123.agent.attention.comment_wake_paused

Alerts.emit_custom Call Pattern:
Alerts.emit_custom(
  "ticket.#{issue.id}.agent.attention.comment_wake_#{reason}",
  "Refusal message here",
  issue: issue.identifier,
  reason: "Detailed explanation and remedy guidance",
  needs_attention: false,            # refusals are informational, not high-alert
  severity: "info",
  event_source: :system
)

Remedy Guidance Pattern (from comment_wake.ex:892–898 precedent):
  reason: "Reason for refusal. Remedy: specific action to take next."
  Example: "Rework gate refused because no unresolved review threads exist. 
            Use `gh pr review --request-changes` to create a review request."
```

**Test Scenarios:**
1. Alert topics for each refusal reason follow the `ticket.<id>.agent.attention.comment_wake_*` naming convention
2. Payload via emit_custom includes issue identifier and reason string with remedy guidance
3. Remedy guidance is specific and actionable per refusal type
4. Alert severity is "info" (not warning) since refusals are expected gate behavior
5. `needs_attention: false` (refusals do not trigger high-alert status)

**Verification:** Review alert pattern against dispatcher.ex dispatch_decline and comment_wake.ex existing alert patterns; confirm naming follows ticket.agent.attention convention and remedy guidance matches #2798 feedback.

---

### U2. Refactor comment_wake.ex Refusal Sites

**Goal:** Replace Logger.info calls with Alerts.emit_custom for the five identified refusal sites, applying the U1 design.

**Requirements Addressed:** R1 (Durability), R2 (Structured), R3 (Visibility), R5 (Testing)

**Dependencies:** U1

**Approach:**
- Modify the five Logger.info calls in comment_wake.ex:
  1. **Line 602** (`maybe_transition_idle_issue_to_rework/5`): "ignored for idle issue"
  2. **Line 633** (`maybe_transition_idle_issue_to_rework/5`): "ignored for idle issue" (active case)
  3. **Line 870** (`refuse_active_comment_rework/5`): "rework write skipped for active issue"
  4. **Lines 1140–1142** (`dispatch_reworked_comment_issue/1`): "Trusted comment dispatch declined"
  5. **Line 1261** (`transition_and_revalidate_comment_reactivation/5`): "ignored for inactive issue"
- For each site:
  - Replace the Logger.info call with `Alerts.emit_custom` using the U1 pattern
  - Extract the refusal reason (e.g., `:idle_issue`, `:inactive_issue`, `:dispatch_policy_refused`)
  - Craft remedy guidance specific to the gate (e.g., "resolve issue pause", "use `gh pr review --request-changes`")
  - Call: `Alerts.emit_custom("ticket.#{issue.id}.agent.attention.comment_wake_#{reason}", message, issue:, reason:, needs_attention: false, severity: "info", event_source: :system)`
- Add test coverage validating each refusal emits the correct alert (see U4)

**Patterns to Follow:**
- dispatch_authorization.ex line 666–675: exact `Alerts.emit_custom` call pattern with keyword options
- dispatcher.ex line 1318–1326: dispatch_decline alert with `issue:`, `reason:`, `needs_attention:`, `severity:`
- comment_wake.ex line 892–898: existing precedent for remedy guidance in alert reason field

**Files:**
- `src/lib/aiur/orchestrator/comment_wake.ex` — modify refusal Logger.info sites (lines 602, 633, 870, 1140–1142, 1261)
- `src/test/aiur/orchestrator/comment_wake_test.exs` — extend existing tests or add new ones for alert emission coverage (see U4)

**Test Scenarios:**
1. **Idle issue refusal (line 602):** Refusal emits alert topic `ticket.XX.agent.attention.comment_wake_idle_issue`, payload with remedy guidance
2. **Idle issue refusal active case (line 633):** Emits same topic and payload as above
3. **Rework write skipped (line 870):** Emits `ticket.XX.agent.attention.comment_wake_benign_comment`, remedy: reason for benign comment
4. **Dispatch policy refused (lines 1140–1142):** Emits `ticket.XX.agent.attention.comment_wake_dispatch_policy_refused`, includes state context and remedy
5. **Inactive issue refusal (line 1261):** Emits `ticket.XX.agent.attention.comment_wake_inactive_issue`, remedy guidance
6. **Alert emission without --debug:** Test suite disables Logger handlers; alerts still emit and are captured by alert spy
7. **Remedy accuracy:** Each refusal's remedy field matches the gate's recommended action per #2798 guidance
8. **Backward compatibility:** Existing comment_wake behavior unchanged (comments still not acted on; refusal record changes Logger → Alert)

**Execution Note:** Implement test-first: write a failing test for each refusal scenario that expects an alert (using alert spy), then add the alert emission code.

**Verification:**
- Grep: `Logger.info` returns zero matches at lines 602, 633, 870, 1140–1142, 1261
- Test: Run comment_wake tests; all pass, alerts captured by spy
- Integration: Full comment_wake test suite passes; no regressions

---

### U3. Sweep Codebase for Other Refusal-Only Logger Sites

**Goal:** Identify and convert all other Logger.info/warning calls that are the sole record of a refusal of trusted input, applying the U1/U2 pattern.

**Requirements Addressed:** R1, R2, R4 (Scope)

**Dependencies:** U1, U2

**Approach:**
1. Search codebase for Logger.info/warning calls using keywords: "refused", "ignored", "declined", "skipped", "rejecting" in context of trusted operator input
2. For each match, categorize:
   - Is it a refusal of trusted input (operator action)?
   - Or is it ordinary debug/chatter logging?
3. For true refusals, apply the U2 pattern:
   - Categorize reason into an atom
   - Design remedy guidance specific to that gate
   - Replace Logger with `Alerts.emit_custom`
   - Add test coverage
4. For non-refusal chatter, leave unchanged

**Files:**
- TBD by sweep results; likely candidates: src/lib/aiur/orchestrator/dispatch.ex, other orchestrator modules, gate-enforcement code
- Corresponding test files for any modified modules

**Test Scenarios:**
- Each refusal-converted site emits correct alert topic and payload
- Non-refusal Logger.info calls are untouched
- All existing tests for modified modules pass
- Alert spy captures converted refusals

**Verification:**
- Grep: `mise exec -- rg -n "Logger\.(info|warning)" src/ | grep -E "(refused|ignored|declined|skipped)"` — confirm no matches that represent sole refusal records
- Test: Modified test suites pass; no regressions

---

### U4. Write Explicit Refusal Alert Test Suite

**Goal:** Add comprehensive test coverage validating refusal alerts emit correctly without `--debug`.

**Requirements Addressed:** R1 (Durability), R3 (Visibility), R5 (Testing)

**Dependencies:** U2, U3

**Approach:**
- Create a new test module or extend alert test coverage to specifically target refusal alert emission
- Test both comment_wake refusals (U2) and other refusals (U3)
- Mock or disable log handlers to simulate `--debug off` scenario
- Validate alert payload structure, topic naming, remedy content
- Confirm alerts are emitted *before* silent refusal occurs (temporal ordering)

**Files:**
- `src/test/aiur/alerts/refusal_alerts_test.exs` (new, or extend existing alert test module)

**Test Scenarios:**
1. **No log handler dependency:** Refusal alerts emit and are captured even when Logger file/console handlers are disabled
2. **Payload completeness:** Alert payload includes issue_id, issue_identifier, source, reason, remedy, timestamp — all with correct types
3. **Topic correctness:** Alert topic matches `<module>.refused.<reason>` pattern
4. **Remedy presence and specificity:** Remedy field is non-empty and specific to the refusal gate
5. **Temporal ordering:** Alert is emitted and visible before the refusal takes effect (operator sees the alert immediately, not after-the-fact)
6. **Alert subscription filtering:** Operators can filter by topic pattern `"comment_wake.refused.*"` or by issue_id
7. **Cross-refusal consistency:** All refusals (comment_wake and swept) follow the same payload schema and topic naming

**Execution Note:** Build an alert-spy test helper that captures emitted alerts and allows assertions on topic, payload, and content.

**Verification:**
- Test runs with `--debug off`; passes
- Alert assertions cover all payload fields
- Test file is discoverable and run by CI

---

### U5. Validate No Regressions

**Goal:** Run affected test suites to confirm no unintended behavior changes.

**Requirements Addressed:** R5 (Testing)

**Dependencies:** U2, U3, U4

**Approach:**
- Run tests for all modified modules (comment_wake.ex, and any swept modules)
- Use `mix aiur.affected_tests` to determine the scoped test set
- Run the full test suite if any warnings surface

**Files:**
- Test files for comment_wake.ex: `src/test/aiur/orchestrator/comment_wake_test.exs`
- Test files for any swept modules: TBD by sweep

**Test Scenarios:**
- All existing comment_wake tests pass (no behavior changes)
- All existing alert/dispatch tests pass
- No new test failures introduced

**Verification:**
- Command: `cd src && mix test --max-cases 4` (scoped set from affected_tests)
- Result: Green; no failures

---

## High-Level Technical Design

**Alert Emission Pattern:**

```
comment_wake.ex refusal site (simplified)
├─ Evaluate gate condition (idle? inactive? state update failed?)
├─ If gate refuses:
│  ├─ Emit alert via Alerts.emit_custom
│  │  ├─ Topic: "comment_wake.refused.<reason>"
│  │  ├─ Payload: {issue_id, source, reason, remedy, timestamp}
│  │  └─ Message: human-readable description
│  └─ Do NOT act on comment (existing behavior preserved)
└─ End
```

**Alert Flow:**

```
1. Refusal gate in comment_wake.ex evaluates operator input
2. If gate refuses:
   - Alerts.emit_custom(topic, message, payload) ← durable, visible, no Logger dependency
   - Return {:skip, reason} (comment not acted on)
3. Alert delivered to:
   - Executor dashboard (topic subscription)
   - Alert feed (queryable by issue_id, reason, remedy)
   - Offline: alert event log (if configured)
4. Operator sees alert immediately and can query by issue/source/remedy
```

---

## Verification Contract

**How to know this work is complete:**

1. **comment_wake.ex refusals are durable:**
   - Grep: `rg "Logger\.(info|warning)" src/lib/aiur/orchestrator/comment_wake.ex` returns zero matches for refusals
   - Test: Run comment_wake tests with `--debug off`; refusal alerts are captured

2. **Alert structure is consistent:**
   - Topic: `<module>.refused.<reason>` format across all refusals
   - Payload: includes issue_id, source, reason, remedy, timestamp (all refusals)
   - Remedy: specific, actionable guidance for each gate

3. **Sweep completed:**
   - Grep: `rg -n "Logger\.(info|warning)" src/ | grep -iE "(refused|ignored|declined|skipped)"` shows no refusal-only Logger sites
   - All found refusals converted to alert emission

4. **Test coverage:**
   - `src/test/aiur/alerts/refusal_alerts_test.exs` exists and passes with `--debug off`
   - Tests validate payload structure, topic naming, remedy content, and alert spy captures

5. **No regressions:**
   - `cd src && mix aiur.affected_tests` command output shows green
   - All comment_wake, alert, dispatch tests pass

---

## Definition of Done

- [ ] U1 design validated against existing alert patterns
- [ ] U2 comment_wake refusals converted to alert emission (5 sites)
- [ ] U2 tests passing (comment_wake behavior unchanged, alerts emitted)
- [ ] U3 codebase sweep completed; all refusal-only Logger sites identified and converted
- [ ] U3 tests passing for all modified modules
- [ ] U4 refusal alert test suite written and passing (with `--debug` off)
- [ ] U5 regression validation: `mix aiur.affected_tests` passing for all modified modules
- [ ] No new test failures introduced
- [ ] All PR review feedback addressed

---

## Sources & Research

- **#2797 Issue:** Refusals of trusted operator input disappear when `--debug` is off
- **#2793 PR:** Fixed dispatch authorization deferred state silence via dispatch_decline recording
- **#2798 PR:** Context on remedy guidance requirement and rework gate refusal patterns
- **dispatch_authorization.ex:** Existing alert pattern (lines 625–675)
- **dispatcher.ex:** Dispatch_decline recording pattern (lines 1312–1330)
