# T-032: init wave 2: Scaffold, Migration, Prewarm, Alerts

**Phase:** 3
**Depends-on:** T-031
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/init.ex` began this refactor at 2,253 lines — the entire
interactive `aiur init` wizard in one module (`.aiur/` layout, config
generation, hooks/alerts/prewarm scaffolds, CODEOWNERS, never-clobber writers,
legacy-layout migration, resume backfill #411, GitHub label provisioning). It is
inside history hotspot row 7 ("Init & config scaffolding", ~14 incidents:
fresh-install scaffold gaps; `.aiur/` layout move broke compile-time paths,
skills, alerts; init clobbers real configs #649/#724) and row 15 (alerts, #702).
The binding decomposition plan and name map are in
`docs/refactor/research-arch/giant-init.md` (§2 is the name-map contract, §4 is
the required-verbatim semantics).

T-031 was the first init wave: it extracted `Aiur.Init.Runtime`,
`Aiur.Init.Format`, `Aiur.Init.Questions`, `Aiur.Init.Resume`, and
`Aiur.Init.Templates`, and added the facade `defdelegate`s for the template
accessors and `parse_dotenv/1`. This is **init wave 2 of 3**: extract the
filesystem layer (`Aiur.Init.Scaffold`, `Aiur.Init.Migration`) and the
warm-base + alerts opt-in flows (`Aiur.Init.Prewarm`, `Aiur.Init.Prewarm.Failure`,
`Aiur.Init.Alerts`). T-033 (the final wave) extracts the remaining
CODEOWNERS/Labels/GitHub/AgentCli/Dotenv concerns and slims `Aiur.Init` to a
flow-plus-facade module. After this wave the repo compiles clean and the full
suite passes with **zero edits** to `src/test/aiur/init_test.exs`.

## Scope (exact)

**Binding name map:** `docs/refactor/research-arch/giant-init.md` §2 — the rows
for `Aiur.Init.Scaffold`, `Aiur.Init.Migration`, `Aiur.Init.Prewarm`,
`Aiur.Init.Prewarm.Failure`, and `Aiur.Init.Alerts`. Module names, file paths,
and function-to-module assignments below are copied verbatim from that table and
are **not negotiable**. `giant-init.md` §4 (Risks) names the semantics that must
be preserved verbatim — read it before writing a line.

**Line numbers cannot be trusted this wave.** T-031 already moved ~700 lines out
of `init.ex`, so every line range in the research doc has shifted. **Locate every
function by name and arity**, never by line number.

**Decomposition-wave rules (apply to every extraction in this ticket):**

- Move code **verbatim** — extract, do not rewrite. Do not reformat beyond what
  `mix format` does, do not rename variables, do not "improve", do not collapse
  clauses, do not re-scope a `with` or a `case`. Move each function's leading
  doc-comment with it.
- Public function **signatures and observable behavior are unchanged** — names,
  arities, return-tuple shapes, and every operator-facing string (`IO.puts`
  output, faint-ANSI formatting, heredocs) stay byte-identical.
- A `defp` that moves out becomes a `def` (`@doc false`) in its new module (it is
  reached across a module boundary — via the injected `deps` map, the flow, or a
  sibling module).
- The parent `Aiur.Init` and its already-extracted siblings keep working: update
  every caller of a moved function to the new module (see the repoint list in
  each step). `Aiur.Init` keeps a `defdelegate migrate_layout/1` so
  `init_test.exs`'s 11 direct `Init.migrate_layout` calls pass unedited.
- Wherever a moved body **already** calls `Aiur.Init.Format.*`,
  `Aiur.Init.Templates.*`, or `Aiur.Init.Runtime.*` (T-031 repointed these when
  it extracted those modules), **keep the call exactly as the post-T-031 tree
  leaves it** — do not re-derive it.
- Every new module gets a `@moduledoc` (2–4 sentences derived from its name-map
  responsibility sentence) and an `@spec` on every public `def` (`mix specs.check`
  enforces this via `mix credo`/lint).
- Every new module gets its own test file (step 5). New modules are **NOT**
  coverage-exempt — do not add them to `ignore_modules` in `src/mix.exs`; the 85%
  threshold enforces that tests exist.
- Dependency direction is strictly downward:
  `Aiur.Init` (flow + facade) → feature modules (`Prewarm`, `Alerts`) → mechanism
  modules (`Scaffold`, `Migration`, `Templates`, `Format`). `Prewarm.Failure` is a
  child mechanism of `Prewarm`. **No new module may call back up into
  `Aiur.Init`** (see the `tracker_repo/1` note in step 3).
- After every step: `mix compile --warnings-as-errors` and the full `mix test`
  pass. Commit each step separately with a 3–7 word imperative message.

Execute as five serialized steps in this order (research doc §3, waves 2 and 5).

### Step 1: `Aiur.Init.Scaffold` (filesystem layer)

1. Create `src/lib/aiur/init/scaffold.ex` — module `Aiur.Init.Scaffold`. Declare
   at the top, copied verbatim from `init.ex`, the module attributes this module
   references: `@config_file_name ".aiur/config"`,
   `@legacy_config_file_name ".aiurconfig"`, `@alerts_file_name "alerts"`,
   `@aiurhooks_file_name "hooks"`, `@prewarm_file_name "prewarm"`,
   `@env_file_name ".env"`, `@env_example_file_name ".env.example"`,
   `@gitignore_entry ".aiur/"`. Alias `Aiur.Init.{Format, Templates}`. Move
   verbatim (as `def`, `@doc false`) these functions (research doc §2 Scaffold
   row): `config_target/1`, `legacy_config_target/1`, `global_alerts_path/0`,
   `existing_config_path/1`, `existing_alerts_path/1`, `write_config/2`,
   `append_config_section/2`, `write_prompt_file/3`, `write_aiurhooks/1`,
   `write_prewarm_file/2`, `add_gitignore_entry/1`, `add_gitignore_entry/2`,
   `ensure_env/1`, `same_path?/2`, and the four io-wrapper functions
   `ensure_prompt_file/5`, `ensure_aiurhooks/3`, `maybe_offer_gitignore/3`,
   `setup_env/3`. `write_prompt_file/3` calls `Templates.prompt_file_scaffold/1`
   (post-T-031); `write_aiurhooks/1` uses `Templates.aiurhooks_template/0`;
   `setup_env/3` passes `Templates.env_example_content()` to `deps.ensure_env`;
   the io-wrappers use `Format.dim/1`. Keep all these post-T-031 calls exactly.
2. In `init.ex`: delete the moved bodies. In `Aiur.Init.fresh_setup/4`, repoint
   the call sites `ensure_prompt_file(...)` → `Scaffold.ensure_prompt_file(...)`,
   `ensure_aiurhooks(...)` → `Scaffold.ensure_aiurhooks(...)`,
   `setup_env(...)` → `Scaffold.setup_env(...)`, and
   `maybe_offer_gitignore(...)` → `Scaffold.maybe_offer_gitignore(...)` (add
   `alias Aiur.Init.Scaffold` to `init.ex`).
3. Repoint the `deps` map (`runtime_deps/0`, which T-031 placed in
   `Aiur.Init.Runtime`, `src/lib/aiur/init/runtime.ex` — if T-031 left it
   elsewhere, edit it wherever `runtime_deps/0` now lives) so these entries point
   at `Scaffold`: `config_target: &Aiur.Init.Scaffold.config_target/1`,
   `legacy_config_target: &Aiur.Init.Scaffold.legacy_config_target/1`,
   `existing_config_path: &Aiur.Init.Scaffold.existing_config_path/1`,
   `global_alerts_path: &Aiur.Init.Scaffold.global_alerts_path/0`,
   `existing_alerts_path: &Aiur.Init.Scaffold.existing_alerts_path/1`,
   `write_config: &Aiur.Init.Scaffold.write_config/2`,
   `append_config: &Aiur.Init.Scaffold.append_config_section/2`,
   `ensure_prompt_file: &Aiur.Init.Scaffold.write_prompt_file/3`,
   `ensure_aiurhooks: &Aiur.Init.Scaffold.write_aiurhooks/1`,
   `ensure_prewarm_file: &Aiur.Init.Scaffold.write_prewarm_file/2`,
   `add_gitignore_entry: &Aiur.Init.Scaffold.add_gitignore_entry/1`,
   `ensure_env: &Aiur.Init.Scaffold.ensure_env/1`.

**Preserve verbatim (research doc §4 risk 2, FI-WS-021/022):** every writer
guards with `File.regular?` **before** writing — `write_prompt_file`,
`write_aiurhooks`, `write_prewarm_file`, and `ensure_env` (which **always**
rewrites `.env.example` but never an existing `.env`); `append_config_section`
appends after a blank line and never regenerates; `add_gitignore_entry/2` is
idempotent (trimmed-line check, `:exists` when unchanged, preserves a missing
trailing newline). Do not alter any guard, order, or return-tuple.

### Step 2: `Aiur.Init.Migration` (legacy → `.aiur/` migration)

1. Create `src/lib/aiur/init/migration.ex` — module `Aiur.Init.Migration`.
   Declare verbatim the attributes it references: `@aiurhooks_file_name "hooks"`,
   `@prompt_basename "prompt.md"`, `@examples_dir "examples"`,
   `@gitignore_entry ".aiur/"`, and `@legacy_examples` (the 3-tuple list). Alias
   `Aiur.Init.Scaffold`. Move verbatim (research doc §2 Migration row):
   `migrate_layout/1` (the public `def`, keep its `@doc` and `@spec`),
   `pointer_src/2`, `inside?/2`, `rewrite_pointers/2`, `replace_pointer_value/3`,
   `parse_yaml/1`, `git_work_tree?/1`, `remove_path/3`, `git/2`. Inside
   `migrate_layout/1`, the `add_gitignore_entry(base_dir, @gitignore_entry)` call
   becomes `Scaffold.add_gitignore_entry(base_dir, @gitignore_entry)`.
2. In `init.ex`: delete the moved bodies and replace the public
   `migrate_layout/1` with `defdelegate migrate_layout(opts), to:
   Aiur.Init.Migration` (keep a `@doc` + `@spec` on the delegate so
   `init_test.exs`'s direct `Init.migrate_layout/1` calls and `mix specs.check`
   stay satisfied).
3. Repoint the `deps` map entry `migrate_layout: &Aiur.Init.Migration.migrate_layout/1`
   (wherever `runtime_deps/0` lives, per step 1).

**Preserve verbatim (research doc §4 risk 3, FI-WS-019):** the move order is
sacred — (1) copy pointer + example files into `.aiur/`, (2) write the rewritten
config so the new layout is complete and loadable, (3) only then remove the
legacy originals (git-aware via `git rm`, else `File.rm`), (4) `git add` the new
files or, with `ignore: true`, append `.aiur/` to `.gitignore`. Keep the
`inside?/2` guard (pointer targets outside the repo are never copied or deleted),
the "only rewrite a pointer key whose file actually moved" logic, and the
whole-token pointer rewrite regex (quoted values with spaces replaced whole). A
partial failure must never leave a state aiur can't load. Pinned by the 11
`migrate_layout/1` tests in `init_test.exs`.

### Step 3: `Aiur.Init.Prewarm` + `Aiur.Init.Prewarm.Failure` (warm-base opt-in)

1. Create `src/lib/aiur/init/prewarm/failure.ex` — module
   `Aiur.Init.Prewarm.Failure`. Alias `Aiur.Init.Format`. Move verbatim
   (research doc §2 Prewarm.Failure row): `report_prewarm_failure/4` — **rename
   the public entry to `report/4`** (this is the only rename in this ticket; keep
   the same arg order and body) — plus the private helpers `classify_prewarm_failure/1`,
   `auth_error?/1`, `prewarm_failure_guidance/2` (all 4 clauses),
   `prewarm_failure_prompt/3` (the AI-handoff heredoc), and `failure_output/1`.
   The `dim/…` calls become `Format.dim/…`.
2. Create `src/lib/aiur/init/prewarm.ex` — module `Aiur.Init.Prewarm`. Declare
   verbatim `@prewarm_file_name "prewarm"`. Alias
   `Aiur.Init.{Format, Prewarm.Failure}`. Move verbatim (research doc §2 Prewarm
   row): `prompt_prewarm/3` (both clauses), `resolve_prewarm/2`,
   `print_prewarm_fallback/1`, `print_prewarm_ambiguous/2`,
   `prewarm_fallback_prompt/0` (the heredoc), `maybe_first_prewarm/4` (both
   clauses), `maybe_resume_prewarm/4`, `prewarm_from_config/1`,
   `prewarm_section_yaml/1`, `first_prewarm_backfill/5`, `ensure_prewarm_file/4`.
   Inside `maybe_first_prewarm/4`, the `report_prewarm_failure(io, repo, cmd,
   reason)` call becomes `Failure.report(io, repo, cmd, reason)`. Because
   `maybe_first_prewarm/4` uses `tracker_repo/1` (which the name map keeps in
   `Aiur.Init`) and `Prewarm` must not call back up into `Aiur.Init`, **add a
   private `tracker_repo/1` to `Prewarm`, copied verbatim** from `init.ex` (the
   two-clause `%{repo: repo}` / fallback function). `ensure_prewarm_file/4` calls
   `deps.ensure_prewarm_file` (already wired to `Scaffold.write_prewarm_file/2` in
   step 1). The `dim/…` calls become `Format.dim/…`.
3. In `init.ex`: delete the moved bodies. In `Aiur.Init.fresh_setup/4`, repoint
   `prompt_prewarm(io, deps, location)` → `Prewarm.prompt_prewarm(...)`,
   `ensure_prewarm_file(...)` → `Prewarm.ensure_prewarm_file(...)`, and
   `maybe_first_prewarm(...)` → `Prewarm.maybe_first_prewarm(...)` (add `alias
   Aiur.Init.Prewarm`).
4. In `Aiur.Init.Resume` (`src/lib/aiur/init/resume.ex`, from T-031): repoint the
   prewarm references — the `resume/3` call `maybe_resume_prewarm(io, deps,
   tracker, config)` → `Aiur.Init.Prewarm.maybe_resume_prewarm(...)`, and the
   `promptable_sections/0` registry entry's function captures
   `prompt: &Aiur.Init.Prewarm.prompt_prewarm/3`,
   `to_yaml: &Aiur.Init.Prewarm.prewarm_section_yaml/1`,
   `first_run: &Aiur.Init.Prewarm.first_prewarm_backfill/5`. (If T-031 left the
   `promptable_sections/0` registry or the `maybe_resume_prewarm` call in
   `init.ex` rather than `resume.ex`, repoint them wherever they actually live.)

**Preserve verbatim (research doc §4 risks 6 & 8, FI-PW-008..013, FI-WS-024/025):**
the two AI-handoff heredocs (`prewarm_fallback_prompt/0`,
`prewarm_failure_prompt/3`) must be byte-identical after the move. The failure
classifier's ordered clauses (`:auth`/`:clone` from git-stderr signatures,
`:build`, `:other`) and each guidance block stay exact. `maybe_first_prewarm/4`
only builds when the tracker carries a non-empty repo and only on the
`%{enabled: true, base_build: cmd}` clause. `first_prewarm_backfill/5` runs the
one-time side effect (write sibling script + first build) **only after** a
successful append (the #411 convention: declining leaves the config untouched).

### Step 4: `Aiur.Init.Alerts` (alert-sound opt-in)

1. Create `src/lib/aiur/init/alerts.ex` — module `Aiur.Init.Alerts`. Declare
   verbatim `@alerts_file_name "alerts"`. Alias
   `Aiur.Init.{Format, Templates, Scaffold}`. Move verbatim (research doc §2
   Alerts row): `prompt_alerts/3`, `prompt_reuse_global_alerts/3`,
   `ensure_alerts/4`, `write_alerts_file/2`, `write_new_alerts_file/2` (both
   clauses). `write_new_alerts_file/2` calls `Scaffold.same_path?/2` and
   `Templates.alerts_template(:os.type())`; `prompt_alerts/3` and
   `ensure_alerts/4` use `Format.dim/1`;
   `prompt_reuse_global_alerts/3` reads `deps.global_alerts_path` /
   `deps.existing_alerts_path` (wired to `Scaffold` in step 1) — keep these calls
   exactly.
2. In `init.ex`: delete the moved bodies. In `Aiur.Init.fresh_setup/4`, repoint
   `prompt_alerts(io, deps, target)` → `Alerts.prompt_alerts(...)` and
   `ensure_alerts(io, deps, path, alerts)` → `Alerts.ensure_alerts(...)` (add
   `alias Aiur.Init.Alerts`).
3. Repoint the `deps` map entry `ensure_alerts: &Aiur.Init.Alerts.write_alerts_file/2`
   (wherever `runtime_deps/0` lives, per step 1).

**Preserve verbatim (research doc §4 risk 2, FI-WS-021):** `write_alerts_file/2`
guards with `File.regular?` (never clobbers a tuned `.aiur/alerts`), and
`write_new_alerts_file/2` keeps the `same_path?/2` self-copy guard before
`File.cp!` and the OS-family template pick (`:darwin` → macOS, else Linux) via
`Templates.alerts_template/1`.

### Step 5: tests for the five new modules

Create one `async: true` test file per new module. These modules are pure
map/string transforms and never touch global process state (dotenv/`:req` live
only on `Aiur.Init.run/1`, unchanged here), so `async: true` is correct. Drive
each module's public functions directly; for the flow/writer functions build a
scripted `io` map (label-keyed `puts`/`confirm`/`select`/`input`) and a `deps`
map of fakes, exactly as `init_test.exs` already does — reuse those stub shapes.
Required coverage per file (add more if trivial, never fewer):

- `src/test/aiur/init/scaffold_test.exs` (`Aiur.Init.ScaffoldTest`): in a
  `tmp_dir`, `write_prompt_file/3`, `write_aiurhooks/1`, `write_prewarm_file/2`
  and `ensure_env/1` each return `{:created, _}` first, then `{:exists, _}` on a
  second call without overwriting the file (never-clobber, FI-WS-021);
  `append_config_section/2` appends after a blank line and leaves prior content
  intact; `add_gitignore_entry/2` returns `{:added, _}` then `{:exists, _}` and
  preserves a missing trailing newline (FI-WS-022).
- `src/test/aiur/init/migration_test.exs` (`Aiur.Init.MigrationTest`): in a
  git-init'd `tmp_dir`, a legacy `.aiurconfig` with `hooks_file:`/`prompt_file:`
  pointers migrates to `.aiur/config` with pointers rewritten to `hooks`/
  `prompt.md`, example files copied under `.aiur/examples/`, and the legacy
  originals removed; a pointer resolving outside the repo is left in place
  (`inside?/2` guard); `ignore: true` appends `.aiur/` to `.gitignore`
  (FI-WS-019).
- `src/test/aiur/init/prewarm_test.exs` (`Aiur.Init.PrewarmTest`): `prompt_prewarm/3`
  returns `%{enabled: false}` for `:global`; a `{:ok, detection}` toolchain +
  "use" select yields `%{enabled: true, base_build: cmd}`; `:none` and
  `{:ambiguous, _}` disclose and leave prewarm disabled and emit the fallback
  prompt (FI-PW-008/009); `maybe_first_prewarm/4` on a successful fake
  `prewarm_build` prints "✅ Warm base ready." and on failure delegates to
  `Failure.report/4`; `prewarm_section_yaml/1` renders `base_build_file:
  prewarm` (FI-PW-010/011/013).
- `src/test/aiur/init/prewarm/failure_test.exs` (`Aiur.Init.Prewarm.FailureTest`):
  `report/4` classifies an auth-signature git failure as `:auth`,
  `:base_build_failed` as `:build`, others as `:other`, printing the
  class-specific guidance plus the AI-handoff prompt embedding the captured
  output, and the "retries automatically on the next `aiur` run" line
  (FI-PW-012).
- `src/test/aiur/init/alerts_test.exs` (`Aiur.Init.AlertsTest`): declining the
  master switch returns `%{enabled: false, ...}`; accepting returns
  `%{enabled: true, use_os_default_sounds: _, source_path: _}`;
  `write_alerts_file/2` writes the host-OS template first (`{:created, _}`) and
  never clobbers an existing `.aiur/alerts` (`{:exists, _}`) (FI-WS-021).

Do **not** add any of the five new modules (`Aiur.Init.Scaffold`,
`Aiur.Init.Migration`, `Aiur.Init.Prewarm`, `Aiur.Init.Prewarm.Failure`,
`Aiur.Init.Alerts`) to `ignore_modules` in `src/mix.exs`.

**Final:** run `mix format`, then the full Agent gate. Delete any `alias` in
`init.ex` your moves orphaned (e.g. if `Aiur.Prewarm.Detect` is now referenced
only by the `@type deps` typespec, keep it; if a moved body was its only user,
drop it). Do not touch unrelated aliases.

## Files

- Create:
  - `src/lib/aiur/init/scaffold.ex`
  - `src/lib/aiur/init/migration.ex`
  - `src/lib/aiur/init/prewarm.ex`
  - `src/lib/aiur/init/prewarm/failure.ex`
  - `src/lib/aiur/init/alerts.ex`
  - `src/test/aiur/init/scaffold_test.exs`
  - `src/test/aiur/init/migration_test.exs`
  - `src/test/aiur/init/prewarm_test.exs`
  - `src/test/aiur/init/prewarm/failure_test.exs`
  - `src/test/aiur/init/alerts_test.exs`
- Modify:
  - `src/lib/aiur/init.ex` (delete moved bodies; repoint `fresh_setup/4` call
    sites; add `defdelegate migrate_layout/1`; add `alias`es for the new modules;
    drop orphaned aliases)
  - `src/lib/aiur/init/runtime.ex` (repoint the `runtime_deps/0` map entries — if
    T-031 placed `runtime_deps/0` elsewhere, edit it there instead)
  - `src/lib/aiur/init/resume.ex` (repoint the `Prewarm` references in
    `resume/3` and `promptable_sections/0` — if T-031 left them in `init.ex`,
    repoint them there instead)
- Test: the 5 new test files above; existing pins run unchanged (see
  Characterization-tests).

## Out of scope

- The T-031 modules `Aiur.Init.Runtime`, `Aiur.Init.Format`,
  `Aiur.Init.Questions`, `Aiur.Init.Templates` — call them, do not edit them
  (except the `runtime_deps/0` map repointing explicitly required above). Do not
  move any function `giant-init.md` §2 assigns to them into a T-032 module.
- The T-033 concerns still resident in `init.ex`: CODEOWNERS setup
  (`setup_codeowners` and helpers), GitHub label staging (`setup_labels` and
  helpers), the GitHub API adapters (`create_labels`, `list_repo_labels`,
  `fetch_label_names`, `detect_repo`, `detect_github_login`, …), agent-CLI checks
  (`check_agent_clis`, `install_claude_app_server`, …), and dotenv
  (`load_dotenv`, `parse_dotenv`) — leave them byte-identical; do not move them.
- `Aiur.Codeowners` / `Aiur.Codeowners.Edit` — not part of this wave (T-033).
- The `@external_resource` / `__DIR__`-relative template-embedding attributes —
  they live in `Aiur.Init.Templates` after T-031; do **not** add, move, or edit
  any `@external_resource` or `Path.expand(..., __DIR__)` this wave (that would
  trip the T-006 guard). Templates stay compile-time embedded — never "simplify"
  a writer to a runtime file read (research doc §4 risk 1).
- The wizard flow itself (`run/1`, `run/3`, `fresh_setup/4`, `provision/4`,
  `existing_config_target/2`, `config_probe_targets/1`, `tracker_repo/1`, the
  closing screens, `@type io`/`@type deps`) — stays in `Aiur.Init`; only its
  call sites to moved functions change.
- Any existing test under `src/test/aiur/` — must pass unmodified; do not edit or
  reformat. Everything under `src/test/aiur/regression/` and `src/test/fixtures/`
  is read-only.

## Inventory-IDs

Files in this ticket implement/touch, from
`docs/refactor/feature-inventory/ws.md` and `.../pw.md`:

- FI-WS-019 — Legacy `.aiurconfig` → `.aiur/` layout migration → `Aiur.Init.Migration`
- FI-WS-021 — Init sibling-file scaffolding (prompt.md, hooks, alerts, prewarm,
  .env), never-clobber → `Aiur.Init.Scaffold` (+ `Alerts`, `Prewarm` writers)
- FI-WS-022 — Gitignore opt-in for `.aiur/` → `Aiur.Init.Scaffold`
  (`add_gitignore_entry`, `maybe_offer_gitignore`) + `Aiur.Init.Migration` (ignore path)
- FI-WS-024 — Pre-warm opt-in (toolchain detect, first build, failure triage) →
  `Aiur.Init.Prewarm` + `Aiur.Init.Prewarm.Failure`
- FI-WS-020 — Fresh-setup scaffold wizard (partial: the prewarm + alerts opt-in
  prompts and the config/scaffold writers) → `Prewarm`, `Alerts`, `Scaffold`
  (the flow orchestration itself stays in `Aiur.Init`)
- FI-WS-025 — Resume backfill of promptable sections #411 (partial: the prewarm
  section YAML + first-build side effect) → `Aiur.Init.Prewarm`
  (`prewarm_section_yaml`, `first_prewarm_backfill`, `maybe_resume_prewarm`); the
  registry (`promptable_sections`, `offer_section`) stays in `Aiur.Init.Resume`
  (T-031)
- FI-PW-008 — init pre-warm opt-in prompt → `Aiur.Init.Prewarm`
- FI-PW-009 — init detection-miss / ambiguity disclosure + agent fallback prompt
  → `Aiur.Init.Prewarm`
- FI-PW-010 — init writes `.aiur/prewarm` sibling script + config block →
  `Aiur.Init.Prewarm` (`prewarm_section_yaml`, `ensure_prewarm_file`) +
  `Aiur.Init.Scaffold` (`write_prewarm_file`)
- FI-PW-011 — init one-time first warm-base build → `Aiur.Init.Prewarm`
  (`maybe_first_prewarm`)
- FI-PW-012 — init warm-base failure classification + guidance →
  `Aiur.Init.Prewarm.Failure`
- FI-PW-013 — init resume re-verify + backfill prewarm section →
  `Aiur.Init.Prewarm` (`maybe_resume_prewarm`, `first_prewarm_backfill`,
  `prewarm_from_config`)

Alert-sound opt-in itself has no dedicated FI beyond FI-WS-020 (flow) and
FI-WS-021 (the `.aiur/alerts` scaffold write), both listed above.

Consumed but owned elsewhere (not re-implemented here): `RepoBase.refresh/3`
(FI-PW-014..019), invoked through `deps.prewarm_build` (wired to
`Aiur.Init.Runtime.run_first_prewarm/2` by T-031); `Aiur.Prewarm.Detect`
(FI-PW-003..007), invoked through `deps.detect_toolchain`. This wave calls them
unchanged, through the injected `deps` map.

## Characterization-tests

The Phase-1 regression file that guards this area is
`src/test/aiur/regression/compile_time_paths_test.exs` (T-006) — it freezes the
compile-time template-embedding mechanism that `Scaffold`'s writers
(`write_aiurhooks/1`, `write_prompt_file/3`) and `Alerts`
(`write_new_alerts_file/2` → `Templates.alerts_template/1`) depend on. It must
pass **unmodified**. This wave moves **no** `@external_resource`/`__DIR__` site
(T-031 already relocated them to `Aiur.Init.Templates` and reconciled the
allowlist), so this guard needs no change; if it fires, your change is wrong.

The pre-existing prewarm regression suites
(`src/test/aiur/regression/parallel_pre_warm_test.exs`,
`prewarm_complete_time_test.exs`, `shared_prewarm_e2e_test.exs`,
`warm_marker_semantics_test.exs`, `warm_state_transitions_test.exs`) guard the
`RepoBase` warm-base runtime that init only calls through `deps.prewarm_build`;
they must stay green **unmodified**.

The primary byte-level pin for everything this wave moves is
`src/test/aiur/init_test.exs` (~1,793 lines, `async: true`) — not under
`regression/`, but it must stay green after every step and must **not** be edited
or reformatted. It drives `run/3` with injected `io`/`deps` plus direct
`migrate_layout/1`, `alerts_template/0,1`, `prompt_file_scaffold/1`, and covers
prewarm opt-in + failure report, alerts opt-in, legacy migration, #411 backfill,
and never-clobber for hooks. If it fails, fix the code, never the test.

## Acceptance criteria

Mechanically checkable (run from repo root unless noted):

- All five new lib modules exist at their exact paths with matching names:
  `grep -c "defmodule Aiur.Init.Scaffold do" src/lib/aiur/init/scaffold.ex` → 1;
  `grep -c "defmodule Aiur.Init.Migration do" src/lib/aiur/init/migration.ex` → 1;
  `grep -c "defmodule Aiur.Init.Prewarm do" src/lib/aiur/init/prewarm.ex` → 1;
  `grep -c "defmodule Aiur.Init.Prewarm.Failure do" src/lib/aiur/init/prewarm/failure.ex` → 1;
  `grep -c "defmodule Aiur.Init.Alerts do" src/lib/aiur/init/alerts.ex` → 1.
- Parent slimmed: `wc -l src/lib/aiur/init.ex` → **< 1000**.
- The moved concerns no longer have live implementations in `init.ex` — each of
  these prints `0`:
  `grep -c "defp config_target\|defp write_config\|defp write_prompt_file\|defp write_aiurhooks\|defp write_prewarm_file\|defp ensure_env(\|defp add_gitignore_entry\|defp append_config_section\|defp global_alerts_path\|defp existing_alerts_path\|defp existing_config_path\|defp same_path?" src/lib/aiur/init.ex`;
  `grep -c "defp ensure_prompt_file\|defp ensure_aiurhooks\|defp maybe_offer_gitignore\|defp setup_env\|defp ensure_alerts\|defp ensure_prewarm_file" src/lib/aiur/init.ex`;
  `grep -c "def migrate_layout(\|defp pointer_src\|defp rewrite_pointers\|defp replace_pointer_value\|defp remove_path\|defp git_work_tree?\|defp parse_yaml\|defp inside?" src/lib/aiur/init.ex`;
  `grep -c "defp prompt_prewarm\|defp resolve_prewarm\|defp prewarm_fallback_prompt\|defp maybe_first_prewarm\|defp maybe_resume_prewarm\|defp prewarm_section_yaml\|defp first_prewarm_backfill\|defp prewarm_from_config\|defp print_prewarm_fallback\|defp print_prewarm_ambiguous" src/lib/aiur/init.ex`;
  `grep -c "defp report_prewarm_failure\|defp classify_prewarm_failure\|defp prewarm_failure_guidance\|defp prewarm_failure_prompt\|defp auth_error?\|defp failure_output" src/lib/aiur/init.ex`;
  `grep -c "defp prompt_alerts\|defp prompt_reuse_global_alerts\|defp write_alerts_file\|defp write_new_alerts_file" src/lib/aiur/init.ex`.
- The `migrate_layout/1` facade survives as a delegate:
  `grep -c "defdelegate migrate_layout" src/lib/aiur/init.ex` → 1;
  `cd src && mix run -e 'Code.ensure_loaded(Aiur.Init); IO.puts(function_exported?(Aiur.Init, :migrate_layout, 1))'`
  → `true`.
- The two heredocs moved out are present in the new modules and absent from
  `init.ex`: `grep -c "called the warm base" src/lib/aiur/init/prewarm.ex` → 1 and
  `grep -c "called the warm base" src/lib/aiur/init.ex` → 0;
  `grep -rc "Building the warm base just FAILED" src/lib/aiur/init/prewarm/failure.ex` → 1 and
  `grep -c "Building the warm base just FAILED" src/lib/aiur/init.ex` → 0.
- Failure entry renamed: `grep -c "def report(" src/lib/aiur/init/prewarm/failure.ex` → 1;
  `grep -c "Failure.report(" src/lib/aiur/init/prewarm.ex` → 1.
- Every new lib file has a moduledoc and specs: `grep -c "@moduledoc" <file>` → 1
  for each of the five; `grep -c "@spec" <file>` ≥ 1 (reviewer spot-checks one
  `@spec` per public `def`).
- New modules are NOT coverage-exempt:
  `grep -c "Aiur.Init.Scaffold\|Aiur.Init.Migration\|Aiur.Init.Prewarm\|Aiur.Init.Alerts" src/mix.exs`
  → 0 (none added to `ignore_modules`).
- Five new test files exist under `src/test/aiur/init/` and, from `src/`,
  `mix test test/aiur/init/scaffold_test.exs test/aiur/init/migration_test.exs test/aiur/init/prewarm_test.exs test/aiur/init/prewarm/failure_test.exs test/aiur/init/alerts_test.exs`
  passes, 0 failures; each file `grep -c "async: true" <file>` → 1.
- `init_test.exs` is untouched: `git diff --name-only origin/v2...HEAD` lists
  none of `src/test/aiur/init_test.exs`, nothing under
  `src/test/aiur/regression/`, and nothing under `src/test/fixtures/`.
- File-size norms (per `giant-init.md` §2, "every file ≤ ~220, most ≤ 190"; the
  two heredoc-bearing files sit near the top of that band): `wc -l` prints
  ≤ **200** for `scaffold.ex`, ≤ **190** for `migration.ex`, ≤ **210** for
  `prewarm.ex` (holds the 47-line fallback heredoc), ≤ **160** for
  `prewarm/failure.ex`, ≤ **120** for `alerts.ex`. Moved functions keep their
  exact current bodies — do not rewrite a moved function to satisfy a norm; any
  function you author keeps its body ≤ 20 logic lines.

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
### At-merge (reviewer)

- Run every grep in Acceptance criteria verbatim; all must match.
- Confirm the diff shows moved bodies **verbatim**:
  `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/init.ex src/lib/aiur/init/`
  renders the extractions as moved blocks, not rewrites.
- Check FI-WS-019 (migration move-order): `init_test.exs`'s 11
  `migrate_layout/1` tests pass, and reading `Aiur.Init.Migration.migrate_layout/1`
  the order is still copy → write rewritten config → remove legacy → git-add /
  gitignore, with the `inside?/2` out-of-repo guard intact.
- Check FI-WS-021 (never-clobber, #649/#724): the hooks/alerts/prewarm/`.env`
  never-clobber assertions in `init_test.exs` pass; every writer in
  `scaffold.ex` / `alerts.ex` still guards with `File.regular?` before writing,
  and `ensure_env` still always rewrites `.env.example` but never an existing
  `.env`.
- Check FI-PW-012 (failure triage): `init_test.exs` "warm-base failure report"
  tests pass; `Aiur.Init.Prewarm.Failure` classifies `:auth`/`:clone`/`:build`/
  `:other` in that clause order and the AI-handoff heredoc is byte-identical.
- Check FI-WS-025 / FI-PW-013 (#411 backfill): the resume-backfill tests in
  `init_test.exs` pass — declining leaves the config untouched; opt-in appends
  the `prewarm:` block (never regenerates) then writes the sibling script and
  runs the first build, in that order.
- Confirm the injected-deps seam is intact:
  `cd src && mix run -e 'IO.inspect(Aiur.Init.Runtime.runtime_deps() |> Map.take([:write_config, :migrate_layout, :ensure_alerts, :ensure_prewarm_file, :add_gitignore_entry]))'`
  runs without error and the captured functions resolve into the new modules
  (spot-check they are `&Aiur.Init.Scaffold.*` / `&Aiur.Init.Migration.*` /
  `&Aiur.Init.Alerts.*`).
- Confirm no T-033 concern moved early: `git diff --name-only origin/v2...HEAD`
  contains no change that deletes `setup_codeowners`, `setup_labels`,
  `create_labels`, `load_dotenv`, or `parse_dotenv` bodies from `init.ex`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
