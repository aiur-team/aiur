---
title: MP1 merge_policy config and visibility - Plan
type: feat
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/merge-policy/brainstorm.md
base_main_sha: fd158cef8
---

# MP1 merge_policy config and visibility - Plan

## Goal Capsule

- **Objective:** a validated `merge_policy` section exists, every consumer
  reads it through one accessor, and `aiur status` and `aiur capabilities`
  print it. The aiur repo's config sets its policy.
- **Product authority:** [brainstorm.md](brainstorm.md) (R1, R2, R3, R13, R14,
  R15).
- **Open blockers:** none.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

No merge setting exists except `tracker.github.human_mergers`. A fresh
Executor has no way to see the repo's merge rule. Every later ticket (MP2-MP6)
reads this section.

## Requirements

- R1, R2, R3, R13, R14, R15 from the brainstorm.
- MP1-R1. Invalid values fail config load with dotted-path messages
  (`merge_policy.ci must be one of: wait, pending_ok`).
- MP1-R2. `website/docs-app/reference/configuration.md` documents every key;
  `scripts/check-config-docs.py` passes.
- MP1-R3. The `human_mergers` docs agree: it is the post-merge attribution
  allowlist and the `aiur pr merge` identity allowlist.

## Key Technical Decisions

- **Shape** (defaults in brackets):

  ```yaml
  merge_policy:
    ci: wait                  # wait | pending_ok
    local_tests: partial      # all | partial | none
    full_ci_labels: [main-fix]
    full_ci_paths: []         # globs; any matching file forces ci=wait
    premerge_checks: []       # commands run on the merge result by aiur pr merge
    attribution_scan: false
    main_watch:
      enabled: false
      workflows: []           # empty = every workflow on the base branch
      on_red: alert           # alert | dispatch_fixer
      fixer_label: main-fix
      canary_minutes: 45      # 0 disables
  ```

- **No `fail` option.** R2 is not configurable, so there is no key for it.
- **Cross-field rules in the changeset** (R3, R13): `pending_ok` needs
  `main_watch.enabled`; `pending_ok` forbids `local_tests: none`;
  `dispatch_fixer` needs `fixer_label` in `full_ci_labels`.
- **One accessor module**, `Aiur.MergePolicy`, returns a plain map and answers
  `requires_full_ci?(labels, paths)`. MP2, MP3, MP4 call it, not the schema.
- **Capabilities without a contract change.** A provider reports capability
  id `merge_policy` with `state: ready` and `mode: "ci=pending_ok
  local_tests=partial"`. `mode` is already a wire field.
- **Status line** reads config only in this ticket; MP4 adds main's state to
  the same line.

## Implementation Units

### U1. Schema

**Goal:** parse and validate the section.
**Requirements:** R1, R2, R3, R13, MP1-R1.
**Dependencies:** none.
**Files:** `src/lib/aiur/config/schema/merge_policy.ex` (new; `MainWatch`
nested module, as in `schema/tracker.ex`), `src/lib/aiur/config/schema.ex`,
`src/test/aiur/config/merge_policy_test.exs` (new).
**Patterns to follow:** `schema/pr_watch.ex`, `schema/decisions.ex` (string
lists), `tracker.ex` `validate_inclusion` messages.
**Test scenarios:**
- Empty config: all defaults as above.
- `ci: pending_ok` with `main_watch.enabled: false`: error names both keys.
- `ci: pending_ok`, `local_tests: none`: error.
- `on_red: dispatch_fixer`, `fixer_label: hotfix`, `full_ci_labels: []`:
  error.
- `ci: maybe`: error lists the allowed values.
- Blank strings in `full_ci_labels` or `premerge_checks`: error.

### U2. Accessor

**Goal:** one read path for consumers.
**Requirements:** R1, R5 (helper), R13.
**Dependencies:** U1.
**Files:** `src/lib/aiur/merge_policy.ex` (new),
`src/test/aiur/merge_policy_test.exs` (new).
**Approach:** `current/0` from `Aiur.Config.settings!/0`;
`requires_full_ci?(labels, changed_paths)` matches labels case-insensitively
and paths by glob.
**Test scenarios:**
- Label `Main-Fix` matches `main-fix`.
- Path `.github/workflows/ci.yml` matches `.github/workflows/**`.
- No match: false.

### U3. Visibility

**Goal:** `aiur status` and `aiur capabilities` show the policy.
**Requirements:** R14.
**Dependencies:** U2.
**Files:** `src/lib/aiur/agent_control_cli.ex` (`print_merge_policy`, called
from `print_status_report/3`), `src/lib/aiur/capabilities/merge_policy_provider.ex`
(new), `src/lib/aiur/capabilities/collector.ex` (`@known_ids`), app env
provider list, tests in `src/test/aiur/agent_control_cli_test.exs` and
`src/test/aiur/capabilities/`.
**Test scenarios:**
- Default config: `MERGE POLICY ci=wait local_tests=partial main_watch=off`.
- aiur policy: `MERGE POLICY ci=pending_ok local_tests=partial
  full_ci=[main-fix] main_watch=on(dispatch_fixer)`.
- Capabilities JSON has `merge_policy` with the mode string and still matches
  the v1 schema.

### U4. Docs and templates

**Goal:** operators can find and set it.
**Requirements:** R15, MP1-R2, MP1-R3.
**Files:** `website/docs-app/reference/configuration.md` (new `##
merge_policy` table; fix `human_mergers` row), `.aiur/examples/config.example`,
`src/examples/workflows/github-claude.yaml`, `github-codex.yaml`,
`github-muse.yaml`, `linear-codex.yaml` (commented section with defaults),
`src/README.md`, `.aiur/config` (aiur values: `ci: pending_ok`, `local_tests:
partial`, `attribution_scan: true`, `premerge_checks` = the two scripts in
`merge-if-safe.sh`, `main_watch` enabled, `workflows: [ci]`, `on_red:
dispatch_fixer`).
**Test expectation:** `check-config-docs.py` and example-loading tests
(`init_test.exs`, `core_test.exs`) pass.
**Note:** `.aiur/config` is operator config; the PR changes only the
`merge_policy` block. `main_watch` does nothing until MP4 ships, which is
safe. The operator's main checkout has local edits to `.aiur/config`; the PR
description must give the exact block so the Executor can apply it to the live
config by hand.

## Risks

- The aiur config sets `pending_ok` before `aiur pr merge` exists. Harmless:
  nothing reads it until MP2.

## Verification Contract

- New schema and accessor tests, status and capabilities tests,
  `check-config-docs.py`.

## Definition of Done

- U1-U4 merged; `aiur status` on the rebuilt daemon prints the aiur policy.
