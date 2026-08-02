---
title: "feat: Document the Executor Control Center"
type: feat
status: active
date: 2026-07-12
issue: 1033
---

# feat: Document the Executor Control Center

## Summary

Publish a reader-facing guide to the shipped Executor Control Center, illustrated with deterministic synthetic data captured from the real Phoenix LiveView surface. Use the same pass to close the concrete navigation and content gaps in setup, configuration, cross-ticket coordination, and CLI control commands, while inheriting the rebranded VitePress styling from #1022 and the terminology decision from #1034.

---

## Problem Frame

The dashboard implementation is complete, but the public docs do not explain its routes, decision lifecycle, mutation controls, writable/authentication posture, or analytics handoff. Existing docs have useful quick-start and configuration material, yet the coordination model has no page, CLI control coverage is incomplete, and the dashboard paragraph still describes the pre-capstone read-only surface. Screenshots must demonstrate the shipped UI without exposing live repository, customer, credential, or agent data.

---

## Requirements

- **R1.** Document the overview, decision inbox, decision card/detail, fleet table, decision history, recent repository outcomes, and analytics link.
- **R2.** Explain Recorded → Dispatch pending → Delivered → Acknowledged → Resolved, plus Delivery failed and Superseded, without collapsing decision state into delivery state.
- **R3.** Explain human Executor and supervising-agent actions, including answer/decide, retry delivery, resolve, revise, and revision follow-up handling as the shipped controls permit.
- **R4.** Explain read-only versus writable mode, dashboard Basic Auth, loopback/private binding posture, same-origin/custom-header defenses, and the separate supervisor bearer credential.
- **R5.** Include light, dark, and responsive screenshots for the overview, decision inbox, and decision detail routes; each capture must contain only clearly synthetic example tickets, agents, decisions, merges, URLs, and identifiers.
- **R6.** Fill the identified docs gaps: first-run dashboard access and auth, complete CLI/control command reference, current configuration sections, and the event/blocker/attention/decision coordination model.
- **R7.** Use “Executor Control Center” and Executor role terminology in all new reader-facing content while preserving historical OCC issue/branch references.
- **R8.** Match the #1022 VitePress rebrand and keep all docs routes, image links, and production builds valid under the `/docs/` base path.
- **R9.** Reconcile the durable operational guidance from PR #971's `EXECUTOR-HANDOFF.md` into current main, rewritten for the shipped #1026 system, without merging the old branch or deleting/replacing any existing OCC contract document.

---

## Assumptions

- “Each surface” means each named documentation subject: overview, decision inbox, decision card/detail, fleet table, decision history, recent outcomes, and analytics link. Capture a focused light, dark, and mobile image for each subject (21 optimized assets), using the three shipped LiveView routes as sources rather than manufacturing extra routes.
- Screenshot generation will use the real endpoint, router, LiveView, presenter, and components with injected synthetic provider state. Static mock HTML or captures of the live dogfood backlog are not acceptable.
- The deterministic screenshot fixture is maintenance tooling, not a production demo-data mode; it must not add a runtime switch that could expose synthetic or privileged write behavior in normal deployments.
- #1034 owns renaming existing shipped UI/copy. This ticket authors new docs and screenshot metadata with Executor terminology and will reconcile against #1034 before final CI rather than duplicating its rename sweep.

---

## Scope Boundaries

### In Scope

- VitePress navigation and public markdown pages.
- Synthetic screenshot fixture/capture tooling and committed documentation assets.
- Corrections to stale public documentation discovered in the four requested audit areas.
- A current-main `docs/operator-control-center/EXECUTOR-HANDOFF.md` that orients maintainers to the shipped wave and preserved contract set.
- Link, build, example-data, and responsive-image validation.

### Out of Scope

