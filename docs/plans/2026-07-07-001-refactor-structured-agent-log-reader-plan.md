---
title: "refactor: Read dashboard logs from structured agent events"
type: refactor
status: completed
date: 2026-07-07
origin: docs/brainstorms/2026-07-07-transcript-storage-consolidation-requirements.md
---

# refactor: Read dashboard logs from structured agent events

## Summary

Route the web dashboard's agent-log modal through workspace `agent.ndjson` for current logs, while keeping `agent.md`, central `IssueLog`, and opencode SQLite as compatibility projections.

---

## Problem Frame

The dashboard currently parses the human-readable markdown projection with a regex even though the same workspace has structured event data. The origin requirements keep existing projections intact but make structured workspace events the local reader contract.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input - un-validated bets that should be reviewed before implementation proceeds.*

- The first implementation slice should improve reader ownership without removing any existing file sink.
- Dashboard behavior should remain best-effort: malformed log records should not crash the modal.

---

## Requirements

- R1. Workspace NDJSON remains a complete structured event stream.
- R2. Current local readers that need structured display data prefer workspace NDJSON over markdown text.
- R3. Dashboard chat-log parsing works from structured event records without requiring markdown block regex matching for current logs.
- R4. Malformed structured lines are skipped without crashing the reader.
- R5. `logs/agent.md` remains present for human inspection and Codex resume/debug context.
- R7. Central per-issue log behavior remains unchanged for operator tailing and opencode replay.
- R8. Opencode SQLite remains a projection, not Aiur's canonical transcript store.

**Origin actors:** A1 Operator, A2 Aiur agent, A3 Opencode pane, A4 Aiur maintainer
**Origin flows:** F1 Dashboard log viewing, F2 Workspace resume/debug inspection, F3 Opencode history rendering
**Origin acceptance examples:** AE1, AE2, AE3, AE4

---

## Scope Boundaries

- Do not remove or migrate `logs/agent.md`.
- Do not remove or filter `logs/agent.ndjson`.
- Do not change `IssueLog` file format, `aiur --log <id>`, or opencode replay.
- Do not introduce a new Aiur SQLite transcript database in this slice.

### Deferred to Follow-Up Work

- On-demand regeneration of `agent.md` from NDJSON: defer until resume/debug consumers are audited.
- Central cross-workspace transcript queries: defer until there is a concrete reader.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/agent_event_log.ex` writes both workspace files and already has JSON-safe encoding for tuples and timestamps.
- `src/lib/aiur/agent_log.ex` owns dashboard log read/parse behavior and already maps Codex JSON event payloads into display messages.
- `src/lib/aiur_web/live/dashboard_live.ex` gets a workspace path from the running agent row and currently passes the markdown file content into `AgentLog.parse/1`.
- `src/lib/aiur/alert_feed.ex` reads `agent.ndjson` alert entries, so NDJSON cannot be removed or alert-filtered.
- `src/lib/aiur/issue_log.ex` and `src/lib/aiur/opencode/session_writer.ex` remain the opencode/operator projection path and are not part of this slice.

### Institutional Learnings

- No `docs/solutions/` entries exist in this checkout.

### External References

- None. Existing Elixir file-reader and parser patterns are sufficient.

---

## Key Technical Decisions

- Add a structured workspace reader beside the existing markdown reader: this lets the dashboard prefer NDJSON without breaking callers that still pass raw markdown content to `AgentLog.parse/1`.
- Keep markdown parsing as a fallback: old logs, tests, and direct callers remain compatible while current dashboard reads move to structured data.
- Keep the writer behavior unchanged in this slice: reducing writes requires a broader resume-contract audit and is deferred by the origin requirements.

---

## Open Questions

### Resolved During Planning

- Should the first slice remove any sink? No. The origin requirements preserve every existing projection and only redirect structured readers.

### Deferred to Implementation

- Exact public function names in `AgentLog`: choose names that fit the existing module while preserving existing tests.

---

## Implementation Units

### U1. Structured workspace parsing in AgentLog

**Goal:** Teach `AgentLog` to read and parse workspace `agent.ndjson` as structured event records while preserving the existing markdown parser fallback.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/agent_log.ex`
- Test: `src/test/aiur/agent_log_test.exs`

