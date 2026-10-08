# U-units-ACC — U-units acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** U9-T02

## Outcome

The Executor proves U-units end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/U-units/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (31)

- U0-T01 — U0 review gate - refresh finding dispositions at the implementation SHA and sign off
- U0-T02 — Refresh the oversized-path owner ledger at the implementation SHA (373 paths, 16 new)
- U0-T03 — Transitional 500-line gate in the required workflow security job
- U1-T01 — Commit the two missing automated P0 witnesses (coalesced-route no-send, credential names inside the real sandbox)
- U1-T02 — Real-process witness that aiur stop reaps only its own instance's agents
- U1-T03 — Foreground witness - packaged Ctrl+C in a chat pane with a queued Executor message
- U2-T01 — One ticket-transition owner - every lifecycle label write goes through Aiur.Orchestrator.TicketTransition
- U2-T02 — One guarded terminal-verification wrapper, with a bound on retained terminal ids
- U2-T03 — Rate-limit fallback - complete safety entries and no starvation from one failing label write
- U2-T04 — Every waiting ticket reports reason, owner, cause and since
- U2-T05 — Workspace ownership - a retained lease is reported, alerted and never claimed as released
- U3-T01 — Event subscription replays its stalled buffer in order before any newer event
- U3-T02 — Executor claims - an expired owner cannot renew after a successor claims
- U3-T03 — Executor wake inbox - recover from a corrupt journal tail and make write failures visible
- U4-T01 — Settle a worker pause once - one function for TurnLoop and QueueDrain, containment confirmed on every path
- U4-T02 — Measure no-progress continuation turns, then wait for a wake instead of continuing when the count justifies it
- U4-T03 — Backend stop and startup diagnostics - Claude kills its process tree, ANSI cannot hide a secret, startup log is bounded
- U5-T01 — Complete paginated GitHub readers - comments, PR changed files, and a list reader that refuses a next page
- U5-T02 — One CODEOWNERS trust snapshot (KTD9) - one grammar, one team resolver, unknown is never trusted
- U5-T03 — Monotonic resource-store writes - an older read can never overwrite a newer observation
- U5-T04 — Typed complete / held / unknown outcomes at the GitHub access entry points, membership witnesses, and reconcile-before-retry for review replies
- U6-T01 — Decision journal outcome matrix (KTD10) - failed, ambiguous and accepted appends are told apart
- U6-T02 — Decision projection failure keeps accepted events, shows stale health, and replays withheld notifications once
- U6-T03 — Usage aggregate re-subscribes after the usage ledger restarts
- U6-T04 — One status read model for CLI and dashboard - complete fields, per-field observed age
- U6-T05 — Dashboard read path - cache loader off the GenServer call, and an unknown cap renders as unknown
- U7-T01 — Usage census and cut decisions for the four live candidates; close the three already-cut ledger entries
- U7-T02 — Cut the Linear tracker (only if the owner approves after the U7-T01 census)
- U9-T01 — Net tracked-text LOC census between two commits, by area, with moves excluded
- U9-T02 — Integrated release acceptance for the U-unit program on latest main, with the before/after census
- U9-T03 — Run the npm launcher tests (bun test in packaging/npm/aiur-cli) in CI

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
