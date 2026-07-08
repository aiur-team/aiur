# Decomposition: `src/lib/aiur/config/schema.ex` (1017 lines)

Behavior-preserving split of `Aiur.Config.Schema` for the production-readiness refactor.
Repo root: `/home/orangekid/github/aiur`. All paths below are repo-relative unless absolute.

Verdict up front: this file is a legitimate candidate for the blessed "per-section schema
module" split, plus four small plumbing extractions (routing grammar, agent-map validators,
attrs preprocessing, env/secret resolution, error formatting). No process/ETS/GenServer state
lives here — the risk profile is *semantic drift in pure functions*, not concurrency. All
existing module names are preserved verbatim (they are load-bearing: tests build
`%Schema.Agent{}` / `%Schema.Codex{}` / `%Schema.Workspace{}`, `mix.exs` names
`Aiur.Config.Schema.Events` in the coverage ignore list, `alerts.ex` aliases
`Aiur.Config.Schema.Alerts`).

---

## 1. Function / responsibility census

Line numbers refer to the current file.

### A. Custom Ecto type (25 lines)
| Function | Lines | Size |
|---|---|---|
| `StringOrMap` module: `type/0`, `embed_as/1`, `equal?/2`, `cast/1`, `load/1`, `dump/1` | 14–38 | 25 |

Used by `Codex.approval_policy` field; aliased directly by
`src/test/aiur/workspace_and_config_test.exs:5`.

### B. Section embedded schemas (17 nested modules, lines 40–551, ~512 lines)
| Module | Lines | Size | Notes |
|---|---|---|---|
| `Github` | 40–57 | 18 | leaf embed of Tracker |
| `Linear` | 59–76 | 18 | leaf embed of Tracker |
| `Tracker` | 78–105 | 28 | embeds Github + Linear |
| `Polling` | 107–129 | 23 | **raises ArgumentError** on legacy `interval_ms` key |
| `Events` | 131–155 | 25 | zero-coverage; named in `src/mix.exs:117` coverage ignore |
| `Workspace` | 157–175 | 19 | default root uses `System.tmp_dir!()` at compile time |
| `Worker` | 177–194 | 18 | |
| `Codex` | 196–240 | 45 | uses `StringOrMap`; fail-closed `approval_policy: "untrusted"` |
| `Claude` | 242–260 | 19 | |
| `Agent` | 262–367 | 106 | embeds Claude + Codex; calls 6 parent-`Schema` validators; `drop_uncapped_max_turns/1`, `drop_key_if_uncapped/2`, `uncapped_max_turns?/1` (350–366) |
| `Hooks` | 369–389 | 21 | |
| `Prewarm` | 391–414 | 24 | |
| `PrWatch` | 416–443 | 28 | |
| `Alerts` | 445–476 | 32 | only section with a public `@type t`; aliased by `src/lib/aiur/alerts.ex:11` |
| `Observability` | 478–501 | 24 | |
| `Server` | 503–524 | 22 | |
| `Opencode` | 526–551 | 26 | |

### C. Root schema + parse pipeline (~96 lines)
| Function | Lines | Size |
|---|---|---|
| root `embedded_schema` (13 `embeds_one`) | 553–573 | 21 |
| `parse/1` (public entrypoint) | 575–589 | 15 |
| `changeset/1` (private, casts root + 13 embeds) | 809–832 | 24 |
| `finalize_settings/1` (env/secret/path resolution + codex map normalization) | 834–869 | 36 |

### D. Codex sandbox-policy resolution (~29 lines)
| Function | Lines | Size |
|---|---|---|
| `resolve_turn_sandbox_policy/2` (public) | 591–598 | 8 |
| `resolve_runtime_turn_sandbox_policy/3` (public; used by `config.ex:322,394`) | 600–609 | 10 |
| `effective_turn_sandbox_policy/1` (danger-full-access thread → dangerFullAccess turn) | 611–619 | 9 |

Thin adapters over `Aiur.Config.CodexSandboxPolicy` — cohesive with the root settings
struct; they stay in `Schema`.

