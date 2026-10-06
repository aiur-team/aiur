---
ticket_id: MP-R1-C8-T3
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Projections component — move the Units row model and policy out of the web namespace
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T3, MP-R1-C1-T5]
prior_units: [U6, U2]
prior_boundaries: [PRJ #28, WEB #34]
prior_features: []
prior_findings: [web-occ-07, web-rest-02]
size_owner: WEB (units_row_test.exs, 597 lines) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2. No moved production file is over 500 lines.
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T3 — Units row model and policy become projections modules

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S10, `projections`).
- **User value:** none visible. The current-run read models stop depending on the
  dashboard (L3 → L4 edge), so the Units projection works in a `--no-dashboard` run,
  in `aiur units` (CLI), and later for the phone meta-dashboard (MP-N3) without the
  web package.
- **Deliverable:** the pure row model `AiurWeb.OperatorControlCenter.UnitsRow`
  (+6 submodules) and the pure truth table `AiurWeb.OperatorControlCenter.UnitsPolicy`
  move to `Aiur.Projections.UnitsRow*` and `Aiur.Projections.UnitsPolicy` under
  PROPOSED `src/lib/aiur/projections/`. All callers and tests are renamed.
- **Non-goals:** no change to any field, version, ordering or rendered value; no
  change to `UnitsPresenter`, `UnitsControlPolicy`, `UnitsURL` (they stay in the web
  package and now call down into projections); no fix of #3009 (see C8-T4).

## Dependencies and blockers

- DESIGN-R1 §1. MP-R1-C1-T1/T3/T5 (manifest, rules, ratchet).
- U6 owns `src/lib/aiur_web/` status presenters and "CLI and dashboard share the same
  field values and ages". This ticket moves the shared model **without** changing it,
  so U6 field-meaning work rebases trivially; if a U6 PR is open on these files at
  pickup, serialize after it (one writer per U8 `WEB` package at a time).
- May run concurrently with C8-T1, T2, T5, T6, T7. Not with C8-T4 (same manifest
  entry and `current_run_projections/state.ex`); T3 goes first.

## Verified starting point (45a290e3)

- Upward references from projections into the web package:
  - `src/lib/aiur/current_run_projections/state.ex:9,22` — `alias AiurWeb.OperatorControlCenter.UnitsRow`; default `&UnitsRow.snapshot/1`.
  - `src/lib/aiur/current_run_projections/units_builder.ex:5,47` — `UnitsRow.version()`.
  - `src/lib/aiur/current_run_summary/facts.ex:5,45-46,163` — `UnitsPolicy.in_scope?/2`, `condition?/2`.
  - `src/lib/aiur/units_cli.ex:7,52-66` — CLI uses `UnitsPolicy` (and `UnitsPresenter`, `PayloadLoader`, `UnitsPresentation`, which stay web-side; the CLI → web edge is recorded, not fixed, because the CLI renders the presenter output).
- Modules to move (lines at base): `aiur_web/operator_control_center/units_row.ex` (47),
  `units_row/fields.ex` (198), `units_row/projection.ex` (240), `units_row/resume_reason.ex` (39),
  `units_row/sources.ex` (223), `units_row/url.ex` (30), `units_row/value.ex` (10),
  `units_policy.ex` (191, moduledoc: "the renderer-independent truth table for the Units catalog").
- Their own outgoing references: `Aiur.TrackerIdentity`, `Aiur.CurrentRunMembership.Reconciler`,
  `Aiur.LiveConversation.Source` — no `Phoenix`/`AiurWeb` dependency outside their own namespace
  (`git grep -o 'Aiur(Web)?\.[A-Z][A-Za-z.]+' 45a290e3 -- src/lib/aiur_web/operator_control_center/units_row/`).
  Verify at head that none of them `use AiurWeb, …` or imports Phoenix.HTML; if one does,
  that module stays web-side and the ticket splits.
- Other callers (`git grep -l -E 'UnitsRow|UnitsPolicy' 45a290e3 -- src/lib`):
  `aiur_web/operator_control_center/{units_presenter,units_control_policy,units_url}.ex`,
  `aiur_web/components/operator_control_center/{units_filters,units_table}.ex`.
- Tests: `src/test/aiur_web/operator_control_center/units_row_test.exs` (597 lines, 38 refs),
  `units_policy_test.exs` (37 refs), `units_url_test.exs`, `units_presenter_test.exs`,
  `src/test/aiur/units_cli_test.exs`, `src/test/aiur/orchestrator/status_report_test.exs` (3 refs),
  `src/test/aiur/cadence_freshness_test.exs` (2), `src/test/aiur_web/streamdeck_control_agreement_test.exs` (10),
  `src/test/aiur/current_run_projections_test.exs`, `src/test/aiur/current_run_summary/projection_test.exs`.
- Rename tooling: `scripts/rename_preflight.py` ("Report rename hits that a joined-literal search would miss") also reports the CI shard of each hit.

## Chosen design

