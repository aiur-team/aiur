# MP-R7-ACC — MP-R7 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R7-C2-T03, MP-R7-C3-T06, MP-R7-C4-T05, MP-R7-C5-T01, MP-R7-C5-T02, MP-R7-C6-T01

## Outcome

The Executor proves MP-R7 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R7/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (21)

- MP-R7-C1-T01 — Registry-wide harness contract test
- MP-R7-C1-T02 — Delivery-policy matrix characterization (entry point x harness)
- MP-R7-C1-T03 — Provider-frame golden tests for operator-message delivery
- MP-R7-C1-T04 — R7 characterization suite (single-writer lock coverage, one command)
- MP-R7-C2-T01 — Declare per-harness delivery primitives (registry data + pure descriptor)
- MP-R7-C2-T02 — Reserve optional steer and native-question callbacks in the backend behaviour
- MP-R7-C2-T03 — Running-agent harness delivery read model (next to, not inside, control capabilities)
- MP-R7-C3-T01 — Move the agent tool surface out of Aiur.Codex.DynamicTool into Aiur.AgentTools
- MP-R7-C3-T02 — Classify checkpoint-delivery failures through the registry, not Aiur.Codex.SessionRecovery
- MP-R7-C3-T03 — Put Claude launch telemetry and the RC display tailer behind registry capability keys
- MP-R7-C3-T04 — Route orchestrator pane interrupts through the optional interrupt/1 callback
- MP-R7-C3-T05 — Harness-adapters boundary rule in the component checker, with a reasoned allowlist
- MP-R7-C3-T06 — Config validation reads the backend catalog through a registered semantic check (remove config → Aiur.CodingAgent edges)
- MP-R7-C4-T01 — Harness-declared supervision children (remove the composition root's Claude edge)
- MP-R7-C4-T02 — Promotion-test record for harness-adapters (go/no-go for a physical package)
- MP-R7-C4-T03 — Physical aiur_harness package skeleton; move contract, registry and AppServer core
- MP-R7-C4-T04 — Move the Codex, Claude, Muse, OpenAI-compat (and, if merged, Gemini) adapters into aiur_harness
- MP-R7-C4-T05 — Release packaging check — the OTP release still contains and boots every adapter
- MP-R7-C5-T01 — aiur-claude protocol fixture and replay test (detect sibling drift)
- MP-R7-C5-T02 — File the aiur-claude turn/steer text-drop defect on the sibling repository
- MP-R7-C6-T01 — Contributor documentation — how to add a harness adapter

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