### E. Issue-state + agent-map normalization/validation (~187 lines)
| Function | Lines | Size | External callers |
|---|---|---|---|
| `normalize_issue_state/1` (public) | 621–624 | 4 | `config.ex:67` |
| `normalize_state_limits/1` (public `@doc false`) | 626–634 | 9 | Agent.changeset, tests |
| `validate_state_limits/2` (public `@doc false`) | 636–653 | 18 | Agent.changeset, tests |
| `normalize_agent_routing/1` | 655–663 | 9 | Agent.changeset, tests |
| `validate_agent_routing/2` | 665–675 | 11 | Agent.changeset, tests; calls `Aiur.CodingAgent.known_backends/0` |
| `routing_errors/4` | 677–696 | 20 | calls `CodingAgent.remote_control?/1` |
| `invalid_routing_effort_error/2` | 698–706 | 9 | calls `CodingAgent.efforts/1` |
| `valid_routing_effort?/1` | 708–719 | 12 | |
| `routing_effort_backend/1` (`claude`+remote → `claude-repl`) | 721–726 | 6 | |
| `split_routing_value/1` (public, documented) | 728–743 | 16 | `coding_agent.ex:283,293`, tests |
| `routing_effort/1` (public, documented) | 745–758 | 14 | `coding_agent.ex:205`, tests |
| `routing_remote_flag?/1` (public) | 760–762 | 3 | `coding_agent.ex:307`, tests |
| `strip_remote_flag/1` | 764 | 1 | |
| `routing_backend/1` | 766–767 | 2 | |
| `normalize_complexity_prompts/1` | 769–777 | 9 | Agent.changeset, tests |
| `validate_complexity_prompts/2` | 779–796 | 18 | Agent.changeset, tests |
| `normalize_routing_level/1` | 798–807 | 10 | shared by routing + prompts normalizers |

Two distinct concerns hiding here: (1) the pure **routing-value grammar**
`backend[:model[:effort]][+remote]` consumed at dispatch time by `Aiur.CodingAgent`,
and (2) **changeset validators for the agent section's map fields**. Split accordingly.

### F. Raw-attrs preprocessing (~46 lines)
| Function | Lines | Size |
|---|---|---|
| `normalize_keys/1` (deep key stringification) | 871–878 | 8 |
| `normalize_optional_map/1` | 880–881 | 2 |
| `normalize_key/1` | 883–884 | 2 |
| `drop_nil_values/1,2` | 886–905 | 20 |
| `put_preserved_nil/3` | 907–909 | 3 |
| `preserve_nil_path?/1` (**preserves explicit `agent.max_load_average: null`**) | 911–916 | 6 |

### G. Env / secret / path resolution (~65 lines)
| Function | Lines | Size |
|---|---|---|
| `resolve_secret_setting/2` (value or `$ENV` ref, env fallback, `""`→nil) | 918–925 | 8 |
| `resolve_path_value/2` (`$ENV` path token, missing/`""` → default) | 927–938 | 12 |
| `resolve_env_value/2` | 940–952 | 13 |
| `normalize_path_token/1` | 954–959 | 6 |
| `env_reference_name/1` (`$NAME` grammar regex; invalid → literal passthrough) | 961–969 | 9 |
| `resolve_env_token/1` | 971–976 | 6 |
| `normalize_secret_value/1` | 978–982 | 5 |

### H. Changeset error formatting (~33 lines)
| Function | Lines | Size |
|---|---|---|
| `format_errors/1` (→ `"section.field message, ..."`) | 984–989 | 6 |
| `flatten_errors/2` (dotted-path prefixing) | 991–1007 | 17 |
| `translate_error/1` | 1009–1013 | 5 |
| `error_value_to_string/1` | 1015–1016 | 2 |

---

## 2. Proposed module split (NAME MAP — the contract)

Conventions honored: everything stays under `Aiur.Config.*` (siblings
`Aiur.Config.CodexSandboxPolicy`, `Aiur.Config.Paths` already exist). Every existing
module name is kept byte-identical; only *new* modules get new names. Public function
names are kept identical across moves (grep-stable, mechanical diffs); private helpers
that become public keep their current names too. Strictly-subordinate leaf embeds are
co-located with their parent section file (mirrors the current single-file precedent
while keeping each file well under 200 lines).

