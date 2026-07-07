# T-031: init wave 1: Runtime, Format, Questions, Resume, Templates

**Phase:** 3
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/init.ex` is a 2,253-line "giant" that owns the entire `aiur init`
wizard (see `docs/refactor/research-arch/giant-init.md`). This is the first of
three strictly-serialized decomposition waves for that file (T-031 → T-032 →
T-033), extracting focused modules under `src/lib/aiur/init/` per the NAME MAP
in `giant-init.md` §2 — the binding downstream contract. This is a
**behavior-preserving** refactor: code moves verbatim, public signatures and
observable output are unchanged, and `Aiur.Init` keeps its public facade (via
`defdelegate`) so every existing caller — `src/lib/aiur/cli.ex:49`
(`Init.run/1`) and the 1,793-line `src/test/aiur/init_test.exs` — keeps working
untouched.

Init & config scaffolding is regression hotspot row 7 (~14 incidents) in
`docs/refactor/research-history-hotspots.md`; the dominant recurring defect is
**compile-time template-path embedding** breaking when files move (#393,
#700/#702, #726). This wave moves exactly those `@external_resource` /
`Path.expand(..., __DIR__)` template attributes into a new file, so §"Scope"
step 3 pins the one path-depth change that class demands, and the T-006
`compile_time_paths_test.exs` guard must stay green.

This wave extracts the modules whose dependencies point strictly *downward*
(`Aiur.Init.Format`, `Aiur.Init.Templates`, `Aiur.Init.Questions`) in full, and
the forward-dependency-free members of `Aiur.Init.Runtime` and
`Aiur.Init.Resume`. Members of `Runtime`/`Resume` that call into modules not yet
extracted (`Prewarm`, `Scaffold`, `Codeowners` come in T-032/T-033) are
explicitly deferred to those later waves per the dependency-direction rule in
`giant-init.md` §2 ("dependency direction is strictly downward … no module
reaches back up") and its §3 wave ordering (Resume/Runtime land after
Prewarm/Scaffold/Codeowners). Deferred members are enumerated in §"Out of
scope" so nothing is silently dropped.

## Scope (exact)

Namespace: new modules live under `src/lib/aiur/init/` as `Aiur.Init.<Name>`
(proven by the existing `Aiur.Init.Prompt` at `src/lib/aiur/init/prompt.ex`,
which is NOT touched). Every new module gets a `@moduledoc` and `@spec` on every
public `def`. Move code **verbatim** — do not rewrite, reword comments, reorder
clauses, or "improve" anything. All operator-facing strings must stay
byte-identical (dozens of `init_test.exs` assertions match `io.puts` output by
substring, including faint-ANSI formatting).

Do the steps in this order.

### Step 1 — Create `Aiur.Init.Format` (`src/lib/aiur/init/format.ex`)

Move these four helpers verbatim out of `Aiur.Init`, making each a public `def`
with an `@spec`:

- `dim/1` (currently `defp dim`, `init.ex:1683`)
- `dim_help/1` (currently `defp dim_help`, `init.ex:1674-1679`)
- `value_of/1` (currently `defp value_of`, `init.ex:1681`)
- `print_hint/2` (currently `defp print_hint`, `init.ex:1517`) — its body calls
  `dim/1`; that call now resolves within `Aiur.Init.Format`.

`@moduledoc`: one sentence — shared terminal-text helpers (faint text, inline-
help dimming, option-value recovery, hints) used by every wizard section.

In `Aiur.Init`, add `alias Aiur.Init.Format` and update **every** remaining
call site of these helpers to the qualified form `Format.dim(...)`,
`Format.value_of(...)`, `Format.print_hint(...)`, `&Format.dim_help/1`. Call
sites are pervasive (`dim/1` alone: `init.ex:246, 309, 498, 728, 730, 753, 769,
771, 859, 897, 901, 912, 990, 1088, 1098, 1108, 1119, 1134, 1165, 1251, 1376,
1377`; `dim_help/1`: `init.ex:1662`; `print_hint/2`: `init.ex:1421, 1439, 1457,
1477`). `value_of/1` call sites (`init.ex:549, 605, 615, 627`) live in code that
moves to `Questions` in Step 3 — update them there to `Format.value_of(...)`.
`mix compile --warnings-as-errors` (undefined-function errors) is the backstop
for any missed site.

### Step 2 — Create `Aiur.Init.Templates` (`src/lib/aiur/init/templates.ex`)

`@moduledoc`: one home for all compile-time embedded scaffold templates and
config-template fill rendering.

Move verbatim into this module:

1. The compile-time template attributes and their `@external_resource`
   directives (`init.ex:49-52`, `54-59`, `72-98`): `@prompt_example_path`,
   `@prompt_example_template`, `@repo_placeholder`, `@env_example_content`,
   `@example_path`, `@example_template`, `@aiurhooks_file_name` is NOT a
   template (leave it — see below), `@aiurhooks_example_path`,
   `@aiurhooks_example_template`, `@alerts_file_name` is NOT a template (leave
   it), `@alerts_macos_example_path`, `@alerts_linux_example_path`,
   `@alerts_macos_example_template`, `@alerts_linux_example_template`, and
   `@prewarm_file_name` (needed by `prewarm_base_build_file_line/1`, below —
   also still used by code staying in `Aiur.Init`; see the shared-constant note
   at the end of this step).
2. The public template accessors (`init.ex:1990-2021`): `aiurhooks_template/0`,
   `alerts_template/0`, `alerts_template/1` (all three clauses),
   `prompt_file_template/0`, `prompt_file_scaffold/1`, and the private
   `repo_display/1` it calls (keep `repo_display/1` private in `Templates`).
   Add a new public `config_example/0` that returns `@example_template` (this
   feeds `deps.read_example` — see Step 4/Out-of-scope) and a new public
   `env_example_content/0` that returns `@env_example_content`.
3. The template-fill functions (`init.ex:1019-1078`): `build_fills/1`,
   `prewarm_base_build_file_line/1` (both clauses), `fill_template/2`,
   `tracker_provider_block/1` (all three clauses), `routing_inline/1`. Make
   `build_fills/1` and `fill_template/2` public (`@spec`); the others may stay
   private in `Templates`. `build_fills/1` calls `primary_kind/1`, which lives
   in `Aiur.Init.Questions` after Step 3 — that call becomes
   `Questions.primary_kind(...)` (`alias Aiur.Init.Questions` in `Templates`).

3-CRITICAL (compile-time path depth — the #700/#702/#726 defect class). The
template files are embedded at COMPILE time via `@external_resource` +
`File.read!/1`; releases have no source tree, so they **must** stay compile-time
embedded — do NOT convert to runtime reads. `templates.ex` sits one directory
deeper than `init.ex` (`src/lib/aiur/init/` vs `src/lib/aiur/`), so every
`Path.expand("../../../.aiur/examples/…", __DIR__)` gains exactly one `../` and
becomes `Path.expand("../../../../.aiur/examples/…", __DIR__)`. Apply to all
four path attributes:

```
@prompt_example_path       Path.expand("../../../../.aiur/examples/prompt.md.example", __DIR__)
@example_path              Path.expand("../../../../.aiur/examples/config.example", __DIR__)
@aiurhooks_example_path    Path.expand("../../../../.aiur/examples/hooks.example", __DIR__)
@alerts_macos_example_path Path.expand("../../../../.aiur/examples/alerts.macos.example", __DIR__)
@alerts_linux_example_path Path.expand("../../../../.aiur/examples/alerts.linux.example", __DIR__)
```

Keep each `@external_resource @<name>_path` line directly with its attribute.

In `Aiur.Init`, add `alias Aiur.Init.Templates` and update the code that stays
in `Aiur.Init` but referenced the moved attributes/functions to call
`Templates.*`:

- `init.ex:1373` `deps.ensure_env.(@env_example_content)` →
  `deps.ensure_env.(Templates.env_example_content())`.
- `init.ex:1693` `read_example: fn -> @example_template end` →
  `read_example: fn -> Templates.config_example() end`.
- `init.ex:1782` `File.write!(path, @aiurhooks_example_template)` →
  `File.write!(path, Templates.aiurhooks_template())`.
- `init.ex:1807` `File.write!(path, alerts_template(:os.type()))` →
  `File.write!(path, Templates.alerts_template(:os.type()))`.
- `init.ex:1771` `File.write!(path, prompt_file_scaffold(repo))` →
  `File.write!(path, Templates.prompt_file_scaffold(repo))`.
- `init.ex:305` `fill_template(deps.read_example.(), fills)` →
  `Templates.fill_template(deps.read_example.(), fills)`.
- `init.ex:289` `build_fills(%{…})` → `Templates.build_fills(%{…})`.

Facade: in `Aiur.Init`, replace the moved public accessor bodies with
delegates so `init_test.exs` and any external caller keep the identical API:

```
defdelegate aiurhooks_template(), to: Templates
defdelegate alerts_template(), to: Templates
defdelegate alerts_template(os_type), to: Templates
defdelegate prompt_file_template(), to: Templates
defdelegate prompt_file_scaffold(repo), to: Templates
```

Keep the existing `@doc`/`@spec` on those `Aiur.Init` entries above the
`defdelegate`s (so the public docs/specs are unchanged).

Shared-constant note: `@prewarm_file_name` also appears in code that stays in
`Aiur.Init` this wave (`prewarm_section_yaml/1` at `init.ex:516`,
`write_prewarm_file/2` at `init.ex:1814`) and moves to `Prewarm`/`Scaffold` in
T-032. To keep this wave a clean verbatim move with no upward calls, **leave a
copy of `@prewarm_file_name "prewarm"` defined in `Aiur.Init`** in addition to
the copy in `Templates`. This transient duplication is removed in T-032 when
`prewarm_section_yaml/1` and `write_prewarm_file/2` leave `Aiur.Init`. Do the
same for `@aiurhooks_file_name` and `@alerts_file_name`: they are NOT templates
and are used by `write_aiurhooks/1`/`write_alerts_file/2` staying in
`Aiur.Init`, so leave them in `Aiur.Init` and do not move them.

### Step 3 — Create `Aiur.Init.Questions` (`src/lib/aiur/init/questions.ex`)

`@moduledoc`: the core wizard prompts and their pure parse/normalize policy
(location, tracker, agents, complexity routing, permission mode, numeric/"none"
limits, agent-kind ordering).

Move verbatim from `Aiur.Init`:

- The prompt block `init.ex:544-705`: `prompt_location/1`, `prompt_tracker/3`,
  `prompt_agents/1`, `prompt_routing/2`, `prompt_routing_level/4`,
  `prompt_routing_model/3`, `prompt_routing_effort/3`, `routing_value/3` (all
  four clauses), `prompt_permission_mode/1`, `prompt_int/4` (the
  `prompt_int(io, label, default, min, hint \\ nil)` head + body),
  `prompt_max_turns/1`, `prompt_max_duration/1`, `normalize_int_or_none/1`.
- `workspace_default/1` (both clauses, `init.ex:266-269`).
- The agent-kind helpers `init.ex:1637-1647`: `agent_kind_choices/0`,
  `primary_kind/1`, `agent_kinds/1`.
- `known_agent_kinds/0` implementation (`init.ex:2250-2252`): move the body
  (`def known_agent_kinds, do: CodingAgent.known_backends()`) here as a public
  `def` and delegate from `Aiur.Init` (see facade below). `agent_kind_choices/0`
  calls `known_agent_kinds/0`, which now resolves within `Questions`.
- The module attributes consumed only by these functions: `@tracker_kinds`
  (`init.ex:64`, used by `prompt_tracker/3`) and `@permission_modes`
  (`init.ex:65`, used by `prompt_permission_mode/1`). Move both to `Questions`;
  they have no other consumer in `Aiur.Init`.
- `@routing_order` (`init.ex:67`) is consumed by `agent_kind_choices/0` and
  `agent_kinds/1` (moving here) AND by `check_agent_clis/3` (`init.ex:1578`,
  staying in `Aiur.Init` until T-033). Define `@routing_order ["claude",
  "codex"]` in `Questions` AND **leave the existing copy in `Aiur.Init`**;
  T-033 removes the `Aiur.Init` copy when `check_agent_clis/3` leaves. Do not
  reword the comment above it.

Make public (with `@spec`, referencing `Aiur.Init.io()` / `Aiur.Init.deps()`
for the injected-map params — those `@type`s stay in `Aiur.Init` and are
already public): `prompt_location/1`, `prompt_tracker/3`, `prompt_agents/1`,
`prompt_routing/2`, `prompt_permission_mode/1`, `prompt_int/4`,
`prompt_max_turns/1`, `prompt_max_duration/1`, `workspace_default/1`,
`agent_kind_choices/0`, `primary_kind/1`, `agent_kinds/1`,
`known_agent_kinds/0`, `routing_value/3`, `normalize_int_or_none/1`. The three
`prompt_routing_*` helpers may stay private. In `Questions`, `value_of/1` calls
become `Format.value_of(...)` (`alias Aiur.Init.Format`); `prompt_routing_model`
/`prompt_routing_effort` call `CodingAgent.*` (`alias Aiur.CodingAgent`).

In `Aiur.Init`, add `alias Aiur.Init.Questions` and update the call sites that
stay in `Aiur.Init`:

- `fresh_setup/4` (`init.ex:271-323`): `prompt_tracker(io, deps, location)` →
  `Questions.prompt_tracker(...)`, and likewise `prompt_agents`,
  `prompt_routing`, `prompt_permission_mode`, `prompt_int` (both call sites
  `init.ex:277, 281, 282`), `prompt_max_turns`, `prompt_max_duration`,
  `workspace_default`.
- `prompt_location(io)` at `init.ex:158` → `Questions.prompt_location(io)`.
- `agents_from_config/1` (moving to `Resume` in Step 5) calls `agent_kinds/1` →
  `Questions.agent_kinds(...)`.
- `Templates.build_fills/1` calls `Questions.primary_kind/1` (Step 2).

Facade: `defdelegate known_agent_kinds(), to: Questions` in `Aiur.Init` (keep
its existing `@doc false`/`@spec`). This is the only Questions member
`init_test.exs`/other callers reach by name.

### Step 4 — Create `Aiur.Init.Runtime` (`src/lib/aiur/init/runtime.ex`)

`@moduledoc`: composition-root helpers for a live `aiur init` run (HTTP client
start, toolchain detection, first warm-base build, config readback).

Move verbatim and make public (`@spec`):

- `ensure_http_client/0` (`init.ex:147-150`).
- `detect_toolchain/0` (`init.ex:1759`).
- `run_first_prewarm/2` (`init.ex:1761-1763`).
- `load_config/1` (`init.ex:1733-1738`).

`Runtime` aliases `Aiur.Prewarm.Detect` (for `detect_toolchain`),
`Aiur.RepoBase` (for `run_first_prewarm`), and references `Aiur.Workflow` (for
`load_config`) exactly as `init.ex` does today.

In `Aiur.Init`, add `alias Aiur.Init.Runtime` and update:

- `run/1` (`init.ex:138-142`): `ensure_http_client()` →
  `Runtime.ensure_http_client()`.
- `runtime_deps/0` (which STAYS in `Aiur.Init` this wave — see Out of scope):
  `detect_toolchain: &detect_toolchain/0` → `&Runtime.detect_toolchain/0`;
  `prewarm_build: &run_first_prewarm/2` → `&Runtime.run_first_prewarm/2`;
  `load_config: &load_config/1` → `&Runtime.load_config/1`.

### Step 5 — Create `Aiur.Init.Resume` (`src/lib/aiur/init/resume.ex`)

`@moduledoc`: saved-config readback for a resume run — the saved-selections
summary and the tracker/agents/routing readback from an existing config.

Move verbatim the pure readback helpers (`init.ex:362-442`), making each public
with an `@spec`:

- `print_saved_summary/2`, `saved_summary_lines/1`, `alerts_summary_line/1`,
  `format_routing/1` (both clauses), `tracker_from_config/2`,
  `agents_from_config/1`, `routing_backend/1`.

Details: `agents_from_config/1` calls `agent_kinds/1` →
`Questions.agent_kinds(...)` (`alias Aiur.Init.Questions`);
`tracker_from_config/2` uses `deps.detect_repo` (unchanged). These take
`Aiur.Init.deps()` in their specs where needed.

In `Aiur.Init`, add `alias Aiur.Init.Resume` and update `resume/3`
(`init.ex:209-226`, which STAYS in `Aiur.Init` this wave — see Out of scope) to
call `Resume.print_saved_summary(io, config)`,
`Resume.tracker_from_config(deps, config)`, and
`Resume.agents_from_config(config)`.

### Step 6 — Update the T-006 compile-time-path allowlist (sanctioned data edit)

Moving the five `@external_resource` template attributes into `templates.ex`
(Step 2) makes `src/test/aiur/regression/compile_time_paths_test.exs` scan hits
under the new file with the new `../../../../` depth. That test's `@allowlist`
is an explicitly *maintained* data map (see its `@moduledoc` and T-006 §3): a
reviewed file relocation of compile-time-only embeds is exactly the "deliberate,
reviewed act" it is designed to record. This is a DATA update to reflect the
move, NOT a weakening of any assertion. Make this exact change to `@allowlist`:

- Remove the `"aiur/init.ex"` key and its 10 strings (those lines no longer
  exist in `init.ex`).
- Add a new key `"aiur/init/templates.ex"` whose value is the 10 trimmed lines
  as they now read in `templates.ex` (the 5 `Path.expand` lines with
  `../../../../`, each followed by its `@external_resource @<name>_path` line):

```elixir
"aiur/init/templates.ex" => [
  "@prompt_example_path Path.expand(\"../../../../.aiur/examples/prompt.md.example\", __DIR__)",
  "@external_resource @prompt_example_path",
  "@example_path Path.expand(\"../../../../.aiur/examples/config.example\", __DIR__)",
  "@external_resource @example_path",
  "@aiurhooks_example_path Path.expand(\"../../../../.aiur/examples/hooks.example\", __DIR__)",
  "@external_resource @aiurhooks_example_path",
  "@alerts_macos_example_path Path.expand(\"../../../../.aiur/examples/alerts.macos.example\", __DIR__)",
  "@alerts_linux_example_path Path.expand(\"../../../../.aiur/examples/alerts.linux.example\", __DIR__)",
  "@external_resource @alerts_macos_example_path",
  "@external_resource @alerts_linux_example_path"
]
```

Leave the `"aiur/agent_skills.ex"`, `"aiur/prompt_builder.ex"`, and
`"aiur_web/static_assets.ex"` keys untouched. Do not touch either `test` block
or the `scan_hits/0` helper. After the edit, `mix format
test/aiur/regression/compile_time_paths_test.exs` and confirm the two tests are
green. If any trimmed string does not match `templates.ex` byte-for-byte, fix
the string to match the source (never the reverse).

### Step 7 — New test files

Create one test file per extracted module (new modules are NOT
coverage-exempt — see Acceptance). Each must be `async: true`, use no
`Process.sleep`, and directly exercise the module's public functions:

- `src/test/aiur/init/format_test.exs` — `Format.dim/1` wraps in faint ANSI;
  `dim_help/1` dims the ` (…)` suffix only; `value_of/1` recovers the bare
  option; `print_hint/2` prints a dimmed two-space-indented line.
- `src/test/aiur/init/templates_test.exs` — `config_example/0`,
  `aiurhooks_template/0`, `prompt_file_template/0`, `env_example_content/0`
  return non-empty embedded content; `alerts_template({:unix, :darwin})` vs
  `{:unix, :linux}` pick the macOS vs Linux body; `prompt_file_scaffold/1`
  fills `{{REPO}}` (and the `nil`/blank → `"current"` fallback);
  `build_fills/1` + `fill_template/2` render a known token map.
- `src/test/aiur/init/questions_test.exs` — `normalize_int_or_none/1`
  (`"none"`/`""`/`"unlimited"` → `:none`, valid int, `:invalid`);
  `routing_value/3` (all four encodings); `agent_kinds/1` sorts by
  `@routing_order` and dedups; `agent_kind_choices/0` filters to known kinds;
  `primary_kind/1`; `workspace_default/1` github-repo vs fallback.
- `src/test/aiur/init/runtime_test.exs` — `load_config/1` returns
  `{:ok, config}` for a written config file and `{:error, _}` for a missing one
  (use a tmp dir); `detect_toolchain/0` returns a `Detect.result()` for a
  scratch dir. (Do not call `ensure_http_client/0`/`run_first_prewarm/2` against
  the network.)
- `src/test/aiur/init/resume_test.exs` — `saved_summary_lines/1` and
  `format_routing/1` render a known config map; `tracker_from_config/2`
  (github/linear/other); `agents_from_config/1` (kind + routing backends,
  deduped/sorted); `routing_backend/1`; `alerts_summary_line/1`.

## Files
- Create:
  - `src/lib/aiur/init/format.ex`
  - `src/lib/aiur/init/templates.ex`
  - `src/lib/aiur/init/questions.ex`
  - `src/lib/aiur/init/runtime.ex`
  - `src/lib/aiur/init/resume.ex`
  - `src/test/aiur/init/format_test.exs`
  - `src/test/aiur/init/templates_test.exs`
  - `src/test/aiur/init/questions_test.exs`
  - `src/test/aiur/init/runtime_test.exs`
  - `src/test/aiur/init/resume_test.exs`
- Modify:
  - `src/lib/aiur/init.ex`
  - `src/test/aiur/regression/compile_time_paths_test.exs` (Step 6 — `@allowlist`
    data only)

## Out of scope
Do NOT touch or move (they belong to later waves / stay in `Aiur.Init`):

- `src/lib/aiur/init/prompt.ex` (`Aiur.Init.Prompt`) — untouched.
- `runtime_io/0` and `runtime_deps/0` — they wire `io`/`deps` adapters that live
  in `Scaffold`/`Migration`/`GitHub`/`AgentCli` (extracted T-032/T-033). They
  STAY in `Aiur.Init` this wave; T-033 relocates them into `Aiur.Init.Runtime`.
- `resume/3`, `maybe_migrate_layout/5`, `layout_label/1`, `promptable_sections/0`,
  `backfill_missing_sections/6`, `missing_section?/2`, `offer_section/6`,
  `append_section/5` — the resume-flow orchestrator and the #411 backfill
  registry forward-reference `prompt_prewarm/3`, `maybe_first_prewarm/4`,
  `ensure_prewarm_file/4`, `setup_codeowners/3`, `provision/4`. They STAY in
  `Aiur.Init` and move to `Aiur.Init.Resume` in T-032, once `Prewarm`/`Codeowners`
  exist (matches `giant-init.md` §3 wave 6 landing after waves 2/4/5).
- All Scaffold/Prewarm/Alerts/Codeowners/Labels/GitHub/AgentCli/Migration/Dotenv
  code and their attributes (`@config_file_name`, `@legacy_config_file_name`,
  `@prompt_basename`, `@gitignore_entry`, `@aiurhooks_file_name`,
  `@alerts_file_name`, `@prewarm_file_name` copy in `Aiur.Init`,
  `@codeowners_file_name`, `@token_url`, `@linear_key_url`, `@label_prefix`,
  `@env_file_name`, `@env_example_file_name`, `@legacy_examples`) — later waves.
- `Aiur.Init.run/1`, `run/3`, `fresh_setup/4`, `provision/4`, `init_warning/0`,
  `existing_config_target/2`, `config_probe_targets/1`, `github_token_present?/1`,
  the closing screens (`token_setup_instructions/1`, `final_screen/1`,
  `linear_walkthrough/2`), `tracker_repo/1`, the `@type io`/`@type deps` — all
  stay in `Aiur.Init`.
- Do NOT repoint or edit `src/test/aiur/init_test.exs`, `cli_test.exs`, or
  `codeowners_test.exs`. Do NOT touch the two `test` blocks or `scan_hits/0` in
  `compile_time_paths_test.exs` — only its `@allowlist` map (Step 6).
- Do NOT merge the init CODEOWNERS tokenizer with `Aiur.Codeowners` (that is a
  T-033 concern), convert any compile-time embed to a runtime read, or change
  any operator-facing string.

## Inventory-IDs
Implemented/touched by this ticket's files (from
`docs/refactor/feature-inventory/ws.md`):

- **FI-WS-017** — `aiur init` wizard entry: `ensure_http_client/0` moves to
  `Aiur.Init.Runtime` (`init_warning/0`, dotenv stay in `Aiur.Init`).
- **FI-WS-018** — Existing-config resume: the saved-selections summary +
  tracker/agents/routing readback (`print_saved_summary`, `saved_summary_lines`,
  `tracker_from_config`, `agents_from_config`, `format_routing`,
  `alerts_summary_line`, `routing_backend`) move to `Aiur.Init.Resume`.
- **FI-WS-020** — Fresh-setup question flow + template fill: all `prompt_*`/
  routing/limit/agent-kind functions move to `Aiur.Init.Questions`;
  `build_fills`/`fill_template`/`tracker_provider_block`/`routing_inline` move
  to `Aiur.Init.Templates`.
- **FI-WS-021** — Sibling-file scaffolding templates: the compile-time
  `@external_resource` template attributes and accessors
  (`aiurhooks_template`, `alerts_template`, `prompt_file_scaffold`,
  `prompt_file_template`, `env_example_content`) move to `Aiur.Init.Templates`
  (this is the FI whose "compile-time embedded via `@external_resource`"
  guarantee the path-depth change in Step 3 preserves).
- **FI-WS-024** (partial) — `prewarm_base_build_file_line/1` (template-fill
  fragment) moves to `Aiur.Init.Templates`; the rest of the prewarm flow is
  T-032.

## Characterization-tests
Must pass green after this wave.

- `src/test/aiur/regression/compile_time_paths_test.exs` (from T-006) — the
  compile-time path-embedding guard that directly protects the Step-2 template
  move. Its two `test` blocks and `scan_hits/0` stay UNMODIFIED; only its
  `@allowlist` data is updated per Step 6 (a sanctioned relocation record, the
  test's documented maintenance path — not an assertion change).
- `src/test/aiur/init_test.exs` (the 1,793-line primary init characterization
  suite) — must pass **unmodified**. It drives `Init.run/3` and the delegated
  public facade (`aiurhooks_template/0`, `alerts_template/0,1`,
  `prompt_file_template/0`, `prompt_file_scaffold/1`, `known_agent_kinds/0`,
  plus `migrate_layout/1`/`parse_dotenv/1` which stay in `Aiur.Init`); the
  `defdelegate`s keep every return value byte-identical.

(No other `src/test/aiur/regression/` file from T-007..T-013 covers init.ex.)

## Acceptance criteria
Mechanically checkable (run from `src/` unless noted):

- The five modules exist at the exact paths: `test -f
  src/lib/aiur/init/{format,templates,questions,runtime,resume}.ex` all pass;
  each declares its module (`grep -l "defmodule Aiur.Init.Format" …` etc.).
- Each new module has a `@moduledoc` (`grep -c "@moduledoc"` ≥ 1 per file) and
  every public `def` has a preceding `@spec`.
- The moved private functions no longer exist in `init.ex`:
  `grep -E "defp (dim|dim_help|value_of|print_hint)\b" src/lib/aiur/init.ex`
  → no output; `grep -E "defp (prompt_location|prompt_tracker|prompt_agents|prompt_routing|prompt_permission_mode|prompt_int|prompt_max_turns|prompt_max_duration|normalize_int_or_none|routing_value|agent_kind_choices|primary_kind|agent_kinds|workspace_default)\b" src/lib/aiur/init.ex`
  → no output; `grep -E "defp (print_saved_summary|saved_summary_lines|alerts_summary_line|format_routing|tracker_from_config|agents_from_config|routing_backend|build_fills|fill_template|tracker_provider_block|routing_inline|prewarm_base_build_file_line|detect_toolchain|run_first_prewarm|load_config)\b" src/lib/aiur/init.ex`
  → no output.
- The template attributes left `init.ex`:
  `grep -E "@external_resource|@example_template|@aiurhooks_example_template|@alerts_(macos|linux)_example_template|@prompt_example_template|@env_example_content" src/lib/aiur/init.ex`
  → no output. Correspondingly `grep -c "@external_resource"
  src/lib/aiur/init/templates.ex` → 5, and `grep -c '\.\./\.\./\.\./\.\./\.aiur/examples'
  src/lib/aiur/init/templates.ex` → 5 (the new four-`../` depth).
- Facade intact: `grep -E "defdelegate (aiurhooks_template|alerts_template|prompt_file_template|prompt_file_scaffold|known_agent_kinds)" src/lib/aiur/init.ex`
  shows the delegates; `mix run -e 'IO.puts(Aiur.Init.prompt_file_scaffold("o/r"))'`
  prints scaffolded content with `o/r` filled.
- `init.ex` shrinks below **1,900** lines: `wc -l src/lib/aiur/init.ex` < 1900
  (was 2,253).
- Each new module file ≤ **200** lines: `wc -l
  src/lib/aiur/init/{format,templates,questions,runtime,resume}.ex` — every
  count ≤ 200. (Reviewer: each public function body ≤ ~20 logic lines,
  excluding literal data lists.)
- Every extracted module has a test file: `test -f
  src/test/aiur/init/{format,templates,questions,runtime,resume}_test.exs`. None
  of the five modules is added to `ignore_modules` in `src/mix.exs` (`grep -E
  "Aiur.Init.(Format|Templates|Questions|Runtime|Resume)" src/mix.exs` → no
  output); the 85% coverage threshold enforces the tests.
- The full Agent gate below passes.

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
- `mix test test/aiur/init_test.exs` — green, file diff shows ZERO changes to
  `init_test.exs`.
- `mix test test/aiur/regression/compile_time_paths_test.exs` — `2 tests, 0
  failures`; diff to that file is confined to the `@allowlist` map (the
  `aiur/init.ex` key replaced by `aiur/init/templates.ex` with `../../../../`
  paths); no `test`/`scan_hits` change.
- FI-WS-021 Check (compile-time embedding preserved): confirm no template read
  became runtime — `grep -rn "File.read" src/lib/aiur/init/templates.ex` shows
  only compile-time `File.read!` on `@…_path` attributes; a release build (or
  `MIX_ENV=prod mix compile`) embeds the templates (no runtime source
  dependency).
- FI-WS-020/FI-WS-018 behavior spot-check: `Aiur.Init.alerts_template({:unix,
  :darwin})` and `Aiur.Init.alerts_template({:unix, :linux})` return the same
  byte content as before this PR (macOS vs Linux bodies); a resume run's saved-
  selections summary (via `Init.run/3` in the existing tests) is unchanged.
- Confirm `git grep -n "Aiur.Init.Prompt" src/lib/aiur/init/prompt.ex` shows the
  Prompt module untouched (no accidental edits).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
