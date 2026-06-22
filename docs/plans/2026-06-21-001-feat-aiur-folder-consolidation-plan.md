---
title: "feat: Consolidate aiur files into a `.aiur/` folder"
date: 2026-06-21
type: feat
issue: 391
origin: docs/brainstorms/2026-06-21-aiur-folder-consolidation-requirements.md
---

# feat: Consolidate aiur Files into a `.aiur/` Folder

## Summary

Move aiur-owned files (`config`, `hooks`, `prompt.md`, and `examples/`) into a `.aiur/`
folder — repo-local (`./.aiur/`) and global (`~/.aiur/`, beside the existing
`~/.aiur/logs/`) — with simplified names, a 4-step backward-compatible discovery chain, and
an `aiur init`-driven migration that preserves and displays existing settings before moving
files. Legacy root-level layouts keep working untouched.

The change concentrates in two seams the research confirmed: **config discovery**
(`Aiur.Workflow.resolve_config_path/2`, currently 2-candidate → 4-candidate) and the
**`aiur init` wizard** (`Aiur.Init`, fully `io`/`deps`-injected). Pointer resolution
(`hooks_file:`/`prompt_file:`) is already dirname-relative everywhere, so no parser, loader,
or `WorkflowStore` logic change is required — a config at `.aiur/config` resolves
`hooks_file: hooks` → `.aiur/hooks` for free (see origin: R3, R6).

---

## Problem Frame

