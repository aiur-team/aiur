---
date: 2026-07-07
topic: transcript-storage-consolidation
---

# Transcript Storage Consolidation

## Summary

Aiur should treat the workspace structured event stream as the durable local transcript source, while preserving the existing human-readable and opencode-facing projections that operators and agents already depend on.

---

## Problem Frame

Aiur currently persists agent activity through several paths that were added for different readers over time. The workspace markdown file supports quick human inspection and Codex resume context. The workspace NDJSON file preserves full event payloads and powers the attentions feed. The central per-issue log supports `aiur --log`, cross-ticket event replay, and opencode history injection. Opencode's SQLite database is owned by opencode and is populated as a chat-pane projection.

The original issue suspected `agent.ndjson` was dead and that a new SQLite store might be the clean consolidation point. Current code disproves the first premise: `AlertFeed` reads workspace NDJSON, and #708 depends on non-alert crash reasons reaching it. The safer consolidation is to stop adding readers to lossy text projections and make structured event data the local reader contract.

---

## Assumptions

*This requirements doc was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input - un-validated bets that should be reviewed before planning proceeds.*

- The desired v1 outcome is lower parsing brittleness and clearer ownership, not a disruptive migration to a new canonical database.
- Keeping `logs/agent.md` available is mandatory for the Codex resume/debug contract, even if dashboard code no longer treats it as canonical.
- Opencode SQLite remains a viewer-owned projection and should not become Aiur's source of truth in this issue.

---

## Actors

- A1. Operator: inspects active and historical agent activity through the dashboard, CLI log command, and direct workspace files.
- A2. Aiur agent: resumes with workspace-local transcript context and emits transcript, alert, and lifecycle events during a run.
- A3. Opencode pane: renders chat history from opencode-owned SQLite rows populated by Aiur.
- A4. Aiur maintainer: adds future transcript readers or event types without reimplementing another parser.

---

## Key Flows

- F1. Dashboard log viewing
  - **Trigger:** An operator opens or refreshes an agent log from the web dashboard.
  - **Actors:** A1, A4
  - **Steps:** The dashboard reads structured workspace events, converts displayable entries into chat-style messages, and falls back gracefully when no structured log exists.
  - **Outcome:** The dashboard does not depend on markdown block parsing for current logs.
  - **Covered by:** R1, R2, R3, R8

- F2. Workspace resume/debug inspection
  - **Trigger:** An agent or operator inspects a workspace after a run, retry, or crash.
  - **Actors:** A1, A2
  - **Steps:** The structured event stream preserves full payloads, while the markdown projection remains available for quick `cat`-style context.
  - **Outcome:** Existing resume and manual inspection workflows continue to work.
  - **Covered by:** R4, R5, R6

- F3. Opencode history rendering
  - **Trigger:** An operator opens or reopens an opencode chat pane.
  - **Actors:** A1, A3
  - **Steps:** The existing central per-issue log continues to feed opencode session replay and live rendering.
  - **Outcome:** This consolidation does not change opencode's database schema or replay source.
  - **Covered by:** R7, R9

---

## Requirements

**Structured local source**
- R1. Workspace NDJSON remains a complete structured event stream, including alerts, notifications, transcript payloads, and crash reasons.
- R2. Current local readers that need structured display data should prefer workspace NDJSON over markdown text.
- R3. Dashboard chat-log parsing must work from structured event records without requiring markdown header/code-fence regex matching for current logs.
- R4. Malformed structured lines must be skipped without crashing the reader, preserving best-effort visibility for the remaining log.

**Compatibility projections**
- R5. `logs/agent.md` must remain present for workspace-local human inspection and Codex resume/debug context.
- R6. The markdown projection may remain lossy and human-oriented, but it must not be the only source used by new structured readers.
- R7. The central per-issue log remains in scope as an operator/opencode projection because it carries event markers and feeds existing replay paths that workspace NDJSON does not cover.

**Ownership boundaries**
- R8. Opencode SQLite remains out of Aiur's canonical storage decision; Aiur may write opencode rows only as a chat-pane projection.
- R9. `aiur --log <id>` behavior remains text-tail oriented for this v1; replacing it with a SQLite follow mode is deferred.
- R10. Future transcript-event additions should have one documented local structured source to target before adding new reader-specific projections.

---

## Acceptance Examples

- AE1. **Covers R2, R3.** Given a workspace with current `agent.ndjson` content, when the dashboard opens the log modal, it renders displayable user, assistant, warning, command, and alert entries without parsing markdown sections.
- AE2. **Covers R4.** Given a workspace NDJSON file with one malformed line between two valid lines, when the dashboard parses the log, the two valid messages still render.
- AE3. **Covers R5, R6.** Given an agent emits an event, when the workspace logs are inspected directly, both the structured stream and markdown projection are still available.
- AE4. **Covers R7, R8.** Given an opencode pane opens for an existing issue, when history replay runs, it continues to use the central per-issue log and opencode-owned SQLite projection rather than a new Aiur transcript database.

---

## Success Criteria

- The dashboard no longer relies on markdown regex parsing for current workspace logs.
- Existing operator and agent workflows that directly read `logs/agent.md`, `logs/agent.ndjson`, and `aiur --log <id>` continue to work.
- The code documentation makes the source/projection boundary explicit enough that future transcript readers do not add a fourth Aiur-owned canonical sink.

---

## Scope Boundaries

- No change to opencode's database schema.
- No migration of existing workspace or central log files.
- No removal of `agent.ndjson`; it is required by the attentions feed and crash-reason persistence.
- No removal of `agent.md`; it remains a compatibility projection.
- No replacement of `aiur --log <id>` with a SQLite follower in this slice.
- No central cross-workspace query product in this slice.

---

## Key Decisions

- Use workspace NDJSON as the local structured source: it already exists, preserves full payloads, and is workspace-local.
- Keep markdown as a projection: it satisfies resume and quick-inspection needs without forcing readers to parse it.
- Keep the central per-issue log as a separate projection: it serves operator tailing, event bootstrap, and opencode replay paths that are not equivalent to workspace event capture.
- Defer a new Aiur SQLite transcript database: current reader needs do not justify a migration or another canonical store.

---

## Dependencies / Assumptions

- #60 has landed, and opencode session history injection now exists.
- #708's crash-reason persistence remains a hard constraint on `agent.ndjson`.
- The dashboard has access to the workspace path for each running agent.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R2, R3][Technical] Whether dashboard reader APIs should expose a new workspace-level function or keep the current path-based function while pointing it at NDJSON.
- [Affects R5, R6][Technical] Whether markdown should continue to be appended eagerly or eventually become an on-demand regenerated projection.
