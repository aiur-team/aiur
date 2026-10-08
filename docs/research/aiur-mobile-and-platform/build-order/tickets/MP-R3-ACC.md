# MP-R3-ACC — MP-R3 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R3-C1-T01, MP-R3-C2-T01

## Outcome

The Executor proves MP-R3 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R3/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (2)

- MP-R3-C1-T01 — Authorization-independence guards — route and socket auth census, bind matrix, HTTP-only listener
- MP-R3-C2-T01 — Docs — reachability is not authorization; the dashboard is plain HTTP

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
