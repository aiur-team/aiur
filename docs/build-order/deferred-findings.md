# Deferred Findings Ledger

Recording a finding preserves evidence; it does not activate work. These items
do not increase the Build Order remaining count, change its ETA, consume its
critical-path capacity, or prevent completion.

## DF-001 — Linear planning parity

- Severity: P2 separate capability
- Evidence: GitHub-first planning decision and issue
  [#1067](https://github.com/its-everdred/aiur/issues/1067)
- Affected component: Linear tracker/planning materialization
- Why non-blocking: Build Order v1 is explicitly GitHub-only.
- Future disposition: Human scopes a separate parity run after the current
  GitHub contracts are stable.

## DF-002 — Cross-repository and nested orders

- Severity: P3 product expansion
- Evidence: direct GitHub sub-issues support one parent, 100 direct children,
  and nesting; v1 requirements intentionally use one configured repository and
  direct children.
- Affected component: identity, provider, selector, publishing, graph layout
- Why non-blocking: no accepted v1 workflow requires cross-repository or more
  than 100 members.
- Future disposition: New requirements/planning run with multi-repository auth,
  hierarchy, and selector semantics.

## DF-003 — Dashboard graph editing

- Severity: P3 product/security expansion
- Evidence: prototype and accepted constraints make Build Order read-only.
- Affected component: GitHub membership/label/dependency mutations, auth, audit
- Why non-blocking: GitHub remains authoritative and v1 only observes it.
- Future disposition: Separate secure editing feature with confirmation,
  concurrency, rollback, audit, and relationship reconciliation.

## DF-004 — Webhook invalidation

- Severity: optimization
- Evidence: periodic/demand reconciliation is sufficient for v1; native
  `sub_issues`/dependency webhook invalidation could reduce freshness latency.
- Affected component: BuildOrderGitHubProjection
- Why non-blocking: polling remains authoritative and bounded.
- Future disposition: Measure latency/rate budget after production use, then
  authorize a bounded optimization ticket if warranted.

## DF-005 — Durable graph LKG across restart

- Severity: P3 reliability enhancement
- Evidence: v1 allows in-memory LKG with explicit unavailable state after
  daemon restart.
- Affected component: BO-003 projection persistence/migration
- Why non-blocking: restart uncertainty is truthful and accepted.
- Future disposition: Add durable snapshot only after measuring value and
  defining schema/privacy/upgrade behavior.

## DF-006 — Minimap and graph filtering

- Severity: optimization/product expansion
- Evidence: prototype constraints explicitly exclude minimap/filter-bar scope.
- Affected component: graph interaction and performance
- Why non-blocking: pan/zoom/fit, selection, diagnostics, and 100-node proof are
  sufficient v1 navigation.
- Future disposition: Test real Executor pain before adding controls.

## DF-007 — Opencode accounting surface

- Severity: P3 separate presentation
- Evidence: #132 proposes a context/cost row in the opencode side panel and
  chat header; the refreshed dashboard request does not include that TUI.
- Affected component: opencode session projection and pane rendering
- Why non-blocking: DASH-009 supersedes #132's durable storage/accounting
  substrate, while DASH-015 owns the requested dashboard surface.
- Future disposition: Narrow #132 to the TUI consumer after the shared ledger
  contract lands, then authorize it separately if still useful.

## DF-008 — Analytics redesign

- Severity: P3 product expansion
- Evidence: the refreshed prototype shows an Analytics placeholder, while
  production already has an authenticated durable telemetry report.
- Affected component: Analytics route/report/dashboard shell
- Why non-blocking: DASH-001 preserves current capability; no accepted request
  replaces it.
- Future disposition: Separate analytics requirements/design run.