- **Move, rename, no shim.** All callers are in this repository; a delegating shim in
  `AiurWeb` would be a second name to keep and a reverse dependency to allowlist.
- New names: `Aiur.Projections.UnitsRow`, `Aiur.Projections.UnitsRow.{Fields,Projection,ResumeReason,Sources,URL,Value}`,
  `Aiur.Projections.UnitsPolicy`. Files under `src/lib/aiur/projections/` keep their
  basenames.
- Test files move with the modules to `src/test/aiur/projections/` (git rename, so
  history follows). Shard assignment changes with the path; that is expected and needs
  no registration (`scripts/check-test-shard-parity.py` recomputes from the path).
- **Manifest (`projections` entry):** paths `src/lib/aiur/projections/**`,
  `current_run_projections*/**`, `current_run_projection/**`, `current_run_outcome_snapshot*/**`,
  `current_run_summary*/**`, `ticket_activity*/**`, `progress_tracker.ex`,
  `progress_retention.ex` (the build-order ticket-detail modules are NOT included — they read GitHub; C8-T8 gives them a `ticket-context` component);
  facades `Aiur.CurrentRunProjections`, `Aiur.CurrentRunOutcomeSnapshot`,
  `Aiur.CurrentRunSummary`, `Aiur.TicketActivity`, `Aiur.ProgressRetention`,
  `Aiur.ProgressTracker`, `Aiur.Projections.UnitsRow`, `Aiur.Projections.UnitsPolicy`.
  **Corrections to component-map.md:** `current_run_membership/**` is **not**
  projections — it is the authoritative membership store written by orchestration
  (`orchestrator/membership_lifecycle.ex`) and owned by U2; assign it to
  `orchestration`. `open_ticket_source*` is GitHub-event-sourced
  (references `Aiur.GitHub`, `GitHub.ResourceStore`, `Events.GithubWebhook`,
  `Webhooks.ModeRegistry`); assign it to `github` (C8-T4 records it).

## Implementation steps

1. `python3 scripts/rename_preflight.py` for each old module name; save the report.
2. `git mv` the eight lib files and the two test files; rename `defmodule` lines and
   every alias (≈8 lib files edited by one alias line each, ≈5 test files).
3. Update `components.json`: `projections` entry as above; remove the allowlisted
   L3→L4 edges for `state.ex`, `units_builder.ex`, `facts.ex`.
4. Run the checker; record the violation count before and after in the PR body.

Changed production lines (excluding pure renames): ≈30.

## Non-happy paths

- **Wire version:** `UnitsRow.version()` is embedded in projections
  (`units_builder.ex:47`) and possibly in persisted checkpoints
  (`current_run_projections/checkpoint_persistence.ex`). The module rename must not
  change the version value, and checkpoint payloads must not embed module names.
  Verify by grepping checkpoint encoding for `inspect(`/`__struct__` at head; if a
  struct module name is persisted, stop and add a decode alias (blocked item, not an improvisation).
- **Dashboard absent (`--no-dashboard`):** today `CurrentRunProjections` already starts
  without the web listener; after the move it no longer loads web modules at all.
  No new branch.
- **Privacy/concurrency:** none affected (pure modules).

## Compatibility and rollout

No config, no on-disk format change (guarded by the checkpoint check above). Revert
restores old names in one step.

## Verification

- Moved tests run unchanged apart from module names:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/projections test/aiur/current_run_projections_test.exs test/aiur/current_run_summary/projection_test.exs test/aiur/units_cli_test.exs test/aiur/orchestrator/status_report_test.exs test/aiur/cadence_freshness_test.exs test/aiur_web/operator_control_center test/aiur_web/streamdeck_control_agreement_test.exs`.
- No new ExUnit test: the change is a rename, so an ExUnit "no web reference" test
  would only restate the checker. The guarding assertion is the checker rule (a
  failing fixture for L3→L4 already exists in MP-R1-C1-T6).
- Checker mutation: with one `alias AiurWeb.OperatorControlCenter.UnitsRow` re-added in
  `state.ex` (and the shim module present in a scratch branch), `check-components.py`
  reports a new L3→L4 violation.
- `make -C src fmt-check lint`; `python3 scripts/check-components.py`.
- Manual (AGENTS.md): foreground `scripts/aiurdev --test`, open the dashboard Units
  table and run `aiurdev units --scope live`; capture both before and after the change
  and diff — identical rows and counts. Capture the TUI agent list (`0.0`) as well.

## Completion and handoff

- [ ] No module under projections references `AiurWeb.*` (checker).
- [ ] Units table, `aiur units` and Stream Deck agreement output identical (captures in PR).
- [ ] Manifest corrections (membership → orchestration, open-ticket-source → github) applied.
- **Docs:** none (internal).
- **Dependents:** MP-R1-C8-T4; MP-N3 meta-dashboard counts read `Aiur.CurrentRunSummary`
  from projections; plan-refresh adds row "Units model → `Aiur.Projections.*`" for E4/N3 tickets.
