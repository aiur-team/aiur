---
ticket_id: MP-R1-C10-T1
feature_id: MP-R1
chunk_id: MP-R1-C10
bucket: 1-refactor
title: Public manifest fields and the generated planned-features list in components.json
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1]
prior_units: [U0, U8]
prior_boundaries: ["#40 docs-site"]
prior_features: []
prior_findings: []
size_owner: n/a   # ledger pinned at 465aca643; re-resolve at ticket start against the current U8 ledger (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C10-T1 — Public manifest fields and the planned-features list

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (refactor), MP-R1, chunk C10 (public
  component directory page, MP-REQ4, decision D20).
- **User value:** the public directory page (C10-T3/T5) and its "Planned" section are
  generated from one file that CI already enforces against the code. Nobody writes the
  component list or the roadmap list by hand, so the page cannot drift from the code.
- **Deliverable:** an extension of the root manifest `components.json` and its schema
  `components.schema.json` (both created by MP-R1-C1-T1) with:
  1. the **public fields** of each component (`name`, `summary`, `status`, `kind`,
     `install`, `docs`, `config`, `env`), validated by the schema;
  2. a top-level **`features` array** of planned features, each with a public flag and
     a one-line public summary. The page's "Planned" list is generated from this array
     only;
  3. a filled-in public entry for every component in
     [component-map.md §3](../component-map.md) and one `features` entry per Bucket-2 and
     Bucket-3 feature (MP-E1 … MP-N7), with `public: false` by default.
- **Scope:** data and schema only. No page, loader, check rule or sidebar change.
- **Non-goals:** rendering (C10-T2/T3), CI checks (C10-T4), publishing (C10-T5),
  changing any component's `paths`/`facades`/`layer` (C1 owns those), deciding which
  planned features are public (DESIGN-R1 §3 Q4/Q5 — Kevin).

## Dependencies and blockers

- **Blocked by DESIGN-R1** (feature gate, MP-REQ2). The schema can be written once
  DESIGN-R1 §1 is approved; the **content** of public summaries and the value of each
  `public` flag follow DESIGN-R1 §3 Q1 (fields shown), Q4 (how public) and Q5 (which
  planned features). Until Q4/Q5 are answered, every `features[].public` stays `false`.
- **MP-R1-C1-T1** creates `components.json` + `components.schema.json`. This ticket
  extends that schema; it must not fork it.
- **MP-R1-C1-T1** wires `scripts/check-components.py` into the required `lint` job; the
  schema validation added here runs through that checker.
- **Capability IDs:** `capabilities` values are validated against the capability enum
  published by the MP-R1-C3 contracts-package ticket (plan ID C3-T6; confirm in the C1–C5 README) (`packages/aiur-contracts`, PROPOSED). If C3-T6 has not
  merged, this ticket ships `capabilities` as a free list and C10-T4 adds the
  cross-check (recorded there).
- **May run concurrently with:** C10-T2 (loader can be developed against a fixture
  manifest), C10-T4 (check rules can be developed against fixtures), every C6–C9 move
  (moves change `paths`, not public fields).

## Verified starting point (base `45a290e3`)

- No `components.json` or `components.schema.json` exists at `45a290e3`
  (`git ls-tree -r --name-only 45a290e3 | grep components` is empty). Both are PROPOSED,
  created by MP-R1-C1-T1.
- Field list and public/private split are designed in
  [component-directory.md §3](../component-directory.md). That table has a `status`
  value `planned` for components, but no place for a planned **feature** that only
  extends an existing component (for example MP-E2 extends `commands`; it adds no
  component). This ticket adds the `features` array for that case — a change to
  component-directory.md recorded in [README-C6-C11.md](README-C6-C11.md).
- Component IDs, names and owners: [component-map.md §3](../component-map.md)
  (41 components, layers L0–L5). Config section owners:
  [component-map.md §5](../component-map.md), from `src/lib/aiur/config/schema.ex:52-71`.
- Feature list and one-line intended outcomes: `feature-inventory.md` (research branch
  only — research was removed from `main` by PR #2921, see
  component-directory.md §1). Public summaries must therefore be written fresh in the
  manifest, never linked to research docs.
- Existing docs page paths that `docs` fields may point at (all exist at `45a290e3`):
  `website/docs-app/reference/{cli,configuration,optional-optimizations}.md`,
  `website/docs-app/concepts/{executor,units,commands,build-orders,ticket-lifecycle,operating-aiur,message-bus}.md`,
  `website/docs-app/guide/{quick-start,tui,gui,stream-deck}.md`,
  `website/docs-app/apis/{github,elevenlabs}.md`, `website/docs-app/skills.md`
  (sidebar `website/docs-app/.vitepress/config.ts:126-170`).
