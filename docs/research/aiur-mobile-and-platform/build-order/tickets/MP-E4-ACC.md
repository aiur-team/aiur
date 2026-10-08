# MP-E4-ACC — MP-E4 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E4-C2-T02, MP-E4-C3-T03, MP-E4-C5-T04, MP-E4-C6-T01, MP-E4-C6-T02, MP-E4-C7-T01, MP-E4-C8-T01, MP-E4-C8-T02

## Outcome

The Executor proves MP-E4 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E4/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (20)

- MP-E4-C1-T00 — RQ-E4-1: measure journal entries/hour and bytes/hour per agent on the live fleet
- MP-E4-C1-T01 — Conversation identity, entry and session records, and the append-only on-disk store
- MP-E4-C1-T02 — Journal writer process: positions, sessions, dedup, gaps, broadcast, restart recovery
- MP-E4-C1-T03 — Worker tee: journal every worker transcript record from the three daemon ingest points
- MP-E4-C2-T01 — Conversation.History: paged reads by position, sessions, live subscribe and catch-up
- MP-E4-C2-T02 — Read-only JSON routes for conversations: entries, sessions, anchors, resolve
- MP-E4-C3-T01 — Extend Aiur.Conversation.Anchors with journal positions and the precision ladder (pure)
- MP-E4-C3-T02 — Anchor resolver process: live bus subscription, exact and observed anchors, persisted anchors.jsonl
- MP-E4-C3-T03 — Causal anchors: git push, gh pr create and gh pr merge command entries
- MP-E4-C4-T01 — Jump-point catalogue: kinds, labels (push with short sha), icons and default visibility
- MP-E4-C4-T02 — Command ↔ conversation links: decision index, 'Open in conversation' on the Command detail
- MP-E4-C5-T01 — ConversationLive: route, paging, view states and live tail
- MP-E4-C5-T02 — Entry rendering: messages, reasoning, commands, tool results, diffs, operator messages, gaps, session dividers
- MP-E4-C5-T03 — Event navigation: jump-point list with filters, jump to position, precision display, Command chips
- MP-E4-C5-T04 — Links into the conversation view (drawer, units table), phone-width proof, GUI guide
- MP-E4-C6-T01 — Composer through the listener-mode send path, with a delivery overlay reconciled against the journal
- MP-E4-C6-T02 — Answer this agent's open Commands inline in its conversation
- MP-E4-C7-T01 — Switch the Stream Deck logs transcript source onto the conversation journal
- MP-E4-C8-T01 — Import pre-journal history from workspace and IssueLog files as a marked import session
- MP-E4-C8-T02 — Concepts page: conversations, where transcripts live, retention, secrets, jump-point precision

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