- Product behavior changes to decision lifecycle, dashboard controls, auth, or persistence.
- Renaming historical OCC plans, ticket IDs, branch names, or internal module namespaces.
- A production sample-data toggle, long-term screenshot hosting service, or general visual-regression framework.
- Exhaustive documentation of every internal module or private API.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur_web/live/dashboard_live.ex` is the route-level source of truth for overview, inbox, detail, filters, writable events, and deep links.
- `src/lib/aiur_web/components/operator_control_center/` owns lifecycle labels, actions, fleet, history, outcomes, and analytics-link rendering.
- `src/lib/aiur_web/router.ex` and `src/lib/aiur/http_server.ex` define the Basic Auth, bearer-auth, writable, same-origin, custom-header, and bind-address posture.
- `src/test/aiur_web/live/dashboard_live_test.exs` demonstrates injected providers and a real endpoint around deterministic fleet and decision state.
- `website/tests/brand.spec.ts` and `website/playwright.config.ts` establish the repository's Playwright and light/dark/responsive conventions.
- `website/docs-app/.vitepress/config.ts` and the #1022 branch define the rebranded docs navigation and theme.

### Institutional Learnings

- `docs/operator-control-center/00-prd.md` requires explicit state-versus-delivery language, append-only revisions, visible uncertainty, and reuse of the canonical control paths.
- The agent-workspace manual-test guard forbids `scripts/aiurdev --test`/`--test3`; screenshot capture must use a deterministic synthetic fixture rather than pinned live test tickets.

### External References

- None. The shipped implementation and repository-local docs/theme/test patterns are current and sufficient.

---

## Key Technical Decisions

- **Capture real components with injected providers:** this proves the screenshots match shipped rendering while keeping all content synthetic and reproducible.
- **Organize the guide around Executor tasks and routes:** readers first orient on overview/fleet, then triage decisions, then understand lifecycle/actions/security; this mirrors the UI instead of repeating internal architecture notes.
- **Split missing material by reader intent:** retain quick-start for setup, add a CLI reference and coordination concept page, and update configuration in place rather than creating one oversized dashboard page.
- **Treat screenshot privacy as a gate:** a deterministic synthetic vocabulary and automated string audit prevent accidental real identifiers, repositories, URLs, hostnames, or secrets from entering committed images/copy.

---

## Open Questions

### Resolved During Planning

- **Product name:** use “Executor Control Center” per the owner decision on #1034.
- **Rebrand dependency:** stack/reconcile with #1022 so new navigation and pages inherit the shipped VitePress theme.
- **Screenshot coverage:** capture focused light, dark, and mobile images for each of the seven named surfaces, sourced from the three real dashboard routes.

### Deferred to Implementation

- **Exact synthetic provider process shape:** choose the smallest test-only arrangement after exercising the current endpoint helpers; it must still render the real LiveView and avoid a production fixture flag.
- **Final crop dimensions and image format:** decide after visual inspection for legibility and docs build size; preserve a crisp desktop view and a narrow responsive view.

---

## Implementation Units

### U1. Build the synthetic capture path and assets

**Goal:** Produce deterministic, privacy-safe light, dark, and mobile screenshots from the real Executor Control Center LiveView.

**Requirements:** R5, R7, R8

**Dependencies:** #1022 styling available locally; coordinate terminology with #1034

**Files:**
- Create: `src/test/manual/executor_control_center_docs_fixture.exs`
- Create: `website/scripts/capture-executor-control-center.mjs`
- Create: `website/docs-app/public/images/executor-control-center/`
- Modify: `website/package.json`
- Test: `website/tests/executor-control-center-docs.spec.ts`

**Approach:**
- Start a local-only real Phoenix endpoint with deterministic injected fleet, decision, history, recent-merge, and analytics providers modeled on existing LiveView tests. Use isolated temporary stores; never start ticket dispatch or connect to an external tracker.
- Populate multiple example decisions that visibly exercise blocking, delivery-failed, acknowledged/resolved, and superseded lifecycle rendering, plus synthetic agents across running, queued/retrying, CI wait, and review states.
- Capture focused overview, inbox, card/detail, fleet, history, recent-outcomes, and analytics-link regions at desktop light, desktop dark, and narrow mobile widths. Keep the same example vocabulary across captures so readers can follow one fictional run.
- Run read surfaces in the default read-only posture. Where a decision-action capture must show writable controls, use a separate isolated fixture invocation with throwaway example Basic Auth credentials, no supervisor bearer credential, and a dispatcher that cannot reach a real agent queue.
- Add a focused audit that checks the fixture and page source for the allowlisted synthetic repository/domain/identifier vocabulary and verifies all expected image files exist with useful dimensions.

**Patterns to follow:**
- `src/test/aiur_web/live/dashboard_live_test.exs`
- `website/tests/brand.spec.ts`
- `website/playwright.config.ts`

**Test scenarios:**
- Happy path: the fixture endpoint renders all three routes with the expected example tickets, decisions, history, outcomes, and analytics link; capture produces 21 non-empty assets covering seven subjects in three display modes.
- Integration: light and dark desktop captures reflect the corresponding real dashboard theme, and mobile captures have no horizontal overflow or clipped controls.
- Privacy gate: scanning fixture text, docs markdown, and capture metadata finds only the approved `example.test`/synthetic identifiers and no project repo, workspace, token, credential, or hostname content.
- Error path: missing fixture readiness, missing route content, or absent/zero-sized output fails the capture command rather than committing blank screenshots.

**Verification:**
- Every named surface has a legible focused light, dark, and mobile capture, and all visible data is unmistakably synthetic.

### U2. Publish the Executor Control Center guide

**Goal:** Explain the complete dashboard workflow, lifecycle, actions, writable gate, and auth posture with the synthetic screenshots.

**Requirements:** R1, R2, R3, R4, R5, R7, R8

**Dependencies:** U1

**Files:**
- Create: `website/docs-app/guide/executor-control-center.md`
- Modify: `website/docs-app/.vitepress/config.ts`
- Test: `website/tests/executor-control-center-docs.spec.ts`

**Approach:**
- Walk through overview/fleet, decision triage, stable detail links, lifecycle evidence, action semantics, revisions, history, recent repository merges, and analytics in the order an Executor encounters them.
- Use a compact lifecycle diagram/table that separates decision status from transport status and names Delivery failed/Superseded as non-linear outcomes.
- Document that read-only mode preserves every inspection surface while hiding mutation controls; writable mode is explicit opt-in and fails closed without credentials.
- Distinguish browser Basic Auth from the supervisor Decision API bearer credential and explain the local-only/private-tunnel/HTTPS-termination posture without embedding real secrets.
- Embed each asset with descriptive alt text and captions that state the data is synthetic.

**Patterns to follow:**
- `website/docs-app/guide/quick-start.md`
- `website/docs-app/concepts/ticket-lifecycle.md`
- `src/README.md` dashboard and Supervisor Decision API sections

**Test scenarios:**
- Happy path: the production docs build resolves the new route, sidebar entry, anchors, and all 21 image paths under `/docs/`.
- Content contract: headings/copy name every required surface, lifecycle state, action family, writable setting, dashboard credentials, supervisor token, and analytics behavior.
- Terminology gate: new user-facing copy consistently says Executor Control Center/Executor and contains no newly introduced “Operator Control Center” branding outside historical references.
- Accessibility: every image has meaningful alt text and adjacent prose conveys the same essential information without requiring the image.

**Verification:**
- A new reader can identify what needs attention, follow a decision through resolution, understand revision semantics, and configure secure read-only or writable access from this page alone.

### U3. Close the audited public-docs gaps

**Goal:** Make setup, configuration, coordination, and CLI/control documentation complete enough to reach and operate the dashboard without falling back to the repository runbook.

**Requirements:** R6, R7, R8

**Dependencies:** U2 for navigation grouping and terminology consistency

**Files:**
- Create: `website/docs-app/concepts/coordination.md`
- Create: `website/docs-app/reference/cli.md`
- Modify: `website/docs-app/guide/quick-start.md`
- Modify: `website/docs-app/reference/configuration.md`
- Modify: `website/docs-app/concepts/operating-aiur.md`
- Modify: `website/docs-app/.vitepress/config.ts`
- Test: `website/tests/executor-control-center-docs.spec.ts`

**Approach:**
- Extend quick-start through first dashboard access, local bind/port behavior, credentials, and the next links for CLI and Control Center operation.
- Add a command reference covering foreground/background launch, host/port, status/agents/watch, set max-agents, pause/resume, message, todo/only, init/build, and stop, with clear foreground-versus-headless semantics.
- Add a coordination concept page for topic events, subscriptions, blocker dependencies, attentions, durable decisions, and the distinction between cross-ticket coordination and operator-facing progress.
- Bring configuration reference in line with the current annotated template/schema for active-state slugs, newer agent resource/build controls, rate-limit fallback, decisions/supervisor delegation, PR watch, observability, and server/auth environment variables.
- Replace the stale pre-capstone dashboard paragraph in Operating Aiur with a concise link to the new guide.

**Patterns to follow:**
- `.aiur/examples/config.example`
- `AGENTS.md` command and event descriptions
- `.claude/skills/aiur-agent/` event taxonomy and blocker lifecycle
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` usage surface