### Retained (shrunk)
| Module | Path | Responsibility | ~LOC |
|---|---|---|---|
| `Aiur.Config.Schema` | `src/lib/aiur/config/schema.ex` | Root embedded settings struct: 13 `embeds_one` sections, `parse/1` entrypoint, top-level `changeset/1`, `finalize_settings/1`, and the two codex sandbox-policy resolvers (`resolve_turn_sandbox_policy/2`, `resolve_runtime_turn_sandbox_policy/3`, `effective_turn_sandbox_policy/1`). | ~160 |

### New modules
| # | Module | Path (`src/lib/…`) | Responsibility | ~LOC | Key functions moved |
|---|---|---|---|---|---|
| 1 | `Aiur.Config.Schema.StringOrMap` | `aiur/config/schema/string_or_map.ex` | Ecto.Type accepting a bare string or a map (codex `approval_policy`). | 30 | `type/0`, `embed_as/1`, `equal?/2`, `cast/1`, `load/1`, `dump/1` |
| 2 | `Aiur.Config.Schema.Errors` | `aiur/config/schema/errors.ex` | Flatten a settings changeset's nested errors into the dotted `"section.field message, …"` string carried by `{:invalid_workflow_config, msg}`. | 45 | `format_errors/1`, `flatten_errors/2`, `translate_error/1`, `error_value_to_string/1` |
| 3 | `Aiur.Config.Schema.Attrs` | `aiur/config/schema/attrs.ex` | Pre-cast raw-config preprocessing: deep key stringification and nil-dropping with the preserved-null path for `agent.max_load_average`. | 60 | `normalize_keys/1`, `normalize_optional_map/1`, `normalize_key/1`, `drop_nil_values/1,2`, `put_preserved_nil/3`, `preserve_nil_path?/1` |
| 4 | `Aiur.Config.Schema.EnvResolver` | `aiur/config/schema/env_resolver.ex` | Post-cast value resolution: `$ENV` reference grammar, secret env fallbacks (`""` → nil), path tokens with defaults. | 70 | `resolve_secret_setting/2`, `resolve_path_value/2`, `resolve_env_value/2`, `normalize_path_token/1`, `env_reference_name/1`, `resolve_env_token/1`, `normalize_secret_value/1` |
| 5 | `Aiur.Config.RoutingValue` | `aiur/config/routing_value.ex` | Pure grammar of a routing value `backend[:model[:effort]][+remote]` — parsing only, no validation; shared by dispatch (`Aiur.CodingAgent`) and config validation. | 75 | `split_routing_value/1`, `routing_effort/1`, `routing_remote_flag?/1`, `routing_backend/1` (public here), `strip_remote_flag/1` |
| 6 | `Aiur.Config.Schema.AgentValidation` | `aiur/config/schema/agent_validation.ex` | Normalizers + changeset validators for the agent section's map fields (state limits, complexity routing, complexity prompts) and `normalize_issue_state/1`. | 135 | `normalize_issue_state/1`, `normalize_state_limits/1`, `validate_state_limits/2`, `normalize_agent_routing/1`, `validate_agent_routing/2`, `routing_errors/4`, `invalid_routing_effort_error/2`, `valid_routing_effort?/1`, `routing_effort_backend/1`, `normalize_complexity_prompts/1`, `validate_complexity_prompts/2`, `normalize_routing_level/1` |
| 7 | `Aiur.Config.Schema.Tracker` (co-located: `Aiur.Config.Schema.Github`, `Aiur.Config.Schema.Linear`) | `aiur/config/schema/tracker.ex` | Tracker section: kind, base branch, active/terminal states, plus the github/linear sub-schemas it embeds. | 75 | `Tracker.changeset/2`, `Github.changeset/2`, `Linear.changeset/2` |
| 8 | `Aiur.Config.Schema.Agent` (co-located: `Aiur.Config.Schema.Claude`, `Aiur.Config.Schema.Codex`) | `aiur/config/schema/agent.ex` | Agent section: backend kind, RC opt-in flag, concurrency/turn/retry/duration caps, load gate, routing + complexity-prompt maps, plus the claude/codex backend sub-schemas. | 185 | `Agent.changeset/2`, `drop_uncapped_max_turns/1`, `drop_key_if_uncapped/2`, `uncapped_max_turns?/1`, `Claude.changeset/2`, `Codex.changeset/2` |
| 9 | `Aiur.Config.Schema.Polling` | `aiur/config/schema/polling.ex` | Polling interval section, including the verbatim `ArgumentError` raise on the legacy `interval_ms` key. | 30 | `changeset/2` |
| 10 | `Aiur.Config.Schema.Events` | `aiur/config/schema/events.ex` | Event debounce / per-turn custom-event / CODEOWNERS-refresh limits. | 30 | `changeset/2` |
| 11 | `Aiur.Config.Schema.Workspace` | `aiur/config/schema/workspace.ex` | Workspace root + bootstrap image settings. | 25 | `changeset/2` |
| 12 | `Aiur.Config.Schema.Worker` | `aiur/config/schema/worker.ex` | SSH worker hosts + per-host concurrency cap. | 25 | `changeset/2` |
| 13 | `Aiur.Config.Schema.Hooks` | `aiur/config/schema/hooks.ex` | Workspace lifecycle hook commands + timeout. | 25 | `changeset/2` |
| 14 | `Aiur.Config.Schema.Prewarm` | `aiur/config/schema/prewarm.ex` | Warm-base build (base_build / base_build_file / poll cadence). | 30 | `changeset/2` |
| 15 | `Aiur.Config.Schema.PrWatch` | `aiur/config/schema/pr_watch.ex` | Opt-in PR comment watching (watch label, command prefix). | 35 | `changeset/2` |
| 16 | `Aiur.Config.Schema.Alerts` | `aiur/config/schema/alerts.ex` | Alert-sound configuration (enabled, OS-default sounds, sound dir, alerts file); keeps its public `@type t`. | 40 | `changeset/2` |
| 17 | `Aiur.Config.Schema.Observability` | `aiur/config/schema/observability.ex` | Dashboard enable/writable flags + refresh/render cadence. | 30 | `changeset/2` |
| 18 | `Aiur.Config.Schema.Server` | `aiur/config/schema/server.ex` | Dashboard bind host/port (port 0 = free loopback port; required for RC transcript hook). | 30 | `changeset/2` |
| 19 | `Aiur.Config.Schema.Opencode` | `aiur/config/schema/opencode.ex` | Opencode bridge command/host/port/model-prefix/prewarm settings. | 35 | `changeset/2` |

