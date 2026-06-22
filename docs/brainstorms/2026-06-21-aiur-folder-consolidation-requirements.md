---
date: 2026-06-21
topic: aiur-folder-consolidation
issue: 391
---

# Consolidate aiur Files into a `.aiur/` Folder

## Problem Frame

aiur scatters its files across the host repo's root: `.aiurconfig`, the hooks file
(`.aiurhooks`), three `*.example` templates, and the agent prompt `AIUR.md`. This
clutters the project root and interleaves aiur's machinery with the project's own
files. aiur should keep its files together in one clearly-namespaced folder — `.aiur/` —
that `aiur init` generates and manages.

The global side already points this way: `~/.aiur/` exists today as aiur's home
(`~/.aiur/logs/` per `src/lib/aiur/log_file.ex:68`; issue #377 adds `~/.aiur/repo/`),
yet the *global config* is still a bare `~/.aiurconfig` dotfile beside it
(`src/lib/aiur/init.ex:861`). Consolidating makes both the repo and global surfaces
symmetric.

aiur is now published to npm (0.0.2) and used outside this repo, so existing
root-level layouts must keep working — this is no longer a free hard cutover. (Contrast
the earlier `2026-06-15-config-consolidation-and-onboarding` brainstorm, which restructured
config *sections* under a no-back-compat assumption; this work is about *file location*,
and back-compat is required.)

---

## Actors

- A1. Developer with a **new** repo: runs `aiur init`, gets a clean `.aiur/` folder, repo root stays tidy.
- A2. Developer with an **existing** repo (root-level `.aiurconfig` etc.): re-runs `aiur init`, sees their saved settings, and is migrated onto `.aiur/` in place.
- A3. Developer who **never re-runs init**: their root-level layout keeps working unchanged via discovery fallback.
- A4. aiur runtime: discovers config/hooks/prompt from `.aiur/` (new) or the legacy locations, resolving pointer files relative to the config's own directory.

---

## Requirements

**A. New layout & naming**
- R1. aiur-owned files live in a `.aiur/` folder with simplified, de-prefixed names: `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`.
- R2. Example templates live under `.aiur/examples/`: `config.example`, `hooks.example`, `prompt.md.example`.
- R3. The config's pointer keys become folder-relative: `hooks_file: hooks` and `prompt_file: prompt.md`. They resolve against the config file's own directory (the existing dirname-relative logic in `src/lib/aiur/workflow.ex`), so no parser change is required.
- R4. The global surface is symmetric: global config is `~/.aiur/config` (+ `~/.aiur/hooks`, `~/.aiur/prompt.md` where applicable), beside the existing `~/.aiur/logs/` and the upcoming `~/.aiur/repo/`.

**B. Discovery & backward compatibility**
- R5. Config discovery follows this precedence (first hit wins): `./.aiur/config` → `./.aiurconfig` (legacy root) → `~/.aiur/config` → `~/.aiurconfig` (legacy global).
- R6. Legacy layouts keep working untouched: a root `.aiurconfig` with inline `hooks:`, or with `hooks_file: .aiurhooks` pointing at a root `.aiurhooks`, resolves exactly as it does today. No legacy repo is required to migrate.
- R7. `.env` / `.env.example` stay at the repo root (general convention, secret-bearing). aiur keeps reading the cwd `.env`. They are **not** moved into `.aiur/`.

**C. Migration via `aiur init`**
- R8. Migration happens on an `aiur init` **re-run** in a repo that still has root-level aiur files. The resume flow: load and **display** the saved settings unchanged → proceed to the file-creation step → announce the migration and confirm (default yes) → perform it.
- R9. Migration moves each root-level file into `.aiur/` with the rename applied (`.aiurconfig`→`config`, `.aiurhooks`→`hooks`, `AIUR.md`→`prompt.md`, examples into `.aiur/examples/`), using `git mv` when the file is tracked and a plain move otherwise, and rewrites the config's `hooks_file:`/`prompt_file:` values to the new folder-relative names.
- R10. Migration preserves the developer's existing settings verbatim — it is a move + pointer-rewrite, never a re-prompt or a settings reset.
- R11. The same `init` step covers the originally-requested gap: when a referenced hooks/prompt file is missing (e.g. a config created before `.aiurhooks` support), the step scaffolds it from the bundled example, announcing what it does.

**D. Documentation & ignore rules**
- R12. When `aiur init` writes a **repo-local** `.aiur/` (location = repo, not global), it asks whether to add `.aiur/` to the repo's `.gitignore`, and appends the entry if the developer says yes. Default behavior when declined: leave `.aiur/` tracked (team-shared config, as `.aiurconfig` was today). The prompt is skipped for global setup (nothing to ignore) and when `.aiur/` is already ignored.
- R13. `README.md`, `SPEC.md`, `AGENTS.md`, and the shipped `.gitignore`/docs are updated to describe the `.aiur/` layout; secret files (`.env`) remain gitignored regardless of the R12 choice.

---

## Acceptance Examples

- AE1. **Covers R1, R2.** `aiur init` in a fresh repo produces `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, and `.aiur/examples/*.example`; the repo root has no `.aiur*`/`AIUR.md` files (only `.env` remains).
- AE2. **Covers R3, R5.** With only `./.aiur/config` present, aiur loads it and resolves `hooks_file: hooks` to `./.aiur/hooks` and `prompt_file: prompt.md` to `./.aiur/prompt.md`.
- AE3. **Covers R6.** A repo with a root `.aiurconfig` (inline `hooks:`) and no `.aiur/` folder runs aiur with identical behavior to before this change — nothing breaks, nothing is required.
- AE4. **Covers R8, R9, R10.** A repo with root `.aiurconfig`/`.aiurhooks`/`AIUR.md`: re-running `aiur init` shows the saved settings, confirms migration, and ends with the files moved into `.aiur/` (history preserved for tracked files), pointer keys rewritten, and settings unchanged.
- AE5. **Covers R4, R5.** With no repo config but a `~/.aiur/config`, aiur resolves the global config and auto-detects the repo from the cwd git remote; a legacy `~/.aiurconfig` is still honored when `~/.aiur/config` is absent.
- AE6. **Covers R12.** Repo-local `aiur init` asks "add `.aiur/` to `.gitignore`?"; answering yes appends `.aiur/` to `.gitignore`, answering no leaves the folder tracked. Global setup never shows the prompt.

---

## Implementation Anchors

*(Context for planning, not design decisions.)*
- `src/lib/aiur/workflow.ex:29` — `resolve_config_path/2`: the real discovery entry point (cwd `.aiurconfig` → `~/.aiurconfig`); becomes the 4-step chain in R5.
- `src/lib/aiur/workflow.ex` — `resolve_hooks/2`, `resolve_prompt/2`, `resolved_hooks_file_path/1`, `resolved_prompt_file_path/1`: already resolve pointers relative to the config dir; should need no logic change once the config lives in `.aiur/`.
- `src/lib/aiur/init.ex` — `run/3`, `fresh_setup/5`, `resume/3`, `existing_config_target/2`, `config_target/1`, `ensure_aiurhooks/3`, `write_aiurhooks/1`, `ensure_prompt_file/5`: the wizard surface where new-layout scaffolding (R1, R2) and migration (R8–R11) land.
- `src/lib/aiur/workflow_store.ex` — change-polling reads the resolved pointer paths; verify it tracks the `.aiur/` files.
- Related: issue #377 (warm base) uses `~/.aiur/repo/<owner>/<name>`; layout stays compatible.

---

## Outstanding Questions

- OQ1. **Collision check (verify in planning):** confirm nothing already writes a repo-local `./.aiur/` directory. Grounding scan found only `~/.aiur/` (global, logs) usages — no repo-local writer — but planning should confirm before relying on it.
- OQ2. **Migration atomicity:** if a `git mv` partially fails (e.g. dirty index, file not yet committed), should init abort-and-restore or fall back to a plain move per-file? Default leaning: per-file `git mv`-or-move, never leave a half-migrated state that aiur can't load.
- OQ3. **Global migration trigger:** the global `~/.aiurconfig`→`~/.aiur/config` move — does it ride the same `aiur init` re-run (when location=global), or is it a one-time lazy move on first global read? Leaning toward the init path for symmetry with R8.
- OQ4. **Gitignore × migration interaction (R12 × R9):** if the developer opts to gitignore `.aiur/` while migrating files that were previously **tracked** (root `.aiurconfig`), should migration `git rm --cached` them so the ignore actually takes effect (a `git mv` into an ignored path stays tracked)? Leaning yes — honoring the ignore choice means untracking — but planning should confirm the exact git sequence.

---

## Scope Boundaries

- **In scope:** the `.aiur/` repo + global layout, simplified names, the discovery chain, init-driven migration with settings preserved, and doc/ignore updates.
- **Deferred for later:** warm-base hooks (#377) — separate ce cycle; this work only guarantees the `~/.aiur/` layout stays compatible.
- **Outside identity:** moving `.env` into `.aiur/` (R7), and re-prompting/restructuring settings during migration (that was the 2026-06-15 consolidation work, already shipped).
