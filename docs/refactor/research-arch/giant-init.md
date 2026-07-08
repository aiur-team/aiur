# Decomposition proposal: `src/lib/aiur/init.ex` (2253 lines)

Scope: the `aiur init` scaffold wizard — `.aiur` layout, config generation, hooks/alerts/prewarm scaffolds,
CODEOWNERS setup, never-clobber rules, legacy-layout migration, resume backfill (#411), GitHub label
provisioning. Behavior-preserving refactor; module NAME MAP below is the downstream contract.

External surface today (must stay stable):

- `Aiur.Init.run/1` — the only lib caller (`src/lib/aiur/cli.ex:49`).
- `Aiur.Init.run/3`, `migrate_layout/1`, `parse_dotenv/1`, `aiurhooks_template/0`, `alerts_template/0,1`,
  `prompt_file_template/0`, `prompt_file_scaffold/1`, `known_agent_kinds/0` — exercised by
  `src/test/aiur/init_test.exs` (1793 lines, `async: true`; 76 `Init.run` call sites, 11 `Init.migrate_layout`,
  6 `Init.alerts_template`). All other functions are private and reached only through the injected `io`/`deps`
  maps, so private relocation is invisible to tests as long as `Aiur.Init` keeps the facade (via `defdelegate`).

Namespace convention: `Aiur.Init.*` under `src/lib/aiur/init/` (proven by existing `Aiur.Init.Prompt` at
`src/lib/aiur/init/prompt.ex`). One cross-namespace move is proposed (`Aiur.Codeowners.Edit`) to colocate
CODEOWNERS-format knowledge with its existing parser (`src/lib/aiur/codeowners.ex`) — one source of truth
per fact.

---

## 1. Function / responsibility census

Line ranges from the current file; sizes approximate.

| # | Concern | Lines | ~LOC | Functions |
|---|---------|-------|-----:|-----------|
| A | Module head: constants, compile-time embedded templates, `io`/`deps` typespecs | 1–135 | 135 | `@example_template`, `@aiurhooks_example_template`, `@alerts_{macos,linux}_example_template`, `@prompt_example_template`, `@env_example_content`, `@config_file_name` etc.; `@type io`, `@type deps` |
| B | Entry + top-level flow | 137–358 | 190 | `run/1`, `ensure_http_client/0`, `run/3`, `init_warning/0`, `existing_config_target/2`, `config_probe_targets/1`, `resume/3`, `maybe_migrate_layout/5`, `layout_label/1`, `workspace_default/1`, `fresh_setup/4`, `provision/4` (3 clauses), `github_token_present?/1` |
| C | Resume: saved summary + config readback | 360–442 | 80 | `print_saved_summary/2`, `saved_summary_lines/1`, `alerts_summary_line/1`, `format_routing/1`, `tracker_from_config/2`, `agents_from_config/1`, `routing_backend/1` |
| D | Resume backfill registry (#411) | 444–542 | 100 | `promptable_sections/0`, `backfill_missing_sections/6`, `missing_section?/2`, `offer_section/6`, `append_section/5`, `prewarm_section_yaml/1`, `first_prewarm_backfill/5`, `maybe_resume_prewarm/4`, `prewarm_from_config/1` |
| E | Core wizard prompts | 544–705 | 160 | `prompt_location/1`, `prompt_tracker/3`, `prompt_agents/1`, `prompt_routing/2`, `prompt_routing_level/4`, `prompt_routing_model/3`, `prompt_routing_effort/3`, `routing_value/3`, `prompt_permission_mode/1`, `prompt_int/5`, `prompt_max_turns/1`, `prompt_max_duration/1`, `normalize_int_or_none/1` |
| F | Prewarm opt-in + first build | 707–844 | 138 | `prompt_prewarm/3` (2 clauses), `resolve_prewarm/2`, `print_prewarm_fallback/1`, `print_prewarm_ambiguous/2`, `prewarm_fallback_prompt/0` (47-line heredoc), `maybe_first_prewarm/4` |
| G | Prewarm failure report | 846–974 | 128 | `report_prewarm_failure/4`, `classify_prewarm_failure/1`, `auth_error?/1`, `prewarm_failure_guidance/2` (4 clauses), `prewarm_failure_prompt/3` (heredoc), `failure_output/1` |
| H | Alerts opt-in | 976–1017 | 42 | `prompt_alerts/3`, `prompt_reuse_global_alerts/3` |
| I | Template fill / config rendering | 1019–1078 | 60 | `build_fills/1`, `prewarm_base_build_file_line/1`, `fill_template/2`, `tracker_provider_block/1` (3 clauses), `routing_inline/1` |
| J | Closing scaffold ensure-wrappers | 1080–1143 | 64 | `ensure_prompt_file/5`, `ensure_aiurhooks/3`, `ensure_alerts/4`, `ensure_prewarm_file/4`, `maybe_offer_gitignore/3`, `tracker_repo/1` |
| K | CODEOWNERS setup (flow + content edit) | 1145–1368 | 224 | Flow: `setup_codeowners/3`, `maybe_create_codeowners/3`, `explain_codeowners_trust/1`, `create_codeowners_file/1`, `maybe_add_operator_codeowner/4`, `prompt_and_add_operator_codeowner/4`, `prompt_github_login/2`, `codeowners_has_login?/2`, `offer_operator_codeowner/3`. Pure edit: `add_codeowners_login/2`, `write_codeowners_login/3`, `codeowners_content_has_login?/2`, `codeowner_tokens/1`, `content_with_codeowner/2`, `wildcard_rule_index/1`, `wildcard_rule?/1`, `codeowner_rule_tokens/1`, `append_login_to_rule/2`, `append_codeowner_rule/2`, `normalize_login/1` |
| L | `.env` setup | 1370–1381 | 12 | `setup_env/3` (2 clauses) |
| M | Staged label creation UX | 1383–1534 | 152 | `setup_labels/4`, `fetch_existing_labels/2`, `create_lifecycle_labels/4`, `maybe_create_complexity_labels/4`, `maybe_create_model_labels/5`, `maybe_create_remote_label/5`, `create_or_skip/7`, `label_status_line/1`, `create_labels_request/5`, `print_label_list/2`, `print_hint/2`, `emit_gh_label_fallback/4`, `shell_arg/1` |
| N | Closing text screens | 1536–1569 | 34 | `token_setup_instructions/1`, `final_screen/1`, `linear_walkthrough/2` |
| O | Agent CLI checks + install | 1571–1647 | 77 | `check_agent_clis/3`, `ensure_agent_cli/3` (2 clauses), `install_claude_then_check/2`, `run_auth_check/3`, `agent_kind_choices/0`, `primary_kind/1`, `agent_kinds/1` |
| P | Runtime `io`/`deps` composition | 1649–1715 | 67 | `runtime_io/0`, `dim_help/1`, `value_of/1`, `dim/1`, `runtime_deps/0` |
| Q | Runtime fs adapters (never-clobber writers, paths) | 1717–1846 | 130 | `config_target/1`, `legacy_config_target/1`, `global_alerts_path/0`, `existing_config_path/1`, `existing_alerts_path/1`, `load_config/1`, `write_config/2`, `append_config_section/2`, `detect_toolchain/0`, `run_first_prewarm/2`, `write_prompt_file/3`, `write_aiurhooks/1`, `write_alerts_file/2`, `write_new_alerts_file/2`, `same_path?/2`, `write_prewarm_file/2`, `add_gitignore_entry/1,2` |
| R | Legacy layout migration | 1848–1988 | 141 | `migrate_layout/1` (public), `pointer_src/2`, `inside?/2`, `rewrite_pointers/2`, `replace_pointer_value/3`, `parse_yaml/1`, `git_work_tree?/1`, `remove_path/3`, `git/2` |
| S | Public template accessors | 1990–2021 | 32 | `aiurhooks_template/0`, `alerts_template/0,1`, `prompt_file_template/0`, `prompt_file_scaffold/1`, `repo_display/1` |
| T | GitHub label/API adapters | 2023–2097 | 75 | `create_labels/2`, `list_repo_labels/1`, `fetch_label_names/5` (paginated Req client), `parse_owner_repo/1`, `require_github_token/0`, `label_error_message/1` (5 clauses) |
| U | Agent auth / install / detection runtime | 2099–2183 | 85 | `check_agent_auth/1`, `install_hint/2`, `install_claude_app_server/0`, `detect_github_login/0`, `agent_executable/1`, `detect_repo/0`, `parse_repo/1` |
| V | `.env` scaffold + dotenv parsing | 2185–2248 | 64 | `ensure_env/1`, `load_dotenv/0`, `put_env_if_unset/1`, `parse_dotenv/1` (public), `parse_dotenv_line/1`, `parse_dotenv_pair/1`, `dotenv_value/1` |
| W | Agent-kind registry passthrough | 2250–2253 | 4 | `known_agent_kinds/0` |

---

## 2. Proposed module split (NAME MAP — the downstream contract)

All new files under `src/lib/`. Dependency direction is strictly downward:
`Aiur.Init` (flow facade) → feature modules (`Questions`, `Resume`, `Prewarm`, `Alerts`, `Codeowners`, `Labels`,
`AgentCli`) → mechanism modules (`Templates`, `Scaffold`, `Migration`, `GitHub`, `Dotenv`, `Format`) →
existing library modules (`Aiur.GitHub.Labels`, `Aiur.Codeowners`, `Aiur.Prewarm.Detect`, `Aiur.RepoBase`,
`Aiur.CodingAgent`, `Aiur.Workflow`). `Aiur.Init.Runtime` is the composition root and may reference anything.
No module reaches back up.

| Module | File | Responsibility (one sentence) | ~LOC | Key functions moving there |
|--------|------|-------------------------------|-----:|----------------------------|
| `Aiur.Init` | `src/lib/aiur/init.ex` (stays) | Entry point, top-level wizard flow (`run/1,3`, fresh vs resume dispatch, `fresh_setup`, `provision`, closing screens) and stable public facade via `defdelegate`. | ~220 | `run/1`, `run/3`, `init_warning/0`, `existing_config_target/2`, `config_probe_targets/1`, `fresh_setup/4`, `provision/4`, `github_token_present?/1`, `token_setup_instructions/1`, `final_screen/1`, `linear_walkthrough/2`, `tracker_repo/1`, `@type io`/`@type deps`; `defdelegate migrate_layout/1, parse_dotenv/1, aiurhooks_template/0, alerts_template/0,1, prompt_file_template/0, prompt_file_scaffold/1, known_agent_kinds/0` |
| `Aiur.Init.Runtime` | `src/lib/aiur/init/runtime.ex` | Composition root for a live run: builds the real `io` (over `Aiur.Init.Prompt`) and `deps` maps, starts the HTTP client, wires fs/git/network adapters. | ~120 | `runtime_io/0`, `runtime_deps/0`, `ensure_http_client/0`, `detect_toolchain/0`, `run_first_prewarm/2`, `load_config/1` |
| `Aiur.Init.Format` | `src/lib/aiur/init/format.ex` | Shared terminal-text helpers used by every wizard section (faint text, inline-help dimming, option-value recovery, hints). | ~35 | `dim/1`, `dim_help/1`, `value_of/1`, `print_hint/2` |
| `Aiur.Init.Questions` | `src/lib/aiur/init/questions.ex` | The core wizard prompts and their pure parse/normalize policy: location, tracker, agents, complexity routing, permission mode, numeric/"none" limits, agent-kind ordering. | ~185 | `prompt_location/1`, `prompt_tracker/3`, `prompt_agents/1`, `prompt_routing/2` (+`_level/_model/_effort`), `routing_value/3`, `prompt_permission_mode/1`, `prompt_int/5`, `prompt_max_turns/1`, `prompt_max_duration/1`, `normalize_int_or_none/1`, `workspace_default/1`, `agent_kind_choices/0`, `primary_kind/1`, `agent_kinds/1` |
| `Aiur.Init.Resume` | `src/lib/aiur/init/resume.ex` | Resume over an existing config: saved-selections summary, tracker/agents readback, legacy-migration offer, and the promptable-sections backfill registry (#411 convention lives here). | ~180 | `resume/3`, `print_saved_summary/2`, `saved_summary_lines/1`, `alerts_summary_line/1`, `format_routing/1`, `tracker_from_config/2`, `agents_from_config/1`, `routing_backend/1`, `maybe_migrate_layout/5`, `layout_label/1`, `promptable_sections/0`, `backfill_missing_sections/6`, `missing_section?/2`, `offer_section/6`, `append_section/5` |
| `Aiur.Init.Templates` | `src/lib/aiur/init/templates.ex` | One home for all compile-time embedded scaffold templates (`config.example`, `hooks.example`, `alerts.{macos,linux}.example`, `prompt.md.example`, `.env` content) and config-template fill rendering. | ~180 | `@example_template` + `config_example/0` (feeds `deps.read_example`), `aiurhooks_template/0`, `alerts_template/0,1`, `prompt_file_template/0`, `prompt_file_scaffold/1`, `repo_display/1`, `env_example_content/0`, `build_fills/1`, `fill_template/2`, `tracker_provider_block/1`, `routing_inline/1`, `prewarm_base_build_file_line/1` |
| `Aiur.Init.Scaffold` | `src/lib/aiur/init/scaffold.ex` | `.aiur/` layout paths and never-clobber filesystem writers: config write/append, prompt/hooks scaffolds, `.gitignore` entry, `.env`, existing-path probes, plus their "Created:" announce wrappers. | ~190 | `config_target/1`, `legacy_config_target/1`, `global_alerts_path/0`, `existing_config_path/1`, `existing_alerts_path/1`, `write_config/2`, `append_config_section/2`, `write_prompt_file/3`, `write_aiurhooks/1`, `write_prewarm_file/2`, `add_gitignore_entry/1,2`, `ensure_env/1`, `same_path?/2`; io wrappers `ensure_prompt_file/5`, `ensure_aiurhooks/3`, `maybe_offer_gitignore/3`, `setup_env/3` |
| `Aiur.Init.Migration` | `src/lib/aiur/init/migration.ex` | Legacy root-layout → `.aiur/` migration with move-order safety, pointer rewriting, in-repo pointer guard, and git-aware remove/track. | ~160 | `migrate_layout/1`, `pointer_src/2`, `inside?/2`, `rewrite_pointers/2`, `replace_pointer_value/3`, `parse_yaml/1`, `git_work_tree?/1`, `remove_path/3`, `git/2` |
| `Aiur.Init.Prewarm` | `src/lib/aiur/init/prewarm.ex` | Warm-base opt-in: toolchain-detection confirm/edit/skip, detection-miss and ambiguous handoff prompts, one-time first build, resume verification, the `prewarm:` YAML section, and the `.aiur/prewarm` script write. | ~180 | `prompt_prewarm/3`, `resolve_prewarm/2`, `print_prewarm_fallback/1`, `print_prewarm_ambiguous/2`, `prewarm_fallback_prompt/0`, `maybe_first_prewarm/4`, `maybe_resume_prewarm/4`, `prewarm_from_config/1`, `prewarm_section_yaml/1`, `first_prewarm_backfill/5`, `ensure_prewarm_file/4` |
| `Aiur.Init.Prewarm.Failure` | `src/lib/aiur/init/prewarm/failure.ex` | Warm-base build failure reporting: classify (auth vs clone vs build vs other), per-class operator guidance, and the AI handoff prompt embedding captured output. | ~140 | `report_prewarm_failure/4` (public as `report/4`), `classify_prewarm_failure/1`, `auth_error?/1`, `prewarm_failure_guidance/2`, `prewarm_failure_prompt/3`, `failure_output/1` |
| `Aiur.Init.Alerts` | `src/lib/aiur/init/alerts.ex` | Alert-sound opt-in: master-switch + OS-default vs custom-map questions, global-alerts reuse offer, and the never-clobber `.aiur/alerts` write (OS-family template pick via `Templates`). | ~85 | `prompt_alerts/3`, `prompt_reuse_global_alerts/3`, `ensure_alerts/4`, `write_alerts_file/2`, `write_new_alerts_file/2` |
| `Aiur.Init.Codeowners` | `src/lib/aiur/init/codeowners.ex` | Interactive CODEOWNERS trust setup: explain the trust boundary, create the file on confirm, detect the operator login, and offer adding it. | ~130 | `setup_codeowners/3`, `maybe_create_codeowners/3`, `explain_codeowners_trust/1`, `create_codeowners_file/1`, `maybe_add_operator_codeowner/4`, `prompt_and_add_operator_codeowner/4`, `prompt_github_login/2`, `codeowners_has_login?/2`, `offer_operator_codeowner/3` |
| `Aiur.Codeowners.Edit` | `src/lib/aiur/codeowners/edit.ex` | Pure CODEOWNERS content editing next to the existing parser: login normalization, has-login scanning, and wildcard-rule append (one source of truth for CODEOWNERS format facts). | ~100 | `add_login/2` (was `add_codeowners_login/2`), `content_with_login/2` (was `content_with_codeowner/2`), `has_login?/2` (was `codeowners_content_has_login?/2`), `normalize_login/1`, plus `codeowner_tokens/1`, `wildcard_rule_index/1`, `wildcard_rule?/1`, `codeowner_rule_tokens/1`, `append_login_to_rule/2`, `append_codeowner_rule/2`, `write_codeowners_login/3` |
| `Aiur.Init.Labels` | `src/lib/aiur/init/labels.ex` | Staged GitHub label-creation UX: fetch-existing-once, lifecycle (Enter-gated) then optional complexity/model/remote stages, create-or-skip, aligned label listing, and the `gh label create` fallback. | ~170 | `setup_labels/4`, `fetch_existing_labels/2`, `create_lifecycle_labels/4`, `maybe_create_complexity_labels/4`, `maybe_create_model_labels/5`, `maybe_create_remote_label/5`, `create_or_skip/7`, `label_status_line/1`, `create_labels_request/5`, `print_label_list/2`, `emit_gh_label_fallback/4`, `shell_arg/1` |
| `Aiur.Init.GitHub` | `src/lib/aiur/init/github.ex` | Init-side GitHub adapters behind `deps`: create/list repo labels over the API (paginated), owner/repo parsing, token requirement, error-message mapping, and repo/login detection from git/gh. | ~135 | `create_labels/2`, `list_repo_labels/1`, `fetch_label_names/5`, `parse_owner_repo/1`, `require_github_token/0`, `label_error_message/1`, `detect_repo/0`, `parse_repo/1`, `detect_github_login/0` |
| `Aiur.Init.AgentCli` | `src/lib/aiur/init/agent_cli.ex` | Agent-CLI presence checks after setup: per-backend auth check with retry-or-skip, `aiur-claude` auto-install with manual-install degradation, executable resolution. | ~120 | `check_agent_clis/3`, `ensure_agent_cli/3`, `install_claude_then_check/2`, `run_auth_check/3`, `check_agent_auth/1`, `install_hint/2`, `install_claude_app_server/0`, `agent_executable/1` |
| `Aiur.Init.Dotenv` | `src/lib/aiur/init/dotenv.ex` | `.env` loading into the process environment (existing vars always win) and dotenv line parsing. | ~60 | `load_dotenv/0` (public as `load/0`), `put_env_if_unset/1`, `parse_dotenv/1` (public as `parse/1`), `parse_dotenv_line/1`, `parse_dotenv_pair/1`, `dotenv_value/1` |

Total ≈ 2,240 LOC across 17 modules (16 new files + slimmed `init.ex`); every file ≤ ~220, most ≤ 190.
`Aiur.Init.Prompt` (`src/lib/aiur/init/prompt.ex`, 288 lines) is untouched.

Notes on judgment calls:

- **Facade delegates stay.** `Aiur.Init` keeps `defdelegate` for every public function tests use
  (`migrate_layout/1`, `parse_dotenv/1`, template accessors, `known_agent_kinds/0`) so
  `init_test.exs` passes unedited through every wave. A later (optional) ticket may repoint tests
  and drop delegates; not part of this decomposition.
- **All compile-time embeds in one module.** `@external_resource` + `File.read!` at compile time is
  the historically fragile mechanism (hotspot rows 7 and 15); concentrating it in
  `Aiur.Init.Templates` gives one place to fix path-depth facts.
- **`Aiur.Codeowners.Edit`** is the only cross-namespace move: `init.ex` currently re-implements
  CODEOWNERS line tokenization that `Aiur.Codeowners.parse_line/line_tokens` also knows. This wave
  only *moves* the init implementation next to the parser (no merging of the two tokenizers — that
  is a flagged follow-up, per "surface conflicts, don't average them").
- `token_setup_instructions/final_screen/linear_walkthrough` stay in `Aiur.Init`: they are flow-level
  closing screens invoked directly by `provision/4`, and moving them buys nothing.

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

After every wave: `mix compile --warnings-as-errors` and the full test suite pass with **zero edits to
`init_test.exs`** (it drives `run/3` + the delegated public facade). Each wave is one reviewable ticket,
≤400 lines moved.

- **Wave 1 — leaf mechanisms (~280 moved):** extract `Aiur.Init.Format`, `Aiur.Init.Dotenv`,
  `Aiur.Init.Templates` (all embedded templates + fill rendering). Add facade `defdelegate`s for
  `parse_dotenv/1` and the four template accessors. **Critical detail:** every
  `Path.expand("../../../.aiur/examples/...", __DIR__)` gains one directory of depth in
  `src/lib/aiur/init/templates.ex` → must become `"../../../../.aiur/examples/..."`; keep
  `@external_resource` attributes with the templates. Verify by asserting the existing template tests
  ("alert examples are concise and fully populated…", scaffold tests) stay green.
- **Wave 2 — filesystem layer (~350 moved):** extract `Aiur.Init.Scaffold` (paths, never-clobber
  writers, gitignore, `.env`, announce wrappers) and `Aiur.Init.Migration` (which calls
  `Scaffold.add_gitignore_entry/2`). `defdelegate migrate_layout/1`. The 11 `migrate_layout` tests
  and the never-clobber tests pin this wave.
- **Wave 3 — GitHub adapters + label UX (~300 moved):** extract `Aiur.Init.GitHub` and
  `Aiur.Init.Labels`. The "closing steps (github)" describe (~15 tests: staging, gating, gh
  fallback, padding, status lines) pins the flow; label API adapters move verbatim.
- **Wave 4 — trust + agent CLI (~330 moved):** extract `Aiur.Codeowners.Edit` (pure content edit),
  `Aiur.Init.Codeowners` (interactive flow), and `Aiur.Init.AgentCli`. Pinned by the "CODEOWNERS
  trust setup" and "claude app-server install" describes plus `codeowners_test.exs` (must stay
  untouched — `Aiur.Codeowners` itself gains a submodule but no behavior change).
- **Wave 5 — prewarm + alerts (~400 moved):** extract `Aiur.Init.Prewarm`, `Aiur.Init.Prewarm.Failure`,
  `Aiur.Init.Alerts` (templates already live in `Templates` from wave 1). Pinned by "pre-warm opt-in",
  "warm-base failure report", "alert sound opt-in", and the prewarm parts of "resume backfill (#411)".
- **Wave 6 — questions + resume (~360 moved):** extract `Aiur.Init.Questions` and `Aiur.Init.Resume`
  (including the `promptable_sections/0` registry; move the #411 convention comment with it and update
  the pointer comment on `run/3`). Pinned by "existing-config handling", "resume backfill", "agents,
  routing, permission mode", "limits and helper text", "tracker prompts fill the nested template".
- **Wave 7 — runtime composition + final slim (~140 moved):** extract `Aiur.Init.Runtime`
  (`runtime_io/runtime_deps/ensure_http_client` + remaining runtime adapters), leaving `Aiur.Init`
  as flow + facade (~220 lines). `run/1` becomes
  `Dotenv.load(); Runtime.ensure_http_client(); run(opts, Runtime.io(), Runtime.deps())` — same order,
  same effects.

Waves 1→7 are strictly ordered (each edits `init.ex`); no two may be in flight at once.

---

## 4. Risks and required-verbatim semantics

Hotspot context (`docs/refactor/research-history-hotspots.md`): row 7 — *Init & config scaffolding*,
~14 incidents: "fresh-install scaffold gaps…; `.aiur/` layout move broke compile-time paths, skills,
alerts; init clobbers real configs (#649, #724)". Row 15 (alerts, #702) and row 2 (test isolation via
global mutable env/state) also apply. Characterization priority item 11 in that doc names exactly this
file: "never-clobber existing config/env, resume backfill, `.aiur/` layout resolution incl.
release-relocated paths."

### Semantics that must be preserved verbatim

1. **Compile-time template embedding paths** (top risk, wave 1). `@external_resource` +
   `Path.expand(..., __DIR__)` breaks silently-at-build when file depth changes; this exact class
   caused incidents in hotspot rows 7 and 15 (#702: stale bundled path → 15 CI failures). Templates
   must still be embedded at compile time (release runs have no repo checkout at runtime) — do not
   "simplify" to runtime reads.
2. **Never-clobber rules (#649, #724).** Every writer guards with `File.regular?` before writing
   (`write_prompt_file`, `write_aiurhooks`, `write_alerts_file` + `same_path?` self-copy guard,
   `write_prewarm_file`, `ensure_env` for `.env`); `ensure_env` *always* rewrites `.env.example` but
   never `.env`; `append_config_section` appends (blank-line separated), never regenerates. The config
   probe order in `config_probe_targets/1` (repo new → repo legacy → global new → global legacy) mirrors
   `Aiur.Workflow` discovery and decides clobber-vs-resume — byte-for-byte preserve.
3. **Migration move-order safety.** `migrate_layout/1`: copy pointer/example files → write rewritten
   new config → only then remove legacy (git-aware) → git add or gitignore. Plus the `inside?/2` guard
   (pointer targets outside the repo are never copied/deleted) and whole-token pointer rewriting
   (quoted values with spaces). All pinned by the `migrate_layout/1` describe; a partial failure must
   never leave a state aiur can't load.
4. **Global process state on the runtime path only.** `load_dotenv` mutates `System.put_env`
   (only-if-unset) and `ensure_http_client` starts `:req` — both live exclusively in `run/1`, never
   `run/3`. `init_test.exs` is `async: true`; leaking either into the injected-deps path recreates
   the hotspot-row-2 env-leak class (cf. PR #582's cached-nil-token breakage). `ensure_http_client`
   must stay before any label API call.
5. **Label staging semantics.** Existing labels fetched once (`fetch_existing_labels`, errors treated
   as "all missing" because creation is idempotent); per-stage `labels -- existing`; lifecycle stage is
   Enter-gated (`io.input`), optional stages are confirm-gated with their exact defaults
   (complexity/model `true`, remote `false`); a `create_labels` failure prints the `gh` fallback and
   returns `:error`, which **withholds** `final_screen` (the "permission failure … withholds the ready
   screen" test). Remote stage only exists when `Labels.alias_labels(kinds)` is non-empty.
6. **Exact operator-facing text.** Dozens of tests assert `io.puts` output by substring — including
   faint-ANSI formatting (`IO.ANSI.format([:faint, …])`), label-column padding, "Created:"/"Found:"
   prefixes, and the two AI-handoff heredocs. Moved text must be byte-identical; keep `dim/1` the
   single faint-text helper.
7. **Prompt-flow ordering and defaults.** The scripted-io harness is label-keyed (mostly
   order-independent) but several tests assert which prompts appear (e.g. resume skips the location
   question; global init skips gitignore/prewarm/prompt_file/repo prompts; agent multiselect never
   offers `claude-repl`) and the `@routing_order`-based agent sorting (`agent_kinds/1`,
   `primary_kind/1`). Resume must keep provisioning from the *saved* config (`agents_from_config`
   including routing backends), and `check_agent_clis` must keep filtering to `@routing_order` so
   `claude-repl` never gets an auth check.
8. **#411 backfill convention.** `offer_section/6` runs the one-time side effect only after a
   successful append; declining leaves the config untouched. The registry's convention comment
   ("register new init prompts in `promptable_sections/0`") must move with the registry and the
   `run/3` comment must point at its new home, or the convention dies.

### Existing test pins

- `src/test/aiur/init_test.exs` (1793 lines, ~110 tests) — the primary characterization suite; drives
  `run/3` with injected `io`/`deps`, plus direct `migrate_layout/1`, `alerts_template/0,1`,
  `prompt_file_scaffold/1`, `prompt_file_template/0`, `aiurhooks_template/0`, `parse_dotenv/1`.
  Covers: CODEOWNERS setup, prewarm opt-in + failure report, alerts opt-in, existing-config
  resume/migration, #411 backfill, migration internals, dotenv parsing, template fills, label staging,
  claude app-server install, never-clobber for hooks.
- `src/test/aiur/init/prompt_test.exs` (160 lines) — pins `Aiur.Init.Prompt` (untouched).
- `src/test/aiur/codeowners_test.exs` — pins `Aiur.Codeowners`, relevant to wave 4's `Edit` submodule.
- `src/test/aiur/cli_test.exs` — pins the `Aiur.Init.run/1` call site.

### Characterization gaps (recommend adding before the wave that moves them)

- **Runtime adapters are untested** (tests inject fakes for all `deps`): `detect_repo/parse_repo`
  (git-URL forms: ssh, https, trailing `.git`), `detect_github_login` (gh absent), paginated
  `fetch_label_names/5` (the 100-per-page recursion has zero coverage; add a Req-stub test before
  wave 3), `install_claude_app_server` (npm absent), `add_gitignore_entry/1` cwd variant (the `/2`
  variant is covered via migration), `ensure_env` (real fs), `write_config` mkdir_p behavior.
- **`load_dotenv`/`put_env_if_unset`** (existing-env-wins) has no test — add one (with env cleanup)
  before wave 1, or accept the move as byte-identical.
- **`run/1` end-to-end** (dotenv → http client → runtime io/deps) has no automated pin; a manual
  `scripts/aiur init` smoke in a scratch repo after wave 7 is the practical check (per repo norms:
  manual CLI verification before declaring done).
- **Never-clobber for `.aiur/alerts` and `.aiur/prewarm` on re-run**: hooks non-clobber is pinned;
  alerts/prewarm equivalents are pinned only indirectly (via `:exists` fake deps) — a small real-fs
  characterization test each would pin rule 2 above through waves 2 and 5.