Total after split: ~1,200 LOC across 20 files (growth is per-file `use`/`import`/moduledoc
boilerplate). Largest file (`agent.ex`) ~185 LOC; residual `schema.ex` ~160 LOC.

Dependency direction after the split (one-way, per house style):
`Schema` (root) → section modules → `AgentValidation` → `RoutingValue` / `Aiur.CodingAgent`.
This *removes* today's child→parent back-reference (`Agent` aliasing parent `Schema` for
validators). The `Schema`↔`Aiur.CodingAgent` mutual dependency shrinks to
`AgentValidation`↔`CodingAgent` and stays runtime-only (function calls, no struct/macro
compile-time deps) — do not introduce compile-time coupling across it.

Deliberate non-moves:
- Sandbox resolvers stay in `Schema` (they read the whole settings struct; the real logic
  already lives in `Aiur.Config.CodexSandboxPolicy`).
- `finalize_settings/1` stays in `Schema` (it knows the settings shape; delegates value
  work to `EnvResolver`/`Attrs`).
- No `defdelegate` shims: the handful of external call sites
  (`coding_agent.ex:205,283,293,307` + comment at 132; `config.ex:67`; test call sites)
  are updated in the same wave that moves their target. One name per fact.
- Observed duplication, out of scope: `normalize_issue_state/1` is privately reimplemented
  in `orchestrator.ex:3687`, `agent_runner.ex:1970`, `workspace.ex:568`,
  `test_reset.ex:418`. Flag for a later consolidation ticket; do not touch here.

---

## 3. Extraction sequencing (waves, strictly serialized on this file)

Every wave ends with `mix compile --warnings-as-errors` + full `mix test` green
(minimum pinning suites: `workspace_and_config_test.exs`, `core_test.exs`,
`codex/config_test.exs`, `config/pr_watch_test.exs`, `log_file_test.exs`), plus
`make fmt-check && make lint` per repo CI convention. Each wave is one ticket, ≤400
moved lines.

