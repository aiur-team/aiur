---
ticket_id: MP-R1-C5-T06
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Migrate orchestrator alert emitters (22 files, 91 sites) from Aiur.Alerts to Aiur.Signal
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C5-T03]
prior_units: [U2]
prior_boundaries: ["#11 signal", "ORC #12", "DSP #13", "CTL #14", "PRL #15", "MSG #16"]
prior_features: [MP-E1, MP-E2]
prior_findings: []
size_owner: "per touched file: one-line call renames; orchestrator files over 500 lines keep their U8 owners and must not grow"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T06 — Orchestrator alert emitters

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5. Step S1, path-map row PR-07.
- **User value:** none visible. Completes the alert migration; orchestration (required,
  L3) then reaches executor-attention only through the L1 signal port.
- **Deliverable:** the same mechanical rename as C5-T05, restricted to
  `src/lib/aiur/orchestrator/**` and `src/lib/aiur/orchestrator.ex`: 22 files, 91 sites at
  base (`git grep -c 'Alerts\.emit_\(system\|custom\)' 45a290e3 -- src/lib`, orchestrator
  subset). After this ticket `Aiur.Alerts.emit_*` is called only by `Aiur.Signal`.
- **Non-goals:** alert latches in `Orchestrator.State` (21 fields, prior §6 item 8) —
  their ownership is MP-R1-C9 / U2; `AlertFeed` reads by the orchestrator (5 modules) —
  also C9.

## Dependencies and blockers

- DESIGN-R1 §1; C5-T03.
- **U2 interlock** (prior plan U2 "give lifecycle one owner" edits
  `orchestrator/issue_sync.ex`, `dispatcher.ex`, `pause_resume.ex`,
  `rate_limit_fallback.ex`): if a U2 PR is open on those files, land after it or rebase;
  never mix U2's semantic changes into this rename.
- **Coordination with MP-R2-C2-T08** batch "orchestrator/" (same rule as C5-T05).
- **Concurrent:** C5-T04, C5-T05.

## Verified starting point (`45a290e3`)

- 91 of 160 alert sites are in the orchestrator — the heaviest emitter area. Alert
  resolution topics (`.resolved`) are deduplicated inside `Alerts` via
  `AlertFeed.duplicate_resolution?/1` (`alerts.ex:121-142`), so routing through the port
  keeps that gate.

## Chosen design

Identical to C5-T05: `alias Aiur.Signal`, rename calls, byte-identical arguments, one
commit per file group (`dispatcher*`, `pause_resume*`, `pr_*`/`ci_*`, others).

## Implementation steps

1. File list via `rg -l 'Alerts\.emit_(system|custom)' src/lib/aiur/orchestrator src/lib/aiur/orchestrator.ex`
   (record count; base 22).
2. Rename; remove unused aliases.
3. Prune allowlist keys `orchestration → Aiur.Alerts`.
4. Add a source guard test: `Aiur.Alerts.emit_` appears in `src/lib` only inside
   `signal.ex` (named as a regression guard for the whole migration).

## Non-happy paths

- As C5-T05. A missed site keeps working and keeps its allowlist key visible.

## Compatibility and rollout

No behaviour change. Rollback: revert.

## Verification

- Suites: `test/aiur/orchestrator/` **and** the sibling files
  `test/aiur/orchestrator_*_test.exs` (CONTRIBUTING: directory runs do not cover
  siblings; at base these include `orchestrator_status_test.exs`,
  `orchestrator_ci_lifecycle_test.exs`, `orchestrator_max_duration_test.exs`,
  `orchestrator_remote_control_test.exs`), plus
  `test/aiur/orchestrator/operator_messages/alerts_test.exs`.
- Equivalence golden (regression guard): pause-with-cause and a PR-health alert produce
  identical central feed lines before/after (timestamps excluded).
- Source guard from step 4.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/orchestrator test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_ci_lifecycle_test.exs test/aiur/orchestrator_max_duration_test.exs test/aiur/orchestrator_remote_control_test.exs`.
- Mutation check: n/a (rename). The source guard fails if any `Aiur.Alerts.emit_` call is
  reintroduced outside the port.
- Manual: foreground `scripts/aiurdev --test`; pause and resume an agent from the TUI;
  `aiur alerts` and the dashboard attention list match `main`.

## Completion and handoff

- [ ] `Aiur.Alerts.emit_*` called only from `Aiur.Signal`; allowlist pruned; SCC size in
      the PR body.
- [ ] Docs: none.
- **Dependents:** MP-E2-C2 (escalation), MP-N4 (push routing), MP-R1-C9 (alert latch
  ownership).
