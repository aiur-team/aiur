---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
deepened: null
---

# Optional Native Thread Compaction at Review Handoff - Plan

**Created:** 2026-10-01 · **Status:** Implementation-Ready

---

## Summary

Implement optional Codex-native thread compaction at the implementation-to-human-review handoff. Provide manual and threshold-based opt-in controls, preserve original transcripts with durable resume handles, track compaction state (pending/completed/failed/unsupported), and avoid repeating compaction on unchanged sessions. Acceptance requires native Codex integration, CLI/TUI approval surfaces, comprehensive test coverage for threshold, no-repeat, failure, restart, and unsupported-provider scenarios, and measured baseline before claiming cost savings.

---

## Problem Frame

Agent threads grow during implementation work, consuming tokens and increasing costs for reviewers who need to read the thread during human review. Codex supports native thread compaction via `thread/compact/start`, which can summarize intermediate work while preserving task constraints, decisions, and review-relevant evidence. Currently, Aiur has no compaction capability. This feature provides optional, backend-specific compaction at the handoff point, with explicit user control and full transparency about state.

---

## Requirements

**From Issue #2882:**
- Design and implement optional compaction at implementation-to-human-review handoff
- Support only verified native primitives (Codex); do not silently compact other backends
- Verify Codex `thread/compact/start` request, completion, restart, and failure behavior
- Provide manual opt-in control (CLI/TUI) and threshold-based auto-trigger (config)
- Preserve original transcript and durable resume handle; avoid repeating compaction on unchanged session
- Show compaction state: pending, completed, failed, unsupported
- Handoff summary must retain task constraints, decisions, revision, validation evidence, remaining review work
- Acceptance: native Codex integration with real CLI/TUI approval; tests for threshold, no-repeat, failure, restart, unsupported providers
- Treat cost savings as hypotheses requiring measured baseline and overhead assessment before claims

---

## Key Technical Decisions

1. **Codex-only scope**: Compaction only fires for Codex backend. Other backends show "unsupported" state but do not error or block handoff. Claude backend specifically must not attempt compaction.

2. **Config-driven triggers**: Compaction is opt-in via config. Two mechanisms: manual approval at CLI/TUI (always available when config enables compaction), and threshold-based auto-trigger (token count, elapsed time, or message count exceeding configured limits).

3. **State machine tracking**: Compaction states (pending → completed/failed) are persisted and visible to operator. Failed compaction does not block handoff; the session remains in "waiting" state, resumable without compaction.

4. **No repeat on unchanged session**: Once compaction completes for a session, a subsequent handoff without new agent messages skips compaction re-attempt. Threshold-based triggers check session change before firing.

5. **Transcript preservation**: Original uncompacted transcript is preserved as durable evidence. Compaction produces a summary artifact; both are available for review and resume.

6. **Handoff summary contract**: Compaction summary must explicitly retain task constraints, decisions made during the run, revision history markers, validation evidence (test pass/fail), and calls-to-action for remaining review work.

7. **Resume from compacted state**: When resuming a compacted thread, Codex automatically resumes from the compacted state. Original transcript is available separately for inspection; operator can choose to revert to original if needed.

---

## Scope Boundaries

### In Scope
- Codex backend compaction via `thread/compact/start`
- Manual approval at CLI/TUI before compaction fires
- Threshold-based auto-trigger (config-driven limits)
- State tracking and persistence (pending/completed/failed/unsupported)
- Original transcript preservation and resume handle
- Failure handling (timeout, API error, invalid state)
- Unsupported-provider detection and "unsupported" state display
- Tests for all acceptance criteria
- Config schema and documentation

### Out of Scope (Deferred to Follow-Up Work)
- Compaction for non-Codex backends (Claude, other providers)
- Automatic cost optimization based on compaction results (requires baseline measurement first)
- UI dashboard visualization of compaction state (CLI/TUI approval surfaces are sufficient for MVP)
- Compaction parameter tuning (summary length, focus areas) — Codex API defaults are acceptable
- Compaction scheduling or batching across multiple agents

---

## High-Level Technical Design

