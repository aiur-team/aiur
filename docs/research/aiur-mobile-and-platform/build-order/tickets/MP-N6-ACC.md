# MP-N6-ACC — MP-N6 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N6-C2-T03, MP-N6-C3-T03, MP-N6-C4-T03, MP-N6-C4-T04, MP-N6-C5-T02, MP-N6-C5-T03, MP-N6-C6-T01, MP-N6-C6-T02

## Outcome

The Executor proves MP-N6 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N6/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (20)

- MP-N6-C1-T00 — Post-refactor path refresh for the device Command API
- MP-N6-C1-T01 — Device Command API — scope, pipelines and GET /api/v1/device/commands/:id view model
- MP-N6-C1-T02 — GET /api/v1/device/commands?state=needs_you — reconciliation list on app open
- MP-N6-C1-T03 — POST /api/v1/device/commands/:id/answer — device actor, D11 outcomes, replace, idempotent retry
- MP-N6-C1-T04 — Capability gating for device Command routes (commands.read / commands.answer) and typed errors
- MP-N6-C2-T01 — Pure destination resolver — machine → instance → target → anchor with visible degradation
- MP-N6-C2-T02 — Tap landing — cold/warm start routing to the resolved screen, never an inbox, no audio session
- MP-N6-C2-T03 — Existing-conversation detection and anchor scroll on tap
- MP-N6-C3-T01 — Phone Command screen — context, 2–3 suggested responses, custom response, Open conversation
- MP-N6-C3-T02 — Phone outcome states and the Replace flow (D11)
- MP-N6-C3-T03 — Unreachable/offline Command screen — sealed summary, draft retention, manual Retry
- MP-N6-C4-T01 — Mic button availability and the Dictate / Converse choice sheet on the Command screen
- MP-N6-C4-T02 — Dictate a Command response over the device voice path, reviewed before Send
- MP-N6-C4-T03 — Converse about a Command — MP-E6 session seeded with Command context, confirm-to-answer, typed end reasons
- MP-N6-C4-T04 — OS microphone permission at first press and the cloud-voice disclosure line
- MP-N6-C5-T01 — Watch Command card rules and fixtures — label, requester, question, up to three options, outcome line (screens are MP-N7-C2-T03 / C3-T03)
- MP-N6-C5-T02 — Watch mic — Dictate/Converse choice on the watch or hand-off to the phone
- MP-N6-C5-T03 — Open on phone" hand-off from the watch card to the same Command
- MP-N6-C6-T01 — Live resolution sync on an open Command screen (foreground polling; export feed later)
- MP-N6-C6-T02 — Foreground reconciliation — remove delivered notifications for Commands no longer needing you

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
