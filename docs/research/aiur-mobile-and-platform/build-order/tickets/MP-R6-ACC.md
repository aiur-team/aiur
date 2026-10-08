# MP-R6-ACC — MP-R6 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R6-C3-T01

## Outcome

The Executor proves MP-R6 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R6/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (3)

- MP-R6-C1-T01 — Extract the device-neutral event-to-transcript anchor rule into Aiur.Conversation.Anchors (behaviour-preserving)
- MP-R6-C2-T01 — Daemon owns the Stream Deck visual contract — the canonical JSON moves to src/priv, the sidecar keeps a byte-checked mirror, and core compiles without packages/streamdeck
- MP-R6-C3-T01 — Docs — shared projections vs Stream Deck presentation; the dashboard never needs the sidecar

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