```
Agent Lifecycle with Compaction Integration:

  [Agent Working] (tokens accumulate)
       ↓
  [Agent → human-review label]
       ↓
  [Compaction Gate]
       ├─ Codex + config enabled → check threshold + session change
       ├─ Manual approval trigger → prompt operator
       ├─ Auto-trigger fires → request Codex compaction
       └─ Non-Codex → skip, state = "unsupported"
       ↓
  [Codex thread/compact/start]
       ├─ Success: state = "completed", summary stored
       ├─ Failure: state = "failed", retry available
       └─ Pending: state = "pending", can poll or proceed
       ↓
  [Resume: Codex automatically uses compacted state]
```

**Compaction State Persistence:**
- New `CompactionState` entity tracks: backend, trigger (manual/threshold), status, timestamp, summary, original-transcript-ref
- Stored in agent run logs and queryable by issue+agent identity
- Survives agent restart; resume queries compaction state before re-attempting

**Integration Points:**
1. `Agent.Orchestrator.agent_teardown` — detect human-review transition, trigger compaction gate
2. `Agent.Runner.session_lifecycle` — store compaction state, preserve transcript
3. `Codex.CompactorClient` (new module) — `thread/compact/start` request/poll/status
4. `Agent.Config` — new `compaction:` config block
5. Dashboard / CLI state display — show "compaction: completed/failed/pending/unsupported"

---

## Implementation Units

### U1. Define Compaction Schema and Config

**Goal:** Define data schema for compaction state, config structure, and persistence layer.

**Requirements:** R: optional compaction at handoff; A: Executor sees state; R: threshold + manual controls

**Dependencies:** None

**Files:**
- `src/lib/aiur/agent_compaction/schema.ex` (new) — CompactionState schema, type definitions
- `src/lib/aiur/agent_compaction/config.ex` (new) — config parsing, validation
- `src/lib/aiur/config.ex` — add `compaction:` config block to schema
- `priv/migrations/` — add compaction_state table migration
- `test/aiur/agent_compaction/` (new) — test fixtures

**Approach:**
- CompactionState tracks: session_id, backend, trigger_type (manual/auto_threshold), status (pending/completed/failed/unsupported), started_at, completed_at, summary_tokens, error_reason, compacted_transcript_ref, original_transcript_ref
- Config schema: `compaction: { enabled: bool, backends: [codex], manual_approval: bool, auto_trigger: { enabled: bool, token_threshold: int, message_count_threshold: int, elapsed_time_minutes: int } }`
- Persist to a new `compaction_states` table; queryable by issue+run+agent identity
- Config validation ensures only recognized backends in `backends:` list; defaults to [] (disabled)

**Patterns to follow:**
- Aiur config patterns from `Agent.Config` and `Codex.Config`
- Schema pattern from existing store entities (e.g., `Alert.Ledger`)
- Migration naming and structure

**Test scenarios:**
- Schema validates CompactionState creation with all fields
- Config parses manual/auto triggers separately
- Config validation rejects unknown backends
- Threshold values clamp to reasonable ranges (token_threshold >= 1000, elapsed_time_minutes >= 1)
- Migration creates table with correct indexes (session_id, status, created_at)

---

### U2. Implement Codex API Integration

**Goal:** Wrap Codex `thread/compact/start` API and handle request/response/polling/failure.

**Requirements:** R: verify request, completion, restart, failure; R: preserve original transcript and resume handle

**Dependencies:** U1

**Files:**
- `src/lib/aiur/agent_compaction/codex_client.ex` (new) — Codex integration, request building, polling
- `src/lib/aiur/agent_compaction/codex_client_test.exs` (new)

**Approach:**
- Codex client exposes: `request_compact(thread_id, summary_prompt, opts)` → async request, returns request_id
- `poll_status(thread_id, request_id)` → returns {status, summary, token_impact}
- `wait_for_completion(thread_id, request_id, timeout_ms)` → polls until done or timeout
- Handles Codex API error cases: rate limit (retry with backoff), invalid thread state (transient, fail gracefully), API unavailable (return error)
- Preserves original transcript_id returned by Codex; durable reference for resume
- Summary respects handoff constraints: includes task constraints section, decisions with timestamps, revision markers, test pass/fail evidence, remaining review work

**Patterns to follow:**
- Error handling from `Codex.UpdateRelay`
- Async request pattern from existing Codex integrations
- Telemetry emission for compaction requests/completions