**Wave 0 — characterization backfill (no production code moves).**
Add missing pins *before* moving the code they cover (all currently untested directly):
`$ENV` token grammar (`$NAME` valid / invalid-name literal passthrough), secret resolution
(env set / empty-string env → nil / missing env → fallback), `workspace.root` `$VAR` and
empty → tmp default, `format_errors` multi-level dotted flattening, `StringOrMap` cast
rejection, direct `Polling` `interval_ms` raise, and smoke casts for the zero-coverage
sections (`Events`, `Hooks`, `Worker`, `Observability`, `Server`, `Opencode`).
New file: `src/test/aiur/config/schema_test.exs`. ~150 test lines added, 0 moved.

**Wave 1 — leaf plumbing out (~170 lines moved).**
Extract `StringOrMap`, `Errors`, `Attrs`, `EnvResolver` into their files; `schema.ex`
gains aliases and `parse/1`/`finalize_settings/1` call the new modules. No public API
changes; no callers outside this file change (test alias
`Aiur.Config.Schema.StringOrMap` resolves unchanged).

**Wave 2 — routing grammar + agent validators (~190 lines moved + mechanical call-site
updates).** Create `Aiur.Config.RoutingValue` and `Aiur.Config.Schema.AgentValidation`;
delete those functions from `Schema`. Update: nested `Agent.changeset/2` (6 validator
call sites), `coding_agent.ex` (4 call sites + doc comment at line 132),
`config.ex:67` (`normalize_issue_state`), and the `Schema.<helper>` assertions in
`workspace_and_config_test.exs` (~lines 1860–2210, alias swap only). The only wave that
touches external call sites — keep it single-purpose.

**Wave 3 — small section schemas (~370 lines moved).**
Move `Polling`, `Events`, `Workspace`, `Worker`, `Hooks`, `Prewarm`, `PrWatch`, `Alerts`,
`Observability`, `Server`, `Opencode` to per-section files; module names unchanged, so
`mix.exs:117` (Events coverage ignore) and `alerts.ex:11` (Alerts alias) need no edits.
`schema.ex` adds the alias list for its `cast_embed` captures.

**Wave 4 — tracker + agent families (~260 lines moved).**
Move `Tracker`(+`Github`,`Linear`) and `Agent`(+`Claude`,`Codex`) out. Verify `Agent` now
depends only on `AgentValidation`/`Claude`/`Codex`/`StringOrMap` (no parent back-ref).
Residual `schema.ex` ≈160 lines: root schema, `parse/1`, `changeset/1`,
`finalize_settings/1`, sandbox resolvers.

**Wave 5 (optional, non-blocking test hygiene).** Carve the schema unit tests out of
`workspace_and_config_test.exs` (~lines 1860–2330) into
`test/aiur/config/schema_test.exs` / `agent_validation_test.exs` so the pinning tests
live next to the modules they pin. Pure test move; can be dropped if the refactor
budget is tight.

---

## 4. Risks and preserved semantics