**Test scenarios:**
- Happy path: every documented command and configuration key exists in the current CLI usage/config schema or annotated example.
- Edge case: docs distinguish foreground UI from headless `--bg`, loopback default from explicit remote binding, and GitHub label slugs from display names.
- Link integrity: all new sidebar/page links and cross-links resolve in the VitePress production build.
- Example-data gate: every command/config sample uses placeholders or synthetic domains/identifiers and contains no local hostnames, workspace paths, tokens, or real issue data.

**Verification:**
- The four requested audit areas are represented in site navigation and no longer depend on `src/README.md` or `AGENTS.md` for ordinary user operation.

### U4. Reconcile the Executor handoff on current main

**Goal:** Preserve the useful Executor operating and architectural context from PR #971 in a concise handoff that describes the shipped system instead of the obsolete in-flight wave.

**Requirements:** R7, R9

**Dependencies:** U2, U3; shipped #1026 implementation and #1034 terminology reconciliation

**Files:**
- Create: `docs/operator-control-center/EXECUTOR-HANDOFF.md`
- Modify: `docs/operator-control-center/README.md`
- Test: `website/tests/executor-control-center-docs.spec.ts`

**Approach:**
- Use PR #971's handoff as reference-only input; do not merge, cherry-pick, or restore its conflict-heavy branch contents.
- Retain the durable material: Executor role boundaries, canonical main-branch/verification posture, real-backend/no-mock invariant, operational controls, fallback discipline, security/auth reminders, and links into the implementation contracts.
- Replace its point-in-time fleet status, stale blockers, commit SHAs, old PR merge instructions, and “next ticket” checklist with the shipped #1026 architecture, current docs entry points, and maintenance-oriented verification guidance.
- Link every existing contract from the operator-control-center index and explicitly state that historical OCC filenames/IDs remain canonical references even though the user-facing product is Executor Control Center.

