---
ticket_id: MP-R1-C1-T01
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: Component manifest, schema and file-ownership check in the required lint job
status: blocked
blocked_by: [DESIGN-R1]
prior_units: [U0, U8]
prior_boundaries: ["all 40 (feature-boundaries.md §2)"]
prior_features: []
prior_findings: []
size_owner: n/a (new files; each < 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T01 — Component manifest, schema and file-ownership check

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1 (manifest and dependency checker).
  Migration step S0 ([migration-plan.md §2](../migration-plan.md)).
- **User value:** none at runtime. Maintainers and agents get one machine-readable
  answer to "which component owns this file", which every later move (C4–C9), the
  directory page (C10) and the plan refresh (C11) read.
- **Deliverable:**
  1. `components.json` at the repository root (decision MP-R1-KD2) with all 41
     components of [component-map.md §3](../component-map.md), today's paths.
  2. `components.schema.json` (JSON Schema draft 2020-12) beside it.
  3. `scripts/check-components.py` with the **ownership** rule only: every tracked file
     under `src/lib/`, `packages/`, `packaging/` matches exactly one component's
     `paths`.
  4. `scripts/test-check-components.sh` with failing fixtures, run in the
     `workflow security` job beside `test-check-config-docs.sh`.
  5. One step in the required `lint` job running `python3 scripts/check-components.py`.
- **Non-goals:** module-reference rules (T02, T03), TypeScript imports (T04), ratchet
  tooling (T05), build-queue seam rules (T06), public directory fields (`summary`,
  `status`, `install`, `docs`, planned entries — MP-R1-C10-T01), moving any code.

## Dependencies and blockers

- **DESIGN-R1 §1** (no user-facing change). No other blocker.
- **Concurrent:** C2-T01 and C5 tickets may run in parallel; they add files, which must be
  added to `components.json` in the same PR once this ticket has merged.
- **Dependents:** C1-T02..T06, C4-T05, C10-T01, C11-T01, and every move ticket (C6–C9),
  which update `paths` in the same PR.

## Verified starting point (`45a290e3`)

- No manifest exists (`git ls-tree 45a290e3 components.json` is empty).
- Precedent for a required docs/drift guard: `scripts/check-config-docs.py` (169 lines),
  run in the `lint` job at `.github/workflows/ci.yml:258-262` with `working-directory: .`
  and skipped on docs-only PRs (`ci.yml:260`); its self-test
  `scripts/test-check-config-docs.sh` runs in the `workflow security` job
  (`ci.yml:176-177`), which has no Elixir toolchain.
- The docs-only classifier treats only `website/` and `packages/aiur-style/` as docs
  (`ci.yml:126-131`), so a `components.json` change always runs the lint job.
- Root `package.json` has no workspaces; `packages/` holds `aiur-style` and
  `streamdeck` (each with its own `package.json`).
- Component IDs, layers, kinds, facades and dependencies: [component-map.md §3](../component-map.md).
  Phase C placements for modules the prior survey did not map (RQ5, measured with the
  prior walker at `45a290e3`, see "Placement evidence" below): `Aiur.Muse.*` and
  `Aiur.AgentTools.*` → `harness-adapters`; `Aiur.AllowedContributors*` → `github`;
  `Aiur.DaemonHeartbeat*` → `telemetry`; `Aiur.AgentContextPresentation` →
  `agent-runner`; `Aiur.TestTicketScope` → `control-cli` (dev harness).
- **Placement evidence (RQ5).** `elixir docs/research/refactor-2026-09-26/tooling/module_references.exs`
  (branch `research/refactor-findings`, `f09e6e5d0`) over a `git archive 45a290e3` tree:
  1,111 modules, 1,077 primary files. `AllowedContributors` references `Aiur.GitHub.*` 10
  times and is referenced by `Events.GithubWebhook` (2), `GitHub.Issues` (1),
  `Config.Schema.Github` (1) and `Aiur.Application`; `Muse` is referenced only by
  `CodingAgent.Providers.Muse` (7) and `Usage.Headless.Muse.SessionUsage` (1).

## Chosen design

**Manifest shape** (one object per component, array sorted by `layer` then `id`):

```json
{
  "manifest_version": 1,
  "components": [
    {
      "id": "kernel",
      "name": "Kernel primitives",
      "layer": 0,
      "kind": "required",
      "paths": ["src/lib/aiur/fs.ex", "src/lib/aiur/json_store.ex"],
      "facades": ["Aiur.Fs", "Aiur.JsonStore"],
      "facade_pending": null,
      "requires": [],
      "optional": [],
      "owns": {"config": [], "env": [], "state": [], "capabilities": []},
      "prior": ["K"]
    }
  ]
}
```

- `paths`: repository-relative globs (`*` = one segment, `**` = any depth). A file is
  owned by the component with the **most specific** matching glob (longest literal
  prefix); two globs of equal specificity in different components both matching one file
  is an error. This lets `orchestration` own `src/lib/aiur/orchestrator/**` while
  `build-queue` (wave 0, MP-E1) owns nothing there and `github-listeners` owns
  `src/lib/aiur/orchestrator/comment_polling*.ex`.
- `facades: ["*"]` is allowed only with `facade_pending` naming the ticket that narrows it
  (T02 treats `*` as "every module is public"). This avoids a day-one flood of
  private-module violations for components whose facade does not exist yet.
- `kind ∈ {required, optional}`; `layer ∈ 0..5`; `requires`/`optional` are component IDs.
  The enum is binary on purpose (X-30). The component map's prose kinds map as:
  "required by surfaces" (projections) and "required by every conversation surface"
  (conversations) → `required`; "optional (on with recording)" (executor-attention),
  "optional (with github)" (github-listeners), "optional (one tracker required)" (github),
  "optional (required by every remote client)" (web-shell) and "optional (foreground
  runs)" (tui) → `optional`. A required component with an optional edge (for example
  `conversations` → `executor-attention`) must be inverted into a registration by the
  optional component, or be named in C1-T06's `seams`; the schema rejects any other
  value of `kind`.