**Approach:**
- Add an NDJSON-relative path helper and a workspace-level read/parse entry point.
- Parse each line with `Jason.decode/1`; skip malformed or non-map lines.
- Reuse the existing JSON payload display mapping so current Codex event handling remains consistent.
- Return the existing placeholder message when no displayable structured events exist.
- Preserve `parse/1` for markdown content and tests, using the structured parser only when content is NDJSON-shaped or when the new workspace entry point is used.

**Execution note:** Add characterization tests around existing markdown fallback before changing parser dispatch.

**Patterns to follow:**
- `src/lib/aiur/alert_feed.ex` for tolerant NDJSON line decoding.
- Existing `AgentLog.parse_json_log_entry/4` behavior for display message mapping.

**Test scenarios:**
- Happy path: a workspace with `logs/agent.ndjson` containing a Codex user message and assistant delta renders the same roles/bodies as markdown-backed parsing.
- Covers AE2. Error path: a malformed line between two valid NDJSON lines is skipped, and valid messages still render.
- Edge case: missing `agent.ndjson` falls back to `agent.md` content when present.
- Edge case: neither file exists returns the existing no-log placeholder.
- Compatibility: `AgentLog.parse/1` still parses markdown fixtures used by existing tests.

**Verification:**
- `AgentLog` tests prove structured current logs and markdown fallback both work.

### U2. Dashboard modal uses workspace-level structured reader

**Goal:** Wire the web dashboard agent-log modal to the new workspace-level reader so current logs no longer depend on markdown parsing.

**Requirements:** R2, R3, R5, R7, R8

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Test: `src/test/aiur/agent_log_test.exs` or existing dashboard LiveView tests if present

**Approach:**
- Keep the modal's displayed path useful for operators, but base messages on the workspace-level `AgentLog` entry point.
- Preserve refresh behavior for running entries and path-based fallback for stale modals.
- Avoid touching `IssueLog`, opencode session writing, or central log command behavior.

**Patterns to follow:**
- Current `agent_log_modal/1` and `refresh_agent_log_modal/2` flow in `dashboard_live.ex`.

**Test scenarios:**
- Covers AE1. Integration-ish unit coverage: dashboard-facing workspace read returns structured messages from `agent.ndjson`, not markdown-only content.
- Covers AE3. Compatibility: writing via `AgentEventLog.write/3` still creates both workspace files.
- Covers AE4. Test expectation: no direct opencode/IssueLog test changes because this unit intentionally does not touch those paths.

**Verification:**
- Existing dashboard behavior compiles with the new reader API.
- Agent log and event log tests cover the changed reader contract.

---

## System-Wide Impact

- **Interaction graph:** `AgentRunner` and `Alerts` continue writing both workspace files. Dashboard reading shifts from `agent.md` content to workspace-level structured reading.
- **Error propagation:** Structured read errors remain best-effort and produce the same user-facing placeholders where practical.
- **State lifecycle risks:** Partial or malformed NDJSON lines are skipped; no write ordering changes are introduced.
- **API surface parity:** Markdown `parse/1` remains available for legacy callers.
- **Integration coverage:** Unit tests cover the workspace reader; full manual TUI verification is not required because this slice does not change TUI behavior.
- **Unchanged invariants:** `IssueLog`, `aiur --log`, opencode SQLite writes, and workspace file creation remain unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Dashboard refresh loses the path needed for stale modal fallback | Keep a path field in modal state and only add workspace-aware reads where a workspace path is available. |
| Structured parser diverges from existing markdown parser behavior | Reuse the existing JSON payload mapping functions and preserve markdown tests. |
| Malformed NDJSON crashes dashboard rendering | Decode line-by-line and skip invalid records. |

---

## Documentation / Operational Notes

- Update module documentation where it still says dashboard parsing is markdown-only.
- No user-facing CLI behavior changes are expected.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-07-transcript-storage-consolidation-requirements.md](../brainstorms/2026-07-07-transcript-storage-consolidation-requirements.md)
- Related code: `src/lib/aiur/agent_log.ex`
- Related code: `src/lib/aiur/agent_event_log.ex`
- Related code: `src/lib/aiur_web/live/dashboard_live.ex`
- Related code: `src/lib/aiur/issue_log.ex`
- Related issue: #63