**Test scenarios:**
- Successful compaction request and polling to completion
- Handles Codex API transient errors with backoff
- Timeout during poll returns :timeout, not :error
- Original transcript reference preserved in response
- Summary includes all required sections (constraints, decisions, evidence, review work)
- Non-Codex backend (Claude) raises informative error "compaction not supported for backend:claude"

---

### U3. Integrate Compaction into Agent Handoff Flow

**Goal:** Trigger compaction when agent transitions to human-review label, execute based on config/trigger, persist state.

**Requirements:** R: optional at handoff; R: manual + threshold triggers; R: avoid repeat on unchanged session

**Dependencies:** U1, U2

**Files:**
- `src/lib/aiur/orchestrator/agent_compaction.ex` (new) — orchestration logic, trigger evaluation
- `src/lib/aiur/agent_runner/compaction_handler.ex` (new) — session-level handoff integration
- `src/lib/aiur/orchestrator/agent_teardown.ex` — integrate compaction gate
- `test/aiur/orchestrator/agent_compaction_test.exs` (new)

**Approach:**
- When agent transitions to `agent:human-review`, `Agent.Orchestrator.agent_teardown` calls `Agent.Orchestrator.AgentCompaction.evaluate_trigger/2` (session, config)
- Evaluate: backend check (Codex only), config enabled, session change detection (no new messages since last compaction attempt)
- If threshold triggers: async spawn compaction request, return pending state
- If manual approval: prompt operator (CLI/TUI), await approval, then spawn request
- If unsupported backend or config disabled: state = unsupported, proceed without compaction
- Persist CompactionState; operator can query and see pending/completed/failed/unsupported
- Handoff is NOT blocked by compaction — proceed to human-review regardless of compaction state (failed compaction does not retry, unsupported shows why)

**Patterns to follow:**
- Orchestrator error handling and logging from existing teardown logic
- State machine pattern from `Agent.Orchestrator.TicketEventRouter`
- Operator messaging from existing alerts and CLI feedback

**Test scenarios:**
- Codex backend + config enabled + new messages → compaction triggers
- Codex backend + config enabled + no new messages since last attempt → skips repeat compaction
- Non-Codex backend → state = unsupported, handoff proceeds
- Config disabled → state = unsupported, handoff proceeds
- Manual approval gate: prompt fires, operator approve/deny, behaves accordingly
- Threshold not met (token count too low) → skips auto-trigger
- Compaction request fails → state = failed, handoff proceeds without blocking

---

### U4. Implement CLI/TUI Control Surfaces

**Goal:** Expose manual compaction approval and state inspection at CLI/TUI.

**Requirements:** A: real CLI/TUI approval; A: states visible to operator

**Dependencies:** U1, U3

**Files:**
- `src/lib/aiur/agent_control_cli.ex` — add `compaction` command/subcommands
- `src/lib/aiur_web/live/dashboard_live.ex` — display compaction state in agent list
- `src/lib/aiur/perf/compaction_intake.ex` (new) — telemetry and operator messaging
- `test/aiur/agent_control_cli_test.exs` — CLI compaction commands

**Approach:**
- CLI: `aiur agents compact <issue-id>` — manual request to compact the specified agent's thread
  - Queries current session, checks backend/config, prompts confirmation, submits async request
  - Returns immediately with pending state; operator can poll with `aiur agents status <issue-id>` to see completion
- CLI: `aiur agents status <issue-id>` — shows compaction state (pending/completed/failed/unsupported) + timestamp + error reason if failed
- TUI: Add "Compaction" column or row in agent list showing state icon (⏳ pending, ✓ completed, ✗ failed, ⊘ unsupported)
- Dashboard: Hover/click on compaction state shows summary stats (token reduction, timestamp, summary excerpt)

**Patterns to follow:**
- CLI command structure from existing agent control commands
- TUI state rendering from agent summaries module
- Dashboard telemetry from existing perf/alerts modules

**Test scenarios:**
- `aiur agents compact <issue-id>` with Codex backend + config enabled → submits request, returns pending
- `aiur agents status <issue-id>` after completion → shows "Compaction: completed, 2026-10-01 12:34:56 UTC, -45%"
- Manual compact on unsupported backend → error message "Compaction not supported for this backend"
- TUI renders state icon correctly for each state (pending/completed/failed/unsupported)
- Dashboard shows compaction state and summary excerpt on hover

