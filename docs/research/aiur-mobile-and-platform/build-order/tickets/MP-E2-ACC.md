# MP-E2-ACC — MP-E2 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E2-C6-T03, MP-E2-C6-T04, MP-E2-C7-T01, MP-E2-C7-T02, MP-E2-C7-T05, MP-E2-C8-T01, MP-E2-C8-T02, MP-E2-C8-T03, MP-E2-C8-T04

## Outcome

The Executor proves MP-E2 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E2/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (36)

- MP-E2-C1-T01 — Persist v2 Command attributes in a request_attributed event
- MP-E2-C1-T02 — Validate v2 questions, derive short_label, warn on suggested responses
- MP-E2-C1-T03 — Route Command lifecycle topics by requester and prove rollback safety
- MP-E2-C1-T04 — Expose v2 Command fields in the read API and aiur commands --json
- MP-E2-C2-T01 — Pure routing and escalation policy
- MP-E2-C2-T02 — Durable routing facts and the human-needed event
- MP-E2-C2-T03 — Routing process — route, escalate on deadlines and roster, survive restarts
- MP-E2-C2-T04 — Executor acknowledgement — aiur executor-ack and implicit acks
- MP-E2-C2-T05 — decisions.escalation config keys with documented defaults
- MP-E2-C3-T01 — Answer precedence (direct operator > relayed > Executor), actor_source, ConflictSummary
- MP-E2-C3-T02 — Answering facade for human surfaces (answer, supersede, normalized outcomes)
- MP-E2-C3-T03 — Dashboard replace-answer, already-answered and too-late states
- MP-E2-C3-T04 — Stream Deck shows who won when an answer loses the race
- MP-E2-C4-T00 — Spike R-Q1: Codex request_user_input through aiur's app-server frames
- MP-E2-C4-T01 — NativeCapture core — classify, map and record native questions
- MP-E2-C4-T02 — Codex capture-and-hold of requestUserInput behind a config gate
- MP-E2-C4-T03 — In-band delivery — answer a held native question through the operator queue
- MP-E2-C4-T04 — Release held native questions on timeout, pause, interrupt and exit
- MP-E2-C4-T05 — Pass the Codex feature flag when capture is on; report native_question capability
- MP-E2-C5-T00 — Spike R-Q2: Claude AskUserQuestion capture under aiur-claude (defer vs blocking host)
- MP-E2-C5-T01 — aiur-claude: forward AskUserQuestion as item/tool/requestUserInput (sibling repo)
- MP-E2-C5-T02 — aiur handles Claude requestUserInput through NativeCapture; minimum aiur-claude version
- MP-E2-C5-T03 — Release Claude native questions on multi-call turns and lost sessions
- MP-E2-C6-T01 — aiur command request — Executor-originated Commands
- MP-E2-C6-T02 — Deliver answers to the Executor through its journal and wake inbox
- MP-E2-C6-T03 — Make aiur ask an alias that raises an Executor Command
- MP-E2-C6-T04 — Dashboard "From Executor" filter and badge
- MP-E2-C7-T01 — Inbox routing chips, filters, banner counts and fleet Commands column
- MP-E2-C7-T02 — Command detail — escalation timeline and native multi-question form
- MP-E2-C7-T03 — Unit row shows "waiting for your answer" while a native question is held
- MP-E2-C7-T04 — aiur commands — route, age and escalation columns and the needs-you filter
- MP-E2-C7-T05 — Stream Deck compatibility with v2 Commands
- MP-E2-C8-T01 — Concept docs for routing, escalation, native questions and supersede
- MP-E2-C8-T02 — aiur-run skill — Executor triage with deadlines, ack and asking the human
- MP-E2-C8-T03 — aiur-agent skill guidance, option-count census, then flip require_suggested_responses
- MP-E2-C8-T04 — Enable native capture by default per harness after owner approval

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
