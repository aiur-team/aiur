# T-052: config/schema: per-section schema modules

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/config/schema.ex` is 1017 lines: one module holding a custom Ecto
type, 17 nested embedded-schema sections, the root parse pipeline, codex
sandbox-policy resolvers, agent-map normalizers/validators, the routing-value
grammar, raw-attrs preprocessing, env/secret resolution, and changeset error
formatting. It is hotspot row 7 in
`docs/refactor/research-history-hotspots.md` (~14 config-format incidents) and
carries invariant "never clobber existing config/env." The blessed decomposition
is specified verbatim in `docs/refactor/research-arch/giant-schema.md` — that
document is the binding name map for this ticket. Follow it exactly; do not
invent module names, paths, or a different split.

This is a **decomposition wave**: move code verbatim (extract, do not rewrite).
Public function signatures, default values, validations, error strings, and all
observable behavior stay identical. The parent module `Aiur.Config.Schema`
retains its root schema and delegates to the extracted modules so existing
callers keep working. Every genuinely-new module gets `@moduledoc`, `@spec` on
its public defs, and its own test file. After this ticket the repo compiles
clean and the full suite passes.

**T-021 baseline (read before you start).** T-021 (Phase 2, "Unify $VAR
resolution + codex validator dedup") ran earlier in the refactor and may have
already relocated or unified the env/secret/`$VAR` resolution helpers
(`resolve_secret_setting/2`, `resolve_path_value/2`, `resolve_env_value/2`,
`normalize_path_token/1`, `env_reference_name/1`, `resolve_env_token/1`,
`normalize_secret_value/1`) out of `schema.ex`. **Before doing anything, read the
current `src/lib/aiur/config/schema.ex` on your branch** — its line numbers will
have drifted from the numbers quoted in the research doc, and the env-resolution
functions may no longer live in this file. Treat the research doc's line ranges
as a map of *responsibilities*, not exact offsets: locate each function by name,
not by line number.

## Scope (exact)

Execute the split from `docs/refactor/research-arch/giant-schema.md` §2 (the
NAME MAP) and §3 (waves). Do the waves in order; the repo must compile and the
full suite must pass at the end. Every module/file name below must match the
research doc byte-for-byte.

**Step 0 — characterization backfill (no production moves).**
Create `src/test/aiur/config/schema_test.exs` pinning the currently-untested
behavior listed in giant-schema.md Wave 0: `$ENV` token grammar (`$NAME` valid /
invalid-name literal passthrough per FI-CFG-029/FI-CFG-035), secret resolution
(env set / empty-string env → nil / missing env → fallback, FI-CFG-025),
`workspace.root` `$VAR` and empty → tmp default (FI-CFG-035), multi-level
`format_errors` dotted flattening (FI-CFG-003), `StringOrMap` cast rejection
(FI-CFG-005), the direct `Polling` `interval_ms` `ArgumentError` raise
(FI-CFG-031), and smoke casts for the zero-coverage sections `Events`, `Hooks`,
`Worker`, `Observability`, `Server`, `Opencode`. Run `mix test` — green before
you move any code.
(If T-021 already relocated the env/secret helpers, pin those specific behaviors
against their current home module instead of `Schema`; keep the pins.)

**Step 1 — leaf plumbing modules (verbatim extract).**
Create and move the function bodies verbatim into:
1. `Aiur.Config.Schema.StringOrMap` → `src/lib/aiur/config/schema/string_or_map.ex`
   — `type/0`, `embed_as/1`, `equal?/2`, `cast/1`, `load/1`, `dump/1`.
2. `Aiur.Config.Schema.Errors` → `src/lib/aiur/config/schema/errors.ex`
   — `format_errors/1`, `flatten_errors/2`, `translate_error/1`,
   `error_value_to_string/1`.
3. `Aiur.Config.Schema.Attrs` → `src/lib/aiur/config/schema/attrs.ex`
   — `normalize_keys/1`, `normalize_optional_map/1`, `normalize_key/1`,
   `drop_nil_values/1`, `drop_nil_values/2`, `put_preserved_nil/3`,
   `preserve_nil_path?/1`.
4. `Aiur.Config.Schema.EnvResolver` → `src/lib/aiur/config/schema/env_resolver.ex`
   — `resolve_secret_setting/2`, `resolve_path_value/2`, `resolve_env_value/2`,
   `normalize_path_token/1`, `env_reference_name/1`, `resolve_env_token/1`,
   `normalize_secret_value/1`. **CONDITIONAL:** grep the current `schema.ex` for
   these functions first. If T-021 already moved them out of `schema.ex`, DO NOT
   create `env_resolver.ex` or its test — the functions already have a home; just
   make sure `finalize_settings/1` still calls them at their existing home. Only
   create this module if the functions still physically reside in `schema.ex`.

In `schema.ex`, add `alias` lines for the new modules and have `parse/1` /
`finalize_settings/1` / `changeset/1` call them. No public API changes; no
callers outside `schema.ex` change in this step.

**Step 2 — routing grammar + agent validators (moves + call-site updates).**
5. `Aiur.Config.RoutingValue` → `src/lib/aiur/config/routing_value.ex`
   — pure grammar of `backend[:model[:effort]][+remote]`, parsing only, no
   validation: `split_routing_value/1`, `routing_effort/1`,
   `routing_remote_flag?/1`, `routing_backend/1` (public here),
   `strip_remote_flag/1`.
6. `Aiur.Config.Schema.AgentValidation` → `src/lib/aiur/config/schema/agent_validation.ex`
   — `normalize_issue_state/1`, `normalize_state_limits/1`,
   `validate_state_limits/2`, `normalize_agent_routing/1`,
   `validate_agent_routing/2`, `routing_errors/4`,
   `invalid_routing_effort_error/2`, `valid_routing_effort?/1`,
   `routing_effort_backend/1`, `normalize_complexity_prompts/1`,
   `validate_complexity_prompts/2`, `normalize_routing_level/1`.
Delete these functions from `Schema` after moving. Update every external call
site (no `defdelegate` shims — one name per fact):
   - `src/lib/aiur/coding_agent.ex:205` `Schema.routing_effort` →
     `RoutingValue.routing_effort`.
   - `src/lib/aiur/coding_agent.ex:283,293` `Schema.split_routing_value` →
     `RoutingValue.split_routing_value`.
   - `src/lib/aiur/coding_agent.ex:307` `Schema.routing_remote_flag?` →
     `RoutingValue.routing_remote_flag?`. Also update the doc comment near
     `coding_agent.ex:132` if it names `Schema.split_routing_value`.
   - `src/lib/aiur/config.ex:67` `Schema.normalize_issue_state` →
     `AgentValidation.normalize_issue_state`.
   - The nested `Agent.changeset/2` validator calls (moved in Step 4) call
     `AgentValidation.*` instead of parent `Schema`.
   - In `src/test/aiur/workspace_and_config_test.exs`, swap the `Schema.<helper>`
     references for state-limits/routing/complexity assertions to the new module
     aliases. **Alias swap only** — do not change any assertion, expected value,
     or test name.
`AgentValidation` calls `RoutingValue`; `RoutingValue`/`AgentValidation` call
`Aiur.CodingAgent` (`known_backends/0`, `efforts/1`, `remote_control?/1`) at
**runtime only** — do not introduce any struct/macro compile-time dependency
across that edge (it would create a compile cycle; see giant-schema.md risk 9).

**Step 3 — small section schemas (verbatim move, names unchanged).**
Move each nested module to its own file, module name byte-identical, changeset
verbatim, keeping `@primary_key false`, `empty_values: []` on every cast, and
existing defaults:
   - `Aiur.Config.Schema.Polling` → `.../schema/polling.ex` (keep the
     `interval_ms` `ArgumentError` raise verbatim).
   - `Aiur.Config.Schema.Events` → `.../schema/events.ex`.
   - `Aiur.Config.Schema.Workspace` → `.../schema/workspace.ex` (keep the
     `Path.join(System.tmp_dir!(), "aiur_workspaces")` default expression
     verbatim).
   - `Aiur.Config.Schema.Worker` → `.../schema/worker.ex`.
   - `Aiur.Config.Schema.Hooks` → `.../schema/hooks.ex`.
   - `Aiur.Config.Schema.Prewarm` → `.../schema/prewarm.ex`.
   - `Aiur.Config.Schema.PrWatch` → `.../schema/pr_watch.ex`.
   - `Aiur.Config.Schema.Alerts` → `.../schema/alerts.ex` (keep its public
     `@type t`).
   - `Aiur.Config.Schema.Observability` → `.../schema/observability.ex`.
   - `Aiur.Config.Schema.Server` → `.../schema/server.ex`.
   - `Aiur.Config.Schema.Opencode` → `.../schema/opencode.ex`.
Add the corresponding `alias` list to `schema.ex` so its root `cast_embed` /
`embeds_one` captures still resolve.

**Step 4 — tracker + agent families (verbatim move).**
   - `Aiur.Config.Schema.Tracker` → `src/lib/aiur/config/schema/tracker.ex`,
     co-locating its leaf embeds `Aiur.Config.Schema.Github` and
     `Aiur.Config.Schema.Linear` in the same file (mirrors the current
     single-file precedent, file stays under 200 lines).
   - `Aiur.Config.Schema.Agent` → `src/lib/aiur/config/schema/agent.ex`,
     co-locating `Aiur.Config.Schema.Claude` and `Aiur.Config.Schema.Codex`;
     move `Agent.changeset/2`, `drop_uncapped_max_turns/1`,
     `drop_key_if_uncapped/2`, `uncapped_max_turns?/1` verbatim. `Agent` now
     depends only on `AgentValidation` / `Claude` / `Codex` / `StringOrMap` —
     confirm the old child→parent back-reference to `Schema` is gone.
After this step the residual `schema.ex` holds only: the root
`embedded_schema` (13 `embeds_one`), `parse/1`, `changeset/1`,
`finalize_settings/1`, and the three sandbox resolvers
`resolve_turn_sandbox_policy/2`, `resolve_runtime_turn_sandbox_policy/3`,
`effective_turn_sandbox_policy/1` — plus its alias list. These three resolvers
and `finalize_settings/1` **stay in `Schema`** (deliberate non-moves).

**Documentation/spec requirements for every NEW module** (Errors, Attrs,
EnvResolver-if-created, RoutingValue, AgentValidation): a one-line descriptive
`@moduledoc` (not `@moduledoc false`) and `@spec` on every public def. Relocated
section modules and `StringOrMap` keep their existing `@moduledoc false`
verbatim (preserving current behavior — do not "upgrade" them).

## Files
- Create:
  - `src/lib/aiur/config/schema/string_or_map.ex`
  - `src/lib/aiur/config/schema/errors.ex`
  - `src/lib/aiur/config/schema/attrs.ex`
  - `src/lib/aiur/config/schema/env_resolver.ex` *(only if the env helpers still live in `schema.ex`; see Step 1.4)*
  - `src/lib/aiur/config/routing_value.ex`
  - `src/lib/aiur/config/schema/agent_validation.ex`
  - `src/lib/aiur/config/schema/tracker.ex`
  - `src/lib/aiur/config/schema/agent.ex`
  - `src/lib/aiur/config/schema/polling.ex`
  - `src/lib/aiur/config/schema/events.ex`
  - `src/lib/aiur/config/schema/workspace.ex`
  - `src/lib/aiur/config/schema/worker.ex`
  - `src/lib/aiur/config/schema/hooks.ex`
  - `src/lib/aiur/config/schema/prewarm.ex`
  - `src/lib/aiur/config/schema/pr_watch.ex`
  - `src/lib/aiur/config/schema/alerts.ex`
  - `src/lib/aiur/config/schema/observability.ex`
  - `src/lib/aiur/config/schema/server.ex`
  - `src/lib/aiur/config/schema/opencode.ex`
- Modify:
  - `src/lib/aiur/config/schema.ex`
  - `src/lib/aiur/coding_agent.ex` *(routing-call module swaps only)*
  - `src/lib/aiur/config.ex` *(line 67 `normalize_issue_state` module swap only)*
- Test:
  - `src/test/aiur/config/schema_test.exs` *(new — Wave 0 backfill + section smoke casts)*
  - `src/test/aiur/config/schema/errors_test.exs` *(new)*
  - `src/test/aiur/config/schema/attrs_test.exs` *(new)*
  - `src/test/aiur/config/schema/env_resolver_test.exs` *(new — only if `env_resolver.ex` is created)*
  - `src/test/aiur/config/routing_value_test.exs` *(new)*
  - `src/test/aiur/config/schema/agent_validation_test.exs` *(new)*
  - `src/test/aiur/workspace_and_config_test.exs` *(modify — alias swaps only)*

## Out of scope
- `src/lib/aiur/config/codex_sandbox_policy.ex` and the sandbox-resolution
  behavior it owns (FI-CFG-064, FI-CFG-065, FI-CFG-066). The three thin sandbox
  resolvers stay in `schema.ex`; do not move sandbox logic into or out of that
  module.
- `src/lib/aiur/config/paths.ex` and `src/config/config.exs`
  (FI-CFG-098–FI-CFG-104). Do not touch.
- The duplicate private `normalize_issue_state` reimplementations in
  `orchestrator.ex`, `agent_runner.ex`, `workspace.ex`, `test_reset.ex` — do NOT
  consolidate them here (flagged for a later ticket).
- The duplicate codex approval-policy validator in `Aiur.Codex.Config`
  (FI-CFG-060) — T-021's concern, not this ticket.
- `src/mix.exs` coverage `ignore_modules` — no edits. `Aiur.Config.Schema.Events`
  keeps its exact name, so it stays exempt where it already is; do not add or
  remove entries.
- `src/lib/aiur/alerts.ex` (`alias Aiur.Config.Schema.Alerts`) and
  `src/lib/aiur/workflow.ex` (`hooks_file` / `base_build_file` / `alerts_file`
  indirection, FI-CFG-007/077/085) — names/behavior preserved, no edits needed.
- Any change to a default value, validation rule, error string, or public
  function signature. Verbatim moves only.

## Inventory-IDs
Schema fields, pipeline, and helpers implemented in the touched files
(`src/lib/aiur/config/schema.ex` and everything extracted from it): **FI-CFG-003,
FI-CFG-004, FI-CFG-005, FI-CFG-009, FI-CFG-010, FI-CFG-011, FI-CFG-012,
FI-CFG-014, FI-CFG-015, FI-CFG-018, FI-CFG-019, FI-CFG-020, FI-CFG-021,
FI-CFG-022, FI-CFG-023, FI-CFG-024, FI-CFG-025, FI-CFG-026, FI-CFG-027,
FI-CFG-028, FI-CFG-029, FI-CFG-030, FI-CFG-031, FI-CFG-032, FI-CFG-033,
FI-CFG-034, FI-CFG-035, FI-CFG-036, FI-CFG-037, FI-CFG-038, FI-CFG-039,
FI-CFG-040, FI-CFG-041, FI-CFG-042, FI-CFG-043, FI-CFG-044, FI-CFG-045,
FI-CFG-046, FI-CFG-047, FI-CFG-048, FI-CFG-049, FI-CFG-050, FI-CFG-051,
FI-CFG-052, FI-CFG-053, FI-CFG-054, FI-CFG-055, FI-CFG-056, FI-CFG-057,
FI-CFG-058, FI-CFG-059, FI-CFG-060, FI-CFG-061, FI-CFG-062, FI-CFG-067,
FI-CFG-068, FI-CFG-069, FI-CFG-070, FI-CFG-071, FI-CFG-072, FI-CFG-073,
FI-CFG-074, FI-CFG-075, FI-CFG-076, FI-CFG-077, FI-CFG-078, FI-CFG-079,
FI-CFG-080, FI-CFG-081, FI-CFG-082, FI-CFG-083, FI-CFG-084, FI-CFG-085,
FI-CFG-086, FI-CFG-087, FI-CFG-088, FI-CFG-089, FI-CFG-090, FI-CFG-091,
FI-CFG-092, FI-CFG-093, FI-CFG-094, FI-CFG-095, FI-CFG-096, FI-CFG-097.**

PRESERVED-EXACTLY (must survive byte-for-byte — do not paraphrase, reorder, or
"clean up"): **FI-CFG-054** (`preserve_nil_path?(["agent","max_load_average"])`
null-disable of the #465 load gate — the single most refactor-fragile line;
moves into `Attrs` unchanged), **FI-CFG-048** (`agent.max_turns`
`none`/`unlimited`/`""` pre-cast key drop → nil), **FI-CFG-045 / FI-CFG-046**
(routing grammar validation + parsing, including `claude+remote` validated
against the `claude-repl` transport and unknown-backend-before-effort error
precedence), **FI-CFG-031** (`polling.interval_ms` `ArgumentError` raise, not a
changeset error).

## Characterization-tests
None under `src/test/aiur/regression/` — that directory protects TUI/pane/warm
lifecycle behavior, not config parsing. The config-schema anti-regression net is
the standard suite: `src/test/aiur/workspace_and_config_test.exs` (state limits,
routing grammar/validation, complexity prompts, `max_load_average`
null-preservation, turn-sandbox resolution), `src/test/aiur/core_test.exs`
(parse defaults, `{:invalid_workflow_config, message}` formats, `LINEAR_API_KEY`
fallback), `src/test/aiur/codex/config_test.exs` (approval-policy default shape),
`src/test/aiur/config/pr_watch_test.exs` (PrWatch defaults/validation), and
`src/test/aiur/log_file_test.exs:277` (legacy `interval_ms` raise at boot). All
must stay green; treat them as immovable pins.

## Acceptance criteria
Mechanically checkable:
- Every file listed under **Create** exists and each is `<= 200` lines
  (`wc -l`). Verbatim moves keep individual moved function bodies at their
  existing length — do not rewrite a moved function to shorten it.
- Each new logic module has a descriptive `@moduledoc` (not `false`) and `@spec`
  on every public def:
  `grep -L "@moduledoc \"" src/lib/aiur/config/schema/errors.ex src/lib/aiur/config/schema/attrs.ex src/lib/aiur/config/routing_value.ex src/lib/aiur/config/schema/agent_validation.ex`
  returns nothing (and `env_resolver.ex` too, if created).
- Every new module has its own test file (the paths under **Test** above exist);
  `mix test` exercises them.
- Module names preserved exactly:
  `grep -rl "defmodule Aiur.Config.Schema.Events" src/lib` and the same for
  `.Alerts`, `.Codex`, `.Agent`, `.Workspace`, `.StringOrMap`, `.Polling`,
  `.Tracker`, `.Github`, `.Linear` each resolve to a file.
- Residual `schema.ex` still defines `parse/1`, `changeset/1`,
  `finalize_settings/1`, `resolve_turn_sandbox_policy/2`,
  `resolve_runtime_turn_sandbox_policy/3`, `effective_turn_sandbox_policy/1`
  (`grep -n "def parse\|defp changeset\|defp finalize_settings\|def resolve_turn_sandbox_policy\|def resolve_runtime_turn_sandbox_policy\|defp effective_turn_sandbox_policy" src/lib/aiur/config/schema.ex`).
- PRESERVED-EXACTLY probes:
  - `grep -rn 'preserve_nil_path?(\["agent", "max_load_average"\])' src/lib/aiur/config/schema/attrs.ex` matches (the literal path is intact and now lives in `Attrs`).
  - `grep -rn "interval_ms is no longer supported" src/lib/aiur/config/schema/polling.ex` matches (raise moved verbatim into `Polling`).
  - `grep -rn "none\|unlimited" src/lib/aiur/config/schema/agent.ex` shows the pre-cast `max_turns` drop logic present in `Agent`.
- Routing callers updated, no stale references:
  `grep -rn "Schema.split_routing_value\|Schema.routing_effort\|Schema.routing_remote_flag?\|Schema.normalize_issue_state" src/lib` returns nothing (all now `RoutingValue.*` / `AgentValidation.*`).
- `empty_values: []` still present on every moved `cast`/`cast_embed`:
  `grep -rc "empty_values: \[\]" src/lib/aiur/config/schema*` count is unchanged from HEAD before the split.
- No `defdelegate` shim was added for the moved functions
  (`grep -rn "defdelegate" src/lib/aiur/config/schema.ex` returns nothing new).
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
- Diff is move-only: `git log -p` for the moved functions shows identical bodies
  (an interdiff of deleted-from-`schema.ex` vs added-in-new-file is empty apart
  from indentation/module wrapper). No default, validation, or error string
  changed.
- Check (FI-CFG-054): a scratch config with `agent: {max_load_average: null}`
  (explicit YAML null) parses with the gate disabled — the null survives
  `drop_nil_values`; a config omitting the key keeps the 1.5 default.
- Check (FI-CFG-031): `polling: {interval_ms: 1000}` makes `Schema.parse` raise
  `ArgumentError` naming `interval_seconds` (not a changeset error).
- Check (FI-CFG-048): `agent: {max_turns: "none"}` parses to `nil` (uncapped),
  not a boot failure.
- Check (FI-CFG-045/046): routing values `codex::high`, `claude+remote`, and an
  unknown backend produce the same accept/reject and the same error precedence
  (unknown-backend before invalid-effort) as before the split.
- Check (FI-CFG-005): `agent.codex.approval_policy` still defaults to the string
  `"untrusted"` (not a map) via `StringOrMap`.
- `mix.exs` coverage `ignore_modules` unchanged; no new module is coverage-exempt.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