aiur scatters its files across the host repo's root (`.aiurconfig`, `.aiurhooks`,
`AIUR.md`, three `*.example` files), interleaving its machinery with the project's own
files. The global side is already inconsistent: `~/.aiur/` exists as aiur's home
(`~/.aiur/logs/`; #377 adds `~/.aiur/repo/`) yet the global config is a bare `~/.aiurconfig`
dotfile beside it. aiur now ships on npm (0.0.2) and is used outside this repo, so the
move must be backward compatible — unlike the prior `2026-06-15` config-consolidation work,
which restructured config *sections* under an explicit no-back-compat assumption that is now
superseded.

---

## Requirements Traceability

Carried from origin (`docs/brainstorms/2026-06-21-aiur-folder-consolidation-requirements.md`):

| Origin | Covered by |
|---|---|
| R1 simplified names `.aiur/{config,hooks,prompt.md}` | U2 |
| R2 `.aiur/examples/*.example` | U2 |
| R3 folder-relative pointer keys, no parser change | U1, U2 (KTD2) |
| R4 symmetric global `~/.aiur/config` | U1, U3 |
| R5 4-step discovery precedence | U1 |
| R6 legacy layouts keep working | U1 (KTD1) |
| R7 `.env` stays at repo root | (no-op; verified unchanged) U4 |
| R8 migration on init re-run: show settings → confirm → migrate | U3 |
| R9 `git mv` when tracked + pointer rewrite | U3 (KTD3) |
| R10 settings preserved verbatim | U3 |
| R11 scaffold missing hooks/prompt from example | U2 |
| R12 repo-local `.gitignore` opt-in prompt | U2 (helper), U3 (reuse) |
| R13 docs updated | U4 |

---

## Key Technical Decisions

**KTD1 — Discovery becomes an ordered 4-candidate list; first existing wins.**
`resolve_config_path/2` (`src/lib/aiur/workflow.ex:34`) currently takes two paths
(local/global) and is a 3-branch function. Replace it with an ordered candidate list —
`./.aiur/config` → `./.aiurconfig` → `~/.aiur/config` → `~/.aiurconfig` — returning the
first `File.regular?` hit. When none exist, return the new repo-local primary
(`./.aiur/config`) as the default target so not-found messaging points at the new layout.
`detect_run_folder_config/0` (lines 28-30) builds the candidate list. The app-env override
path (`workflow_file_path/0`, explicit CLI path) is unchanged. (Resolves the origin's note
that R5 is a real signature change, not a drop-in.)

**KTD2 — Pointer keys stay folder-relative; no parser/loader/store change.** Research
confirmed `resolve_hooks/2`, `resolve_prompt/2`, `resolved_{hooks,prompt}_file_path/1`
(`workflow.ex:114,146,172,189`) and the init writers (`init.ex:883,894`) and
`WorkflowStore` stamps (`workflow_store.ex:154,167`) all use
`Path.expand(rel, Path.dirname(config_path))`. The migrated config is written with
`hooks_file: hooks` and `prompt_file: prompt.md`; everything downstream resolves relative to
`.aiur/`. Legacy `hooks_file: .aiurhooks` beside a root config still resolves to the root
file. **Do not touch the parser or store.**

**KTD3 — Migration rides the existing init resume branch; old config removed last (OQ2).**
No new top-level command. Extend `resume/3` (`init.ex:140-152`): when the resolved config
sits at a **legacy** location, after displaying saved settings, announce + `confirm`
(default yes), then migrate. Per-file move order that never leaves a state aiur can't load:
(1) create `.aiur/`, (2) move `hooks`/`prompt`/examples in, (3) write the rewritten config to
`.aiur/config`, (4) only then remove the legacy root config. `git mv` when the file is
tracked, plain `File.rename` otherwise. Covers repo-local and global (OQ3: global migration
rides the same re-run when the resolved config is `~/.aiurconfig`).

**KTD4 — `.gitignore` opt-in via a new injected dep; `git rm --cached` when ignoring tracked
files (OQ4).** A `git mv` into a gitignored path stays tracked, so honoring "ignore `.aiur/`"
for previously-tracked files requires `git rm --cached`. New `add_gitignore_entry` dep
appends `.aiur/` to the repo `.gitignore` (idempotent), and when the user opts in during
migration of tracked files, the files are `git rm --cached`'d so the ignore takes effect.
Prompt fires only for **repo-local** setup (skipped for global; skipped when `.aiur/` already
ignored).

**KTD5 — `.env` unchanged.** `ensure_env/1` stays `File.cwd!()`-anchored (`init.ex:1076`);
`.env`/`.env.example` remain at the repo root, kept out of git by the already-shipped
`.gitignore` rules (origin: R7).

**KTD6 — Name constants threaded through both modules.** `@config_file_name ".aiurconfig"`
is hardcoded in **both** `workflow.ex:13` and `init.ex:19`. Introduce the new-layout
constants (folder `.aiur`, `config`, `hooks`, `prompt.md`, `examples/`) plus the retained
legacy names in both modules.

OQ1 (collision) is resolved: research confirmed no code reads/writes a repo-local `./.aiur/`
— the namespace is free.

---

## High-Level Technical Design

Discovery + init dispatch after this change:

```
workflow_file_path/0
  ├─ app-env override set? ──► use it (explicit CLI path / tests)   [unchanged]
  └─ else detect_run_folder_config/0
        └─ resolve_config_path([./.aiur/config, ./.aiurconfig,
                                ~/.aiur/config, ~/.aiurconfig])
              └─ first File.regular? wins ; none → ./.aiur/config (default)

aiur init  (run/3)
  ├─ existing_config_target found?
  │     ├─ at NEW location (.aiur/config) ─► resume: show settings, ensure files [U2 scaffolding]
  │     └─ at LEGACY location ────────────► resume: show settings
  │                                           └─ announce + confirm migration   [U3]
  │                                                ├─ move files → .aiur/ (git mv | rename)
  │                                                ├─ write rewritten .aiur/config (pointers)
  │                                                ├─ remove legacy config (last)
  │                                                └─ repo-local? gitignore opt-in [U2 helper]
  └─ none found ─► fresh_setup: write .aiur/ layout + gitignore opt-in (repo-local) [U2]
```

---

## Output Structure

Repo-local result of `aiur init` (committed unless the developer opts into ignoring it):

```
.aiur/
  config            # was .aiurconfig
  hooks             # was .aiurhooks  (hooks_file: hooks)
  prompt.md         # was AIUR.md     (prompt_file: prompt.md)
  examples/
    config.example  # was .aiurconfig.example
    hooks.example   # was .aiurhooks.example
    prompt.md.example  # was AIUR.md.example
.env                # stays at root (unchanged)
```

---

## Implementation Units

### U1. 4-step config discovery chain + name constants

**Goal:** Discovery resolves `.aiur/config` and the global `~/.aiur/config` while keeping
legacy root/home dotfiles working.

**Requirements:** R3, R4, R5, R6 (KTD1, KTD2, KTD6)

**Dependencies:** none

**Files:**
- `src/lib/aiur/workflow.ex` — name constants (lines ~13); `detect_run_folder_config/0`
  (28-30) builds the 4 candidates; `resolve_config_path/2` → ordered-list resolver (34-40).
- `src/test/aiur/workflow_test.exs` (or the existing discovery test file) — discovery tests.

**Approach:** Replace the two-arg `resolve_config_path/2` with a candidate-list resolver
(first `File.regular?` wins; none → `./.aiur/config`). Keep `workflow_file_path/0`'s app-env
override branch untouched. Add `@aiur_dir ".aiur"`, `@config_basename "config"`, and retain
`@legacy_config_file_name ".aiurconfig"`. Do **not** modify pointer resolvers or the loader.

**Patterns to follow:** existing `Path.expand("~/" <> ...)` + `File.regular?` idiom already in
`resolve_config_path/2`; `Application.get_env(:aiur, :workflow_file_path)` override (line 17).

**Test scenarios:**
- Covers AE2. Only `./.aiur/config` present → it is resolved; `hooks_file: hooks` and
  `prompt_file: prompt.md` resolve to `./.aiur/hooks` / `./.aiur/prompt.md`.
- Covers AE3. Only legacy `./.aiurconfig` present (no `.aiur/`) → resolved unchanged.
- Repo-local new beats legacy: both `./.aiur/config` and `./.aiurconfig` present → `.aiur/config` wins.
- Covers AE5. No repo config, `~/.aiur/config` present → global new resolved; only `~/.aiurconfig`
  present → legacy global resolved.
- Full precedence order asserted across all four candidates.
- None present → returns `./.aiur/config` default (drives not-found messaging).
- App-env explicit path override still short-circuits discovery.

**Verification:** discovery tests pass for all four candidate positions and the empty case;
`mix test` green for `workflow`/`workflow_store` suites.

### U2. Fresh-setup `.aiur/` scaffolding + repo-local `.gitignore` opt-in

**Goal:** A fresh `aiur init` writes the `.aiur/` layout with simplified names and offers to
gitignore it (repo-local only).

**Requirements:** R1, R2, R3, R11, R12 (KTD4, KTD6)

**Dependencies:** U1

**Files:**
- `src/lib/aiur/init.ex` — `config_target/1` (861-862) → `.aiur/config` (repo) /
  `~/.aiur/config` (global); `write_aiurhooks/1` → writes `.aiur/hooks` from the hooks example;
  `write_prompt_file/3` → `.aiur/prompt.md`; scaffold `.aiur/examples/*`; the written config
  uses `hooks_file: hooks` / `prompt_file: prompt.md`; new `add_gitignore_entry` dep in
  `@type deps()` (73-88) and `runtime_deps/0` (842-859); a `prompt_gitignore` step in
  `fresh_setup/4` for repo-local.
- `src/test/aiur/init_test.exs` — extend the base `deps` fixture (46-99) with the new dep key;
  update path assertions (`.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`); location-label test
  (line 527) to the new option strings.
- `src/lib/aiur/init/prompt.ex` — reuse existing `confirm` (default-yes) primitive; no change expected.

**Approach:** Thread the new-layout names through the writers (KTD6). Keep the
scaffold-not-clobber behavior (`{:created|:exists}`). Add one injected dep
`add_gitignore_entry: (repo_root, entry) -> {:added|:exists, path}`; call it from a new
repo-local-only prompt step after the files are written. Global setup skips the prompt and
omits `prompt_file`/examples per existing global behavior.

**Patterns to follow:** the `.aiurhooks` (#388) scaffold-not-clobber pattern
(`ensure_aiurhooks`/`write_aiurhooks`); injected-dep + `runtime_deps/0` wiring; the fixture
key-for-key sync the research flagged (deps typespec ↔ `runtime_deps/0` ↔ test fixture).

**Test scenarios:**
- Covers AE1. Fresh repo-local init writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`,
  `.aiur/examples/*`; no `.aiur*`/`AIUR.md` at repo root.
- Written config contains `hooks_file: hooks` and `prompt_file: prompt.md`.
- Covers AE6. Repo-local init asks the gitignore prompt; "yes" appends `.aiur/` to `.gitignore`;
  "no" leaves it absent.
- Global init writes `~/.aiur/config` and does **not** show the gitignore prompt.
- `.gitignore` already containing `.aiur/` → prompt is skipped / dep returns `:exists` (idempotent).
- Existing hooks/prompt file present → scaffolder reports `:exists`, does not clobber (R11).

**Verification:** `init_test.exs` green; manual `aiur init` in a scratch dir produces the tree
in Output Structure; `.gitignore` updated only on opt-in.

### U3. Legacy → `.aiur/` migration on init re-run (repo + global)

**Goal:** Re-running `aiur init` on a root-level layout shows saved settings, confirms, and
migrates files into `.aiur/` with history preserved and settings unchanged.

**Requirements:** R8, R9, R10, R4 (KTD3, KTD4)

**Dependencies:** U1, U2

**Files:**
- `src/lib/aiur/init.ex` — `existing_config_target/2` (129-135) detects legacy vs new location
  and flags migration; `resume/3` (140-152) gains the announce + `confirm` + migrate branch;
  new `migrate_layout` dep (typespec + `runtime_deps/0`) encapsulating per-file `git mv`/rename,
  pointer rewrite, legacy-config removal, and (repo-local opt-in) `git rm --cached`; reuse
  `add_gitignore_entry` from U2.
- `src/test/aiur/init_test.exs` — base `deps` fixture gains `migrate_layout`; new tests for the
  migration branch (tracked + untracked; repo + global; gitignore opt-in).

**Approach (KTD3 order):** create `.aiur/` → move `hooks`/`prompt`/examples (git mv when
tracked, else rename, applying the rename) → write rewritten `.aiur/config` (pointers updated,
all other settings byte-preserved) → remove legacy config last. For repo-local, run the
gitignore opt-in; if the developer opts in and the moved files were tracked, `git rm --cached`
them. Global (`~/.aiurconfig` → `~/.aiur/config`) runs the same move minus the gitignore step.

**Execution note:** Add a failing test for the legacy→`.aiur/` resume branch first — the
move-order invariant (config removed last) and the `git rm --cached`-on-ignore interaction are
the easy-to-regress parts.

**Test scenarios:**
- Covers AE4. Repo with tracked `.aiurconfig`/`.aiurhooks`/`AIUR.md`: re-run shows saved
  settings, confirms, ends with files under `.aiur/` (git-tracked move), pointers rewritten,
  settings unchanged; legacy root files gone.
- Untracked legacy files → plain rename move; same end state.
- Global legacy `~/.aiurconfig` only → migrated to `~/.aiur/config`; no gitignore prompt.
- Covers AE6 (migration path). Repo-local migration + gitignore "yes" on tracked files →
  `.aiur/` appended to `.gitignore` AND files `git rm --cached`'d (untracked, ignore effective).
- Decline confirmation → no files moved; legacy layout intact and still loadable.
- Move-order invariant: if writing `.aiur/config` fails, the legacy config is **not** removed
  (aiur still loads).
- Settings byte-preservation: every non-pointer key in the migrated config equals the original.

**Verification:** migration tests green; manual: a scratch repo with root files, `aiur init`,
confirm → `.aiur/` populated, `git status` shows renames (or cached removals on ignore),
`aiur` still loads the config.

### U4. Fixtures, reset flows, and documentation

**Goal:** Keep the full suite green and document the new layout.

**Requirements:** R7, R13

**Dependencies:** U1, U2, U3

**Files:**
- `src/test/fixtures/*.aiurconfig` and `src/config/config.exs` (test `workflow_file_path`) —
  ensure the test config path still loads under the new discovery; add a `.aiur/`-layout fixture
  if useful.
- `src/lib/aiur/cli.ex` `--test`/`--test3` reset flows — verify they write/clear the correct
  paths under the new layout (research flagged these write real config files).
- `README.md`, `SPEC.md`, `AGENTS.md` — describe `.aiur/`, the discovery precedence, and the
  migration-on-init behavior; note `.env` stays at root.
- `.gitignore` / `src/.gitignore` — no rule change required for `.env`; confirm `.aiur/` is NOT
  globally ignored (it's a per-repo opt-in), only the doc mention.
- `src/lib/aiur/workflow_store.ex:3` doc comment — refresh the `.aiurconfig` mention.

**Approach:** Mechanical follow-through. Run the whole suite from `src/`; fix any fixture or
reset-flow path assumptions surfaced. Documentation reflects the resolved decisions only.

**Test scenarios:** `Test expectation: none — fixtures/docs/reset-flow wiring; covered by the
existing suite running green end-to-end (`mix test`).` Add one fixture-load assertion if a
`.aiur/`-layout fixture is introduced.

**Verification:** `mise exec -- mix test` (full suite), `mix credo --strict`,
`mix format --check-formatted`, `mix dialyzer` all green from `src/`; `grep` shows no stale
`.aiurconfig`-only references in user-facing docs.

---

## Scope Boundaries

**In scope:** `.aiur/` repo + global layout, simplified names, 4-step discovery, init-driven
migration (settings preserved), repo-local gitignore opt-in, docs/fixtures.

**Deferred to Follow-Up Work:** none required for this PR.

**Outside this work:**
- `.env` into `.aiur/` — explicitly kept at root (origin: R7).
- Warm-base #377 — separate ce cycle; its `~/.aiur/repo/` stays compatible with this layout.
- Re-prompting / restructuring settings during migration — that was the shipped 2026-06-15
  consolidation; migration here is move + pointer-rewrite only.

---

## Risks & Dependencies

- **Test-fixture coupling (high-touch, low-risk):** the `deps` base map in
  `init_test.exs:46-99` must stay key-for-key in sync with `@type deps()` and `runtime_deps/0`;
  every new dep (`add_gitignore_entry`, `migrate_layout`) lands in all three or tests break at
  call time. Called out in U2/U3 file lists.
- **Migration atomicity (OQ2):** mitigated by KTD3's move order (legacy config removed last) and
  the explicit move-order invariant test in U3.
- **`git rm --cached` interaction (OQ4):** the non-obvious corner; covered by a dedicated U3 test.
- **`git mv` in CI / non-repo dirs:** migration must fall back to plain rename when the file is
  untracked or not in a git work tree (scratch dirs, `--test` flows); U3 covers tracked +
  untracked.

---

## Sources & Research

- Origin requirements: `docs/brainstorms/2026-06-21-aiur-folder-consolidation-requirements.md`.
- Precedent: `.aiurhooks`/`hooks_file` support (#388, commit `a41c99e`) — dirname-relative
  pointer + scaffold-not-clobber + `WorkflowStore` re-stamp; the closest template.
- Contrast: `docs/plans/2026-06-15-001-feat-config-consolidation-onboarding-plan.md` — reuse its
  injected-`io`/`deps` test seam; invert its no-back-compat migration stance.
- Discovery/init research confirmed: single discovery entry point (`resolve_config_path/2`),
  dirname-relative pointers throughout, `./.aiur/` free, no gitignore-append precedent,
  `WorkflowStore` follows files automatically.
