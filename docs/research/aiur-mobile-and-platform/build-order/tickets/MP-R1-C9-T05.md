---
ticket_id: MP-R1-C9-T05
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move PRHealthScanner out of the Orchestrator namespace into the pr-lifecycle component
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C1-T01, MP-R1-C1-T02]
prior_units: [U2, U5]
prior_boundaries: [PRL #15]
prior_features: []
prior_findings: [orch-b-24]
size_owner: n/a (pr_health_scanner.ex 373 lines and its test are not in the U8 ledger at 465aca643)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T05 — PR health scanner leaves orchestration core

## Identity and outcome

- Bucket 1, MP-R1, chunk C9 (prior §7 step 9: "Move `PRHealthScanner` and `ReworkRequeue`
  out of core at the same time").
- **User value:** none visible. The PR-health periodic worker becomes part of a named
  `pr-lifecycle` component instead of `orchestration` core, so the checker can enforce that
  orchestration does not depend on it and that it does not reach into the orchestrator.
- **Deliverable:** `Aiur.Orchestrator.PRHealthScanner`
  (`src/lib/aiur/orchestrator/pr_health_scanner.ex`) becomes `Aiur.PRLifecycle.HealthScanner`
  (PROPOSED, `src/lib/aiur/pr_lifecycle/health_scanner.ex`). Manifest entry `pr-lifecycle`
  (PROPOSED, L3, optional, requires `tracker`, `github`, `config`, `kernel`, `signal`; see
  "Compatibility" for the manifest change request) lists it.
- **Non-goals:** no change to the alerts, comments, cadence (`pr_health.interval_seconds`)
  or dedupe; finding `orch-b-24` (duplicated worker scaffolding with ReworkRequeue) is
  **not** fixed here; alert calls are not migrated to `Signal.alert/2` (that is
  MP-R1-C5-T05's caller migration, in batches).

## Dependencies and blockers

- DESIGN-R1 §1; MP-R1-C1-T01/T02 (manifest + rules; `pr-lifecycle` must exist);
  MP-R1-C7-T01 (IssueTracker/CodeHost split) only so this file is not edited twice — if
  C7-T01 has not merged when this starts, do the move first and let C7-T01 rebase.
- Not blocked on RQ-U2-TRANSITION: the scanner writes **no** ticket state; it only reads
  open PRs and reviews, comments on a PR and raises alerts (`pr_health_scanner.ex:6-29`).
- Concurrent with everything else in C9 except C9-T06 (same `aiur.ex` lines; serialize).

## Verified starting point (45a290e3)

- Module and process: `use Aiur.PeriodicWorker` (`pr_health_scanner.ex:31`), registered
  under its module name (`:46-47`), started at `src/lib/aiur.ex:447`, after
  `Aiur.Orchestrator` (`:442`) and `maybe_ls_remote_ticker/1` (`:446`), in the
  `:rest_for_one` root (`aiur.ex:118`).
- Dependencies: `Aiur.Alerts`, `Aiur.Tracker`, `GitHub.Client`, `GitHub.Config`,
  `GitHub.Tracker` (`:35-38`); **no** reference to `Aiur.Orchestrator` or `State`
  (`git grep 'Orchestrator' -- src/lib/aiur/orchestrator/pr_health_scanner.ex` shows only
  the `defmodule` line).
- Gate: `GitHubConfig.pr_health_enabled?() and Tracker.adapter() == GitHubTracker`
  (`:105`).
- The only references outside the file: `aiur.ex:447` and
  `src/test/aiur/orchestrator/pr_health_scanner_test.exs`. No `Process.whereis/1` on the
  name anywhere.

## Chosen design

- Rename + move, keeping the child at the **same position** in `child_specs/1`
  (`aiur.ex:447`) so restart cascades are identical.
- The registered name changes with the module. Nothing looks it up by name, so this is
  safe; the `SupervisionHealth` expected-children list is derived from `child_specs/1`
  (`aiur.ex` `supervision_health_child/1`) and follows automatically.
- Keep a deprecation alias? **No.** Nothing outside the tree references the old name
  (verified above); an alias would be dead code (finding `orch-a-23` class).

## Implementation steps

1. `git mv src/lib/aiur/orchestrator/pr_health_scanner.ex src/lib/aiur/pr_lifecycle/health_scanner.ex`;
   rename the module.
2. Update `aiur.ex:447`.
3. `git mv` the test to `src/test/aiur/pr_lifecycle/health_scanner_test.exs`; rename the
   test module and alias.
4. `components.json`: path to `pr-lifecycle`; no allowlist entry.
5. Re-read `website/docs-app/reference/configuration.md` `pr_health.*` entries; they name
   behaviour, not modules — no edit expected.

Estimated: ≈10 changed lines, 373 moved.

## Non-happy paths

Unchanged: disabled gate, GitHub read failure, 304 handling, per-PR dedupe. A crash still
restarts it and everything after it in the root (same position).

## Compatibility and rollout

No config/flag/disk change. Manifest: requests a new `pr-lifecycle` component (L3,
optional) — a component-map change owned by MP-R1 (`component-map.md §3`); the C9 README
lists it for the coordinator. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/pr_lifecycle/health_scanner_test.exs test/aiur/application_test.exs
python3 scripts/check-components.py
```

| Test | Expectation | Fails without |
|---|---|---|
| `application_test "pr-lifecycle health scanner keeps its position after the orchestrator"` | `index(Aiur.PRLifecycle.HealthScanner) == index(Aiur.Orchestrator) + 2` when `ls_remote_ticker?` is true, `+1` when false | the `aiur.ex` edit (old module name not found) |
| checker fixture `pr-lifecycle -> orchestration private module` fails | a fixture file in `pr_lifecycle/` that aliases `Aiur.Orchestrator.State` makes `check-components.py` exit 1 | the manifest entry/rule |

Existing scanner tests pass unchanged except the module name. Mutation check per AGENTS.md.
Manual: wrapper-tmux `aiurdev --test` with `pr_health.enabled: true` and a short interval;
an over-age sandbox PR raises the same `system.pr_health.*` attention in `aiurdev alerts`.

## Completion and handoff

- [ ] No `Aiur.Orchestrator.PRHealthScanner` reference remains.
- [ ] Same child position; checker ratchet ≤ before.
- Docs: none (internal).
- Dependents: C9-T06 (same pattern), C9-T07 (owner table names `pr-lifecycle`).
  size_owner re-resolved at ticket start (RC-23, MP-R1-C11-T02).