**Patterns to follow:**
- `docs/operator-control-center/README.md`
- `docs/operator-control-center/00-prd.md`
- `docs/operator-control-center/02-occ-0-audit-and-design-decisions.md`
- `docs/operator-control-center/03-occ-1-decision-contract.md`
- `docs/operator-control-center/04-occ-2-attention-adapter.md`
- `docs/operator-control-center/04-occ-3-answer-delivery-contract.md`
- `docs/operator-control-center/05-occ-8-decision-revision-contract.md`
- `docs/operator-control-center/06-occ-7-supervisor-decision-api-contract.md`

**Test scenarios:**
- Content contract: the handoff names Executor Control Center, identifies #1026 as shipped, and links the public guide plus every preserved PRD/decomposition/implementation-contract document.
- Preservation gate: the diff contains no deletion or replacement of the existing contract files under `docs/operator-control-center/`.
- Staleness gate: the reconciled handoff contains no obsolete “UI blocked,” “OCC-10 not started,” old main HEAD, transient fleet utilization, or old merge queue instructions from PR #971.
- Terminology gate: historical OCC identifiers are described as stable references while current reader-facing role/product names use Executor.

**Verification:**
- A maintainer can start from the handoff, understand what shipped and where truth lives, operate/verify the control surface, and reach every preserved contract without consulting the abandoned PR branch.

---

## System-Wide Impact

- **Interaction graph:** documentation navigation gains one guide, one concept page, one reference page, and static image assets; screenshot tooling exercises the existing endpoint/components without changing product runtime paths.
- **Internal documentation:** the operator-control-center contract index gains one reconciled handoff while every current-main contract remains intact.
- **Error propagation:** capture/build/link/privacy failures remain developer-time failures and do not affect the daemon.
- **State lifecycle risks:** fixture data is isolated from canonical stores and cannot be selected by normal runtime configuration.
- **API surface parity:** browser and supervisor API auth are documented as intentionally distinct; no API behavior changes.
- **Integration coverage:** the production VitePress build and real LiveView captures prove the docs/assets meet at the website/dashboard boundary.
- **Unchanged invariants:** decision persistence, dispatch, acknowledgement, resolution, revision, auth, and fleet orchestration remain owned by existing runtime modules and #1034 owns the broader rename.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| #1022 changes shared VitePress config/theme while this work is in flight | Keep #1022 declared as a blocker, stack on its validated branch, and reconcile its final merge before push. |
| #1034 changes UI labels after screenshots are captured | Coordinate terminology up front, let #1034 inspect this branch, and recapture after integrating its final user-facing rename if needed. |
| Synthetic fixture diverges from the shipped UI | Render the real router, LiveView, presenter, and components; do not maintain parallel HTML. |
| A screenshot leaks live data | Never point capture tooling at the dogfood daemon; use an allowlisted synthetic vocabulary and automated source/asset audit. |
| Screenshot volume makes the page slow or noisy | Optimize image format after capture and present route/theme variants in compact grouped sections without hiding essential prose. |
| Docs audit expands without bound | Limit changes to the four areas named in #1033 and file unrelated findings separately. |
| PR #971's stale fleet/merge instructions are accidentally revived | Treat its handoff as reference-only, rewrite against current main/#1026, and add explicit staleness/preservation checks. |

---

## Documentation / Operational Notes

- All visible examples use fictional `EX-*` tickets, `example.test` links, synthetic agents, and invented repository names.
- Capture commands bind only to loopback and clean up their temporary stores/processes.
- The final PR should note coordination with #1022 and #1034 and list the exact screenshot routes, themes, and viewport sizes.

---

## Sources & References

- Issue #1033
- Rebrand PR #1040 / issue #1022
- Executor terminology issue #1034
- Reference-only PR #971 at head `5caf5ff20f53e387d3e51b5650b84554c37b8990`
- `docs/operator-control-center/00-prd.md`
- `docs/operator-control-center/README.md`
- `docs/plans/2026-07-12-003-feat-operator-control-center-ui-plan.md`
- `docs/plans/2026-07-12-006-feat-occ-capstone-integration-plan.md`