- `owns.*` arrays may be empty in this ticket; C4-T05 fills `config`/`env`/`state`,
  C3 fills `capabilities`.
- `prior`: the prior survey codes (traceability for C11), not used by rules.
- The schema forbids unknown keys inside a component except the C10 public fields
  (`summary`, `status`, `install`, `docs`, `feature_id`), declared here as optional so
  C10-T01 only fills data. At the root it allows `manifest_version`, `components`, and —
  answering the C6–C11 researcher's Q-2 — an optional `features` array and an optional
  boolean `directory_published` (C10-T01, C10-T04 own their contents). C1-T06 adds `seams`.

**Size.** `components.json` will exceed 500 lines if pretty-printed with one path per
line (41 components). The U8 gate (KTD1) applies to every tracked text file. Rule: the
file is written by `check-components.py --format` with each component on one logical
block and `paths` arrays inline, keeping it under 500 lines. If it still exceeds 450
lines at implementation time, split into `components/<layer>.json` files (six files)
and make the checker and C10's loader read the directory; record the choice in the PR.

**Checker CLI:** `python3 scripts/check-components.py [--rules ownership] [--format]`.
Exit 0 clean, 1 violations, 2 broken input (unreadable manifest, schema mismatch).
Output: one line per problem, `components: <path>: <reason>`. Pure stdlib Python (the
lint job installs no Python packages), so schema validation is a hand-written validator
for the subset the schema uses; the schema file is the documentation and is also used
by C10's TypeScript loader.

## Implementation steps

1. Write `components.schema.json` (PROPOSED path, repo root).
2. Generate the first `components.json` from component-map §3: for each component,
   translate "Paths today" to globs; resolve every `and peers`/`…` in the map into
   explicit files by running the ownership rule and assigning each unowned file.
   Expected: every file in `git ls-files src/lib packages packaging` owned once.
3. Write `scripts/check-components.py`: load + validate manifest; `git ls-files` the
   three roots (fall back to a filesystem walk when not in a git tree, for fixtures);
   compute ownership; report unowned and doubly-owned files; `--format` rewrites the
   manifest deterministically.
4. Write `scripts/test-check-components.sh` modelled on `test-check-config-docs.sh`:
   build fixture trees in `mktemp -d`, run the checker with `REPO_ROOT` overridden by
   an env var (`AIUR_COMPONENTS_ROOT`, PROPOSED), assert exit codes and messages.
