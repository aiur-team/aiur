---
ticket_id: MP-E1-C1-T07
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: Source-scan test that keeps build_queue/ off orchestration and GitHub
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C1-T05]
prior_units: [U8]
prior_boundaries: [ORC #12, BO #30]
prior_features: [MP-R1]
prior_findings: [RC-11]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T07 — Seam test for `src/lib/aiur/build_queue/`

> **Plan refresh (wave 0).** RC-11: MP-E1 ships its own source-scan test
> because MP-R1-C1's dependency checker does not exist yet. R1-C1 absorbs this
> test (or replaces it with an equivalent manifest rule) and deletes it.

## Identity and outcome

- Bucket 2, MP-E1, C1, T07.
- **User value:** the queue stays movable by MP-R1 without a rewrite (D2).
- **Deliverable:** PROPOSED `src/test/aiur/build_queue/seam_test.exs` that
  fails when any file under `src/lib/aiur/build_queue/**` references
  `Aiur.Orchestrator` or `Aiur.GitHub`, or when any file other than
  `src/lib/aiur/build_queue/sources/build_order.ex` references
  `Aiur.BuildOrder`. A positive control proves the scanner finds a violation.
- **Non-goals:** checking files outside `build_queue/`.

## Dependencies and blockers

- DESIGN-E1 (gate), C1-T05 (first module in the directory).
- Rules from MP-R1 component map §4
  (`bucket-1-refactor/MP-R1/component-map.md:152-170`) and contract §8.

## Verified starting point (`45a290e3`)

- Precedent for a source-reading test:
  `src/test/aiur/orchestrator/resume_decline_reason_test.exs:40-52`
  (`File.read!` + `Regex.scan`).
- `src/lib/aiur/build_queue/` does not exist at base.

## Chosen design

Read every `*.ex` file under the directory (`Path.wildcard`). Normalise each
file by expanding multi-alias forms (`alias Aiur.{GitHub, Orchestrator}`) into
their full module names with a regex over `alias Aiur.\{([^}]*)\}`. Flag any
occurrence of `Aiur.Orchestrator`, `Aiur.GitHub`, or (outside the allowed
file) `Aiur.BuildOrder`, including `Module.concat`/string forms
`"Elixir.Aiur.GitHub"`. Expose the scanner as a private function in the test
and run it on an in-test fixture string (positive control).

## Implementation steps

1. Test file with three tests (below). No production code.

## Non-happy paths

- **Directory missing** (queue removed): the test fails with a clear message
  rather than passing vacuously (`assert files != []`).
- **False positive in a comment:** comments are stripped before scanning
  (`~r/#.*$/m`), so documentation may name the forbidden modules.

## Compatibility and rollout

Test-only.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| "no build_queue module references orchestration or GitHub" | no offenders | (the rule itself; guards future changes) |
| "only sources/build_order.ex references Aiur.BuildOrder" | no offenders | (same) |
| "the scanner flags a grouped alias" — fixture `alias Aiur.{Config, GitHub}` | offender reported | the alias-expansion step (positive control) |

Mutation check: add `alias Aiur.Orchestrator` to `hints.ex` in a worktree →
test 1 fails; remove → passes. Drop the alias expansion → test 3 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/seam_test.exs
```

## Completion and handoff

- [ ] Test in place, positive control proven.
- Docs: none.
- Dependents: every later ticket that adds a `build_queue/` file; MP-R1-C1.