**Hotspot context.** `config/schema.ex` sits in hotspot row 7 of
`/home/orangekid/github/aiur/docs/refactor/research-history-hotspots.md` (~14 incidents:
config-format churn #238→#244→#333; `.aiur/` layout moves breaking compile-time paths;
init clobbering configs #649/#724), and invariant item 11 pins "never-clobber existing
config/env" behavior for this seam. The per-section split reduces future churn blast
radius, but every move below must be byte-semantics-preserving.

**No concurrency/state in-file** — `parse/1` is pure except for `System.get_env/1` and
`System.tmp_dir!/0`. The timing semantics that must survive verbatim:

1. **Env reads happen at parse time, per parse**, inside `finalize_settings/1`
   (`LINEAR_API_KEY`, `LINEAR_ASSIGNEE`, `$ENV` tokens). `Aiur.Config.settings/0` caches
   via `WorkflowStore` while `settings_uncached/0` deliberately re-reads
   (`config.ex:39–45`, boot-time `LogFile` determinism). `EnvResolver` must not memoize
   or hoist env reads to compile/boot time.
2. **`preserve_nil_path?(["agent", "max_load_average"])`** — an explicit YAML `null` is
   the *only* way to disable the #465 dispatch load gate; dropping it re-enables the 1.5
   default silently. The path literal is coupled to the Agent field's location — Wave 3/4
   must not change the string path, and Wave 1 moves this into `Attrs` unchanged
   (pinned: `workspace_and_config_test.exs:2057–2086`).
3. **`Polling.changeset/2` raises `ArgumentError`** (not a changeset error) on legacy
   `interval_ms`; the boot path depends on `Schema.parse` raising
   (`log_file.ex:102`, `log_file_test.exs:277`).
4. **Codex fail-closed default** `approval_policy: "untrusted"` as a *string* via
   `StringOrMap` (a map default crashed turns) — pinned by
   `codex/config_test.exs` (`%Schema.Codex{}.approval_policy`).
5. **Routing grammar edge cases**: `+remote` stripped before `:`-split; effort-only
   `"codex::high"`; `claude+remote` effort validated against the `"claude-repl"`
   transport (`routing_effort_backend/1`); unknown-backend check runs before effort
   check in the `cond` (error precedence is observable). Pinned:
   `workspace_and_config_test.exs:1883–1992`.
6. **Error-string format** `"section.field message, …"` — `core_test.exs:68–137` asserts
   substrings like `"polling.interval_seconds"`; `Errors` must keep dotted-path
   prefixing and `", "` joining exactly.
7. **Module names are behavior**: `mix.exs:117` coverage-ignore names
   `Aiur.Config.Schema.Events`; `alerts.ex:11` aliases `Schema.Alerts`; tests construct
   `%Schema.Agent{}`, `%Schema.Workspace{}`, `%Schema.Codex{}`, alias `StringOrMap`.
   All names preserved by this plan; any rename would be a silent contract break.
8. **`Workspace` default root** `Path.join(System.tmp_dir!(), "aiur_workspaces")` is
   evaluated at *compile time* of the field default; moving the module re-evaluates at
   the new file's compile — same semantics, but keep the expression verbatim
   (`test_reset.ex:592` mirrors it).
9. **Runtime-only cycle** `AgentValidation`/`RoutingValue` ↔ `Aiur.CodingAgent`
   (`known_backends/0`, `efforts/1`, `remote_control?/1` one way; routing-value parsing
   the other). It is runtime-only today; introducing a struct/macro compile-time
   dependency across it would create a compile cycle.
10. **Ecto embed mechanics**: every `embeds_one(..., defaults_to_struct: true)` requires
    the embedded module's struct — after the split `schema.ex` has compile-time deps on
    all section files (fine, one direction). `empty_values: []` on every `cast` is
    load-bearing (empty strings are cast, then handled by `normalize_secret_value`);
    keep it on every moved changeset.

**Existing pins (what will catch a bad move):**
- `src/test/aiur/workspace_and_config_test.exs` (~lines 1860–2330): state limits,
  routing grammar + validation errors, complexity prompts, `max_log_history_mb`,
  `max_load_average` null-preservation, `synthetic_load_process_cap`,
  `prewarm.poll_seconds`, `debug`, `max_agent_duration_minutes`, `remote_control`,
  turn-sandbox resolution against `%Schema{}` structs.
- `src/test/aiur/core_test.exs`: parse defaults, `{:invalid_workflow_config, message}`
  formats, `LINEAR_API_KEY` env fallback (line 217).
- `src/test/aiur/codex/config_test.exs`: approval-policy default shape.
- `src/test/aiur/config/pr_watch_test.exs`: PrWatch defaults + validation.
- `src/test/aiur/log_file_test.exs:277`: legacy `interval_ms` raise handled at boot.

**Missing characterization (Wave 0 backfill):** `$ENV` reference grammar and
literal-passthrough for invalid names; empty-env-secret → nil vs missing-env → fallback;
`workspace.root` env-token resolution; multi-level `format_errors` flattening;
`StringOrMap` cast rejection; direct `Polling` raise; and the zero-coverage sections
`Events` (explicitly listed in `mix.exs` ignore), `Hooks`, `Worker`, `Observability`,
`Server`, `Opencode`.