---

### U5. Implement Resume Logic for Compacted Threads

**Goal:** When resuming an agent on a compacted thread, handle state correctly and preserve operator control.

**Requirements:** R: durable resume handle; R: preserve original transcript

**Dependencies:** U1, U2, U3

**Files:**
- `src/lib/aiur/agent_runner/session_resume.ex` — query compaction state, apply resume context
- `src/lib/aiur/agent_runner/turn_prompt.ex` — include compaction context in turn prompt
- `test/aiur/agent_runner/session_resume_test.exs` — resume with compacted threads

**Approach:**
- On agent resume, query CompactionState for the session
- If state = completed: load both compacted-thread reference and original-transcript reference from Codex; Codex resume naturally uses the compacted state
- Include in turn prompt (visible to agent): "Thread was compacted on [date]. Original transcript available in logs/original-transcript. You are resuming from the compacted state."
- Operator can manually request restore-to-original if needed (separate CLI command for later PR)
- If state = failed: show "Compaction failed on [date] with reason: [error]. Thread was not compacted. Resuming normally."
- If state = pending: show "Compaction in progress. Resuming with uncompacted thread."

**Patterns to follow:**
- Session resume pattern from `Agent.Runner.SessionResume`
- Turn prompt injection pattern from `Agent.Runner.TurnPrompt`
- Codex transcript reference handling

**Test scenarios:**
- Resume with state = completed: agent receives turn prompt acknowledging compaction
- Resume with state = failed: agent notified of failure; session state unchanged
- Resume with state = pending: agent resumes normally; compaction may still complete in background
- Original transcript reference preserved and queryable in logs

---

### U6. Add Comprehensive Test Coverage

**Goal:** Test all acceptance criteria: threshold triggers, no-repeat, failure handling, restart behavior, unsupported providers.

**Requirements:** A: tests for threshold, no-repeat, failure, restart, unsupported; R: avoid repeating compaction on unchanged session

**Dependencies:** U1–U5

**Files:**
- `test/aiur/agent_compaction/integration_test.exs` (new) — end-to-end workflows
- `test/aiur/agent_compaction/threshold_test.exs` (new)
- `test/aiur/agent_compaction/failure_restart_test.exs` (new)
- `test/aiur/agent_compaction/no_repeat_test.exs` (new)
- `test/aiur/agent_compaction/unsupported_backend_test.exs` (new)

**Approach:**
- **Threshold test**: Create session with token count at threshold, verify auto-trigger fires; below threshold, verify it does not fire; edge case: exactly at threshold
- **No-repeat test**: Trigger compaction successfully; handoff again without new messages; verify state skips repeat attempt; add new message; handoff again; verify re-attempt permitted
- **Failure/restart test**: Mock Codex API to return transient error; verify retry logic; then succeed; verify state transitions correctly
- **Restart test**: Compaction pending; restart agent; resume logic queries state correctly; compaction completes; resume reflects completion
- **Unsupported test**: Claude backend with config enabled; verify state = unsupported, handoff proceeds, no Codex call attempted

**Patterns to follow:**
- Fixture patterns from existing agent tests
- Codex mock/stub pattern from codex_update_relay_test
- State assertion patterns from orchestrator tests

**Test scenarios:** (detailed in each sub-test file)

---

### U7. Update Configuration Reference and CLI Docs

**Goal:** Document compaction config schema, CLI commands, and expected behavior.

**Requirements:** R: handoff summary retains task constraints, decisions, revision, validation evidence, remaining review work (via Codex summary contract)

**Dependencies:** U1–U5

**Files:**
- `website/docs-app/reference/configuration.md` — add `compaction:` config section
- `website/docs-app/reference/cli.md` — add `aiur agents compact` and `aiur agents status` commands
- `website/docs-app/concepts/compaction.md` (new) — explain compaction, transcript preservation, resume behavior
- `.aiur/config` — example compaction config (in repo)

