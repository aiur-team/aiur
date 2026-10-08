# MP-N3-ACC — MP-N3 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N3-C1-T02, MP-N3-C1-T03, MP-N3-C1-T04, MP-N3-C1-T05, MP-N3-C4-T06

## Outcome

The Executor proves MP-N3 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N3/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (16)

- MP-N3-C1-T01 — Aiur.InstanceSummary.v1/0 skeleton: Fact envelope, provider injection, size budget and redaction guard
- MP-N3-C1-T02 — Summary fields agents.active, agents.capacity and fleet.globally_paused from the snapshot read model
- MP-N3-C1-T03 — Summary fields commands.awaiting and commands.awaiting_blocking with partial and unavailable health
- MP-N3-C1-T04 — Summary field executor: aggregate roster state without recording an observation
- MP-N3-C1-T05 — Summary fields build_orders, background_agents and capabilities
- MP-N3-C2-T01 — Gateway summary fan-out: GET /v1/instances?include=summary with bounded concurrency, timeouts and unsupported mapping
- MP-N3-C2-T02 — Gateway summary cache (5 s) shared across devices, with observed_at and age on every entry
- MP-N3-C3-T01 — MetaRow view model (TypeScript): row-state priority and per-field display rules
- MP-N3-C3-T02 — Shared meta-dashboard fixtures (registry + summary JSON with expected rows), used by gateway, phone and watch tests
- MP-N3-C4-T01 — Meta-dashboard screen frame: machine sections, loading, empty and machine-level states
- MP-N3-C4-T02 — Instance row rendering per DESIGN-N3: identity, agents, Executor, Commands count, build orders, background agents, freshness
- MP-N3-C4-T03 — Row tap opens the instance dashboard in the WebView; secondary Executor-chat button gated by capability
- MP-N3-C4-T04 — Refresh policy: foreground fetch, pull-to-refresh, 15 s poll while visible, stop in background
- MP-N3-C4-T05 — Offline cache of the last list, encrypted at rest, labelled stale, wiped on revoke
- MP-N3-C4-T06 — Physical-device validation of the meta-dashboard (DV-P5 states, navigation, offline cache)
- MP-N3-C5-T01 — Synthetic multi-machine gateway fixture server for UI work and design review

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