- Env var names a component may list (names only): `AIUR_DASHBOARD_USERNAME`,
  `AIUR_DASHBOARD_PASSWORD`, `GITHUB_TOKEN`, `GITHUB_APP_*`, `AIUR_SUPERVISOR_TOKEN`,
  `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`,
  `OPENROUTER_MANAGEMENT_KEY` (AGENTS.md § Auth at `45a290e3`), plus
  `AIUR_GITHUB_WEBHOOK_SECRET` and `ELEVENLABS_API_KEY` (component-map.md §3). The
  canonical list is the env-var schema checked by `scripts/check-env-example.py`
  (`ci.yml:268-271`); C10-T4 cross-checks names against it.

## Chosen design

### Manifest additions (schema excerpt, JSON Schema draft 2020-12)

```json
{
  "components": [ { "...C1 fields (id, layer, paths, facades, requires, optional, allowlist)...": "",
    "name": "Build Orders",
    "summary": "Shows a dependency graph of tickets and how far a build order has progressed.",
    "status": "optional",
    "kind": "in-app",
    "install": { "type": "included" },
    "capabilities": ["build_orders", "build_orders.progress"],
    "config": ["build_order"],
    "env": [],
    "docs": ["concepts/build-orders.md"]
  } ],
  "features": [
    { "id": "MP-E2",
      "name": "Native question capture",
      "summary": "Agent questions become Commands that reach the right responder.",
      "extends": ["commands", "harness-adapters"],
      "adds": [],
      "public": false,
      "shipped_in": null }
  ]
}
```

- `status` enum: `core | optional | experimental | planned | deprecated`.
  `planned` is allowed only for a component with an empty `paths` list (it does not
  exist yet: `listener-modes`, `voice-conversation`, `pairing-discovery`, `push-relay`,
  `mobile-app`, `watch-apps`, `aiur-contracts` until C3-T6, `build-queue` until MP-E1
  merges). A `planned` component must be named in some `features[].adds`.
- `kind` enum: `in-app | package | repository | client`.
- `install`: `{ "type": "included" }` or `{ "type": "npm", "package": "<name>" }` or
  `{ "type": "setup", "docs": "<docs path>" }`.
- `summary`: required, one sentence, ≤ 140 characters, no trailing whitespace, must not
  contain a path, a module name (`/[A-Z][a-z]+\.[A-Z]/`), or a `#<number>` reference.
  Reason: public copy must survive moves (DESIGN-R1 Q8) and must not leak internals.
- `env`: names only, pattern `^[A-Z][A-Z0-9_]*\*?$`. A value is never stored.
- `docs`: paths relative to `website/docs-app/`, no leading slash, `.md` suffix.
- `features[]`:
  - `id` pattern `^MP-(E|N)[0-9]+$` (Bucket-1 features are refactor work and are not
    "planned features"); unique.
  - `extends` and `adds` hold component IDs; `adds` may name only `planned`
    components; the union is non-empty.
  - `public`: boolean, default `false`. Only an entry with `public: true` is rendered.
  - `shipped_in`: `null` or a release tag string; when non-null the entry is not
    rendered in "Planned" (C11-T2 flips it).
  - `name`/`summary`: same rules as components.
- **Feature IDs are private fields.** The page never renders `features[].id` unless
  DESIGN-R1 Q4 approves it; the loader (C10-T2) enforces that, not this schema.

### Why a separate `features` array

A planned **feature** is not always a planned **component** (MP-E2, E3, E4, E5 extend
existing components). Putting features on components would either invent components or
hide features. One array keeps one source for the "Planned" list (MP-REQ4: "generated
from R1's final component map"), and `extends`/`adds` link each feature to the
components the page already shows. Rejected: a separate `roadmap.json` (second source),
or Markdown (drifts).

### Invariants

- I1: every component has all public fields; validation fails otherwise.
- I2: a feature with `public: true` has a summary that passed the copy rules.
- I3: no field holds a secret value, path to a secret, hostname or IP.
- I4: `features[].adds ⊆ {components with status planned}`.

## Implementation steps

1. Extend `components.schema.json` (PROPOSED path, repo root) with the public fields
   above and the `features` array (`additionalProperties: false` on each entry).
2. Add public fields to every existing manifest entry. Source for summaries:
   operator-facing wording from the existing docs pages listed above; one sentence each.
3. Add one `features` entry per MP-E1 … MP-E7 and MP-N1 … MP-N7 (14 entries) with
   `public: false`, `shipped_in: null`, and `extends`/`adds` from
   [component-map.md §3](../component-map.md) (for example MP-N4 `adds: [push-relay]`,
   `extends: [identity, commands, event-bus]`). MP-E1: if it has merged by the time
   this ticket runs, set `shipped_in` to its release tag and set `build-queue` status to
   `optional`.
4. Extend `scripts/check-components.py` schema validation (from C1-T1) to apply rules
   I1–I4 (I3 as a deny-pattern scan: `token`, `password`, `secret=`, `://`, IPv4
   regex, `.ts.net`).
5. Add fixtures to `scripts/test-check-components.sh` (created by C1-T1) for each new
   rule.
6. After DESIGN-R1 §3 Q4/Q5 are answered: a follow-up commit in this ticket's PR (or a
   one-line data PR) sets `public: true` on the approved features. If the answers are
   not available, the PR merges with all `false` and the ticket's checklist records it.