**Approach:**
- Config reference: document `enabled`, `backends`, `manual_approval`, `auto_trigger` with defaults and constraints
- CLI reference: document `compact`, `status` subcommands, output format, exit codes
- Concepts page: explain what compaction does, when it triggers, what happens to transcripts, how to resume, cost implications, limitations (Codex only)
- Example config: show manual-only, threshold-based, and disabled configurations

**Patterns to follow:**
- Config reference format from existing config docs
- CLI command format from existing CLI docs

---

## Acceptance Criteria

- [x] **Native Codex integration**: `thread/compact/start` request/completion wire flow is integrated into the human-review handoff and exercised against a local JSON-RPC server.
- [ ] **Real CLI/TUI approval**: No per-ticket interactive approval command or prompt is implemented; the current manual opt-in is configuration-driven. Status appears in AgentList activity.
- [x] **Threshold-based triggering**: Cumulative token threshold is configurable and tested at the boundary; unchanged-thread attempts are deduplicated.
- [ ] **Failure and restart handling**: Request failure and missing completion are tested. Restart from a durable pending marker suppresses duplicate work, but interrupted-pending status recovery is not yet verified.
- [x] **Unsupported provider handling**: Non-Codex configured backends report unsupported and do not call a compaction primitive.
- [x] **Transcript preservation**: The original transcript and resume handle remain untouched; compaction only targets the existing Codex thread.
- [x] **State visibility**: Pending/completed/failed/unsupported status is projected into AgentList activity.
- [ ] **Handoff summary contract**: The native primitive takes only the thread ID, so this integration cannot enforce particular summary fields. The Agent Workpad remains the durable handoff record.
- [ ] **Comprehensive test coverage**: Focused wire, schema, threshold, deduplication, storage, and projection tests pass; full restart behavior and real foreground CLI/TUI approval remain unverified.
- [x] **No cost claims without baseline**: No savings claim is made; baseline, overhead, and feedback-resume latency remain unmeasured.

---

## Definitions of Done

- All implementation units (U1–U7) are complete and pushed
- All test scenarios pass (100% green on affected-test suite)
- Config reference and CLI docs are accurate and reviewed
- Concepts doc explains compaction behavior, limits, and expectations
- Codex API contract verified (request, response, status, error handling)
- CI passes (`mix compile --warnings-as-errors`, `mix format`, affected tests, `make ci`)
- Draft PR is open and ready for human review
- Compaction state is visible at CLI and TUI; operator can trigger and monitor

---

## Risks & Dependencies

| Risk | Mitigation |
|------|-----------|
| Codex `thread/compact/start` API contract changes | Verify API behavior before release; pin version if needed; wrap API in abstraction |
| Timeout during compaction blocks handoff | Async model; handoff proceeds regardless of compaction completion state |
| Operator confusion about compacted vs. original transcript | Clear state messaging; TUI shows "compaction: completed"; docs explain transcript preservation |
| Failed compaction repeats on every handoff | Session-change detection prevents repeat; failed state is durable and queryable |
| Silent compaction on non-Codex backends | Explicit backend check; unsupported state shown to operator; no error or surprise |

---

## System-Wide Impact

- **Agent handoff latency**: Compaction is async; no blocking impact. State queries are indexed.
- **Token costs**: Compaction reduces reviewer-thread tokens. Cost savings require baseline measurement (not claimed here).
- **Operator workflows**: New CLI commands and TUI state; minimal learning curve (manual approval optional, unsupported is silent pass-through).
- **Observability**: New CompactionState table; telemetry for request/success/failure; visible in CLI/TUI.

---

## Sources & Research

- Issue #2874: Per-agent context and usage visibility (prerequisite)
- Codex thread/compact/start API documentation (internal; verified by team)
- Existing Aiur patterns: config, orchestrator, agent runner, CLI, TUI

---

## Open Questions

1. **Threshold defaults**: What are reasonable defaults for token_threshold, message_count_threshold, elapsed_time_minutes? Recommend: 50k tokens, 20+ messages, 60+ minutes.
2. **Compaction summary length**: Does Codex API accept a length hint? Use default if not; tuning is follow-up work.
3. **Operator visibility**: Should failed compaction be highlighted in alerts, or only shown in CLI/status? Recommend: status only for MVP; alerts in follow-up if feedback warrants.

---