5. CI: add to `lint` after the config-docs step:
   `- name: Every source file belongs to one component` / `run: python3 scripts/check-components.py`
   (`working-directory: .`, same docs-only guard). Add
   `- name: Test component manifest guard` / `run: bash scripts/test-check-components.sh`
   to `workflow-security` after `ci.yml:177`.
6. Add a row to AGENTS.md "Docs ship with the change" layout notes? No: AGENTS.md is
   changed by C10-T05. Here add one paragraph to `CONTRIBUTING.md` "Enforcement": a new
   source file must be added to `components.json` in the same PR.

## Non-happy paths

- **Unowned new file** in a later PR: lint fails naming the file and the nearest
  component glob. This is intended friction; the fix is one line in the manifest.
- **Ambiguous ownership** (equal-specificity globs): exit 1, both component IDs named.
- **Glob that matches nothing**: exit 1 (`stale path`), so moves cannot leave dead
  globs behind (C11 relies on paths being accurate).
- **Manifest invalid JSON / schema violation**: exit 2 with a JSON pointer.
- **Not a git checkout** (fixtures, tarballs): filesystem walk excluding
  `node_modules`, `_build`, `deps`, `dist`.
- No secrets: the manifest holds paths and module names only.

## Compatibility and rollout

- No runtime change, no config, no migration. Rollback: revert the PR (manifest, script
  and two CI steps go together).
- Concurrent PRs that add files under `src/lib` will fail lint until they add a manifest
  line; announce in the PR body.

## Verification

Self-tests in `scripts/test-check-components.sh` (each a fixture tree):

| Test | Fixture | Expected |
|---|---|---|
| `owned_once_passes` | two components, disjoint globs, three files | exit 0 |
| `unowned_file_fails` | a file under `src/lib/aiur/` no glob matches | exit 1, message names the file |
| `ambiguous_owner_fails` | two components with `src/lib/aiur/x/*.ex` | exit 1, both IDs named |
| `more_specific_glob_wins` | `src/lib/aiur/orchestrator/**` vs `src/lib/aiur/orchestrator/comment_polling*.ex` | exit 0; file owned by the second |
| `stale_glob_fails` | glob matching no file | exit 1 `stale path` |
| `schema_violation_exits_2` | `layer: 7` | exit 2 with pointer `/components/0/layer` |
| `facade_star_requires_pending` | `facades: ["*"]`, `facade_pending: null` | exit 2 |

Commands: `bash scripts/test-check-components.sh` and `python3 scripts/check-components.py`
from the repository root (no Elixir needed).

Mutation check: replace the ownership loop's "more than one owner" branch with `pass`
→ `ambiguous_owner_fails` must fail; make unowned files return early → `unowned_file_fails`
must fail; remove the stale-glob check → `stale_glob_fails` must fail. Run in a worktree
with `git status --porcelain` showing only that hunk.

Real-tree check: `python3 scripts/check-components.py` exits 0 on the implementation
head; record the owned-file count per component in the PR body.

## Completion and handoff

- [ ] `components.json` lists the 41 components with today's paths; checker exits 0.
- [ ] RQ5 placements applied (Muse, AgentTools, AllowedContributors, DaemonHeartbeat,
      AgentContextPresentation, TestTicketScope).
- [ ] Both CI steps added; self-test fails on each mutation above.
- [ ] Every new file < 500 lines.
- [ ] CONTRIBUTING.md paragraph added. No `website/docs-app` change (no operator surface).
- **Dependents:** C1-T02..T06, C4-T05, C10-T01, C11-T01, every C6–C9 move.

## Phase D additions (contract requests)

- **CR-R7-4.** The manifest schema has an optional per-component
  `private_namespaces` list (module prefixes such as `"Aiur.Codex."`), read by the
  C1-T03 private-module rule, so a harness boundary is one data entry
  (MP-R7-C3-T05). Stale allowlist rows already fail (C1-T05) and the walker already
  ignores comments and `@doc` strings (C1-T02).
- **CR-R2-1 / CR-R2-2.** Seed the assignments listed in
  [component-map.md §3 "Phase D assignments"](../component-map.md): the new bus
  modules go to `event-bus`, `debug_log.ex` to `tui`, the GitHub event helpers to
  `github-listeners`, and the value types `tracker_identity.ex` and
  `opaque_identifier.ex` to `kernel`.