Estimated change: ~120 lines of schema and checker code, ~400 lines of manifest data
(data, not production code).

## Non-happy paths

- **Design answers missing:** all `public: false`; the page renders the empty-section
  copy (C10-T3). No improvised public roadmap.
- **Planned component later ships under a different ID:** C11-T2 renames it; the
  checker fails on a dangling `adds` reference, so the rename cannot be partial.
- **Leaked internals in copy:** rejected by the summary rules (module names, paths,
  issue numbers). False positive (for example a product name with a dot): change the
  wording; no allowlist for copy.
- **Privacy:** env var **names** only (brief §7; DESIGN-R1 Q1 plan suggestion). The
  deny-pattern scan fails the PR if a value-like string appears.
- **Concurrent edits** (C6–C9 moves change `paths` in the same file): JSON merge
  conflicts are textual and local to one entry; keep one entry per line block and
  sorted by `id` (C1-T1 convention) so conflicts stay small.

## Compatibility and rollout

- No runtime, config or CLI change. `components.json` is read only by
  `check-components.py` and (later) the docs loader.
- No migration. Rollback is a revert; the checker and the page tolerate the fields
  being absent only before this ticket merges (C10-T2's loader fails loudly if they
  are missing after).
- Size: `components.json` will grow toward ~1,000 lines as data. The U0 transitional
  gate counts all tracked UTF-8 text (U0 plan). If the gate is installed, a new file
  over 500 lines fails. **Resolution:** keep the manifest under 500 lines by splitting
  it into `components/<layer>.json` files plus `components/features.json`, assembled by
  the checker and the loader. C1-T1 picks the physical layout; this ticket follows it.
  MP-R1-C1-T1 already specifies this split when the file would exceed 500 lines
  (its "Size" note), so no extra request is needed.

## Verification

Automated (all in `scripts/test-check-components.sh`, each must fail without the
guarded rule):

| Test case | Fixture | Expected |
|---|---|---|
| `missing_public_field_fails` | component without `summary` | exit 1, message names the component and field |
| `planned_with_paths_fails` | `status: planned` and a non-empty `paths` | exit 1 |
| `feature_adds_non_planned_fails` | `features[].adds: ["orchestration"]` | exit 1 |
| `summary_with_module_name_fails` | summary contains `Aiur.Orchestrator` | exit 1 |
| `summary_with_path_fails` | summary contains `src/lib` | exit 1 |
| `env_value_fails` | `env: ["GITHUB_TOKEN=abc"]` | exit 1 |
| `feature_bucket1_id_fails` | `features[].id: "MP-R3"` | exit 1 |
| `valid_manifest_passes` | real tree | exit 0 |

Mutation check: for each case, delete the corresponding rule in
`check-components.py`, run `bash scripts/test-check-components.sh` and confirm it
fails; restore and confirm it passes (AGENTS.md "Tests must fail without the
production change"). Run in a worktree; `git status --porcelain` must show only the
revert.

Commands:

```bash
python3 scripts/check-components.py
bash scripts/test-check-components.sh
python3 -c "import json;json.load(open('components.json'))"   # or each components/*.json
```

Manual: none (no rendered surface yet).

## Completion and handoff

- [ ] Schema has the public fields and the `features` array with the rules above.
- [ ] Every component has public fields; 14 feature entries exist.
- [ ] `public` flags match DESIGN-R1 §3 Q4/Q5 answers, or are all `false` with the
      reason in the PR body.
- [ ] Each new checker rule has a failing fixture and a recorded mutation result.
- [ ] Docs: none required by AGENTS.md (no config key, CLI flag or surface yet).
      `CONTRIBUTING.md` § Documentation (line 144 at `45a290e3`) gains one line naming the manifest
      as the source of the public page (the page itself ships in C10-T5).
- **Dependents:** C10-T2, C10-T3, C10-T4, C10-T5, C11-T2 (flips `shipped_in`).
- **Sources:** [component-directory.md](../component-directory.md),
  [DESIGN-R1](../../../owner-design-tasks/DESIGN-R1.md) §3,
  JSON Schema 2020-12 (https://json-schema.org/draft/2020-12, accessed 2026-10-06).
