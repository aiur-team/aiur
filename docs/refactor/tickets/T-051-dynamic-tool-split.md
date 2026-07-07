# T-051: dynamic_tool: split registration and dispatch

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/codex/dynamic_tool.ex` is a 1,073-line module — `Aiur.Codex.DynamicTool` — that is simultaneously the registry, dispatcher, and the nine per-tool executors for the agent-facing dynamic tool surface (`linear_graphql`, `aiur_reply_review_thread`, `aiur_resolve_review_thread`, `emit_alert`, `emit_event`, `aiur_subscribe`, `aiur_unsubscribe`, `aiur_declare_blocker`, `aiur_unblock`). These tool contracts are the **public API of the whole coordination system**: their JSON input schemas are advertised verbatim to live codex/claude app-server sessions, and their observable behavior is what agents on every ticket depend on. Schemas and behavior must stay byte-identical.

The decomposition plan is `docs/refactor/research-arch/giant-dynamic_tool.md` — its name map (§2) is the **binding contract** for module and file names, and its risks section (§4) names concurrency/timing semantics that must be preserved verbatim. This is a **behavior-preserving move, not a rewrite**: move code verbatim; the only permitted edits to moved code are `defp` → `def`, adding `@spec`/`@moduledoc`, and rewriting references to moved siblings (e.g. `normalize_emit_alert_string(...)` → `Args.alert_string(...)`). The facade module `Aiur.Codex.DynamicTool` keeps its name, path, and its exact public surface — `execute/3`, `tool_specs/0`, `reset_turn_quotas/0` — so that its three call sites keep working unchanged: `src/lib/aiur/codex/coding_agent.ex:112` and `:454`, `src/lib/aiur/claude/coding_agent.ex:77` and `:270`, and the `tool_executor/3` closures built in `src/lib/aiur/agent_runner.ex:2007` (plus `reset_turn_quotas/0` at `agent_runner.ex:1096` and `:1407`). **No wave in this ticket edits `agent_runner.ex`, `codex/coding_agent.ex`, or `claude/coding_agent.ex` — the public API is frozen.**

## Scope (exact)

All new modules live under a new directory `src/lib/aiur/codex/dynamic_tool/` (matching the repo's `Aiur.Events.*` / `aiur/events/` path convention). Line numbers refer to `src/lib/aiur/codex/dynamic_tool.ex` at the start of this ticket. Module and file names below are the **exact** binding names from `giant-dynamic_tool.md` §2 — do not rename, pluralize, or re-case any of them. Every moved private function becomes a public `def` (with `@spec`) in its new module. Every new module gets a `@moduledoc`. Extract in the wave order below: each wave compiles against the previous ones, and the repo must compile with the full suite green after every wave. During waves 1–4 the facade keeps one-line private wrapper shims that delegate to the new modules so remaining executor code compiles unchanged; wave 5 deletes those now-orphaned shims.

### Wave 0 — characterization backfill (test-only, no src moves)

Before moving any code, append **new** `test` blocks (do not modify or delete any existing test) to `src/test/aiur/dynamic_tool_test.exs` pinning the currently-uncovered behavior identified in `giant-dynamic_tool.md` §4:

1. `aiur_declare_blocker` / `aiur_unblock` execution via `DynamicTool.execute/3` with injected `:blocker_declarer` / `:unblocker` closures: success payload shape (`%{"ok" => true, "issue_number" => n, "result" => ...}` with atom `result` rendered as a string), `normalize_issue_number` string-parse + trim + zero/negative rejection (`:invalid_issue_number`) + missing (`:missing_issue_number`), handler-arity-gate unavailable (`:blocker_declarer_unavailable` / `:unblocker_unavailable`), and the `:cycle_detected`, `:blocker_not_found`, `:rate_limited`, `:permission_denied` error renderings.
2. The shared catch-all reached from a **non-linear** tool: an `:event_publisher` (or `:alert_emitter`) returning `{:error, :unexpected}` still renders the catch-all `"Linear GraphQL tool execution failed."` payload (this pins risk §4.3 before Wave 2).
3. `emit_alert` severity paths: explicit `severity` passthrough, and the `needs_attention: true` → `"warning"` default (only `"info"` is covered today).
4. Atom-key argument variants (e.g. `%{name: ..., message: ...}`) accepted by every normalizer.
5. `emit_event` publisher wrong-arity (e.g. an `fn/2`) → `:event_publisher_unavailable` failure.

Run the gate. All new tests pass against the unchanged source. No `src/lib` file changes in this wave.

### Wave 1 — foundations (`Handler`, `Response`, `Args`)

6. **Create `Aiur.Codex.DynamicTool.Handler`** in `src/lib/aiur/codex/dynamic_tool/handler.ex`. A behaviour with exactly three `@callback`s and a `@moduledoc`:
   - `@callback tools() :: [String.t()]`
   - `@callback specs() :: [map()]`
   - `@callback execute(String.t(), term(), keyword()) :: map()`
   No functions. Depends on nothing.
7. **Create `Aiur.Codex.DynamicTool.Response`** in `src/lib/aiur/codex/dynamic_tool/response.ex`. Move verbatim, renaming as noted:
   - `build/2` (was `dynamic_tool_response/2`, 756–767) — the `%{"success" => _, "output" => _, "contentItems" => [%{"type" => "inputText", "text" => output}]}` shape, unchanged.
   - `failure/1` (was `failure_response/1`, 752–754).
   - `encode_payload/1` (both clauses, 769–773 — `Jason.encode!(…, pretty: true)` with the `inspect/1` fallback for non-encodable payloads).
   - `jsonable/1` (was `result_jsonable/1`, all three clauses, 338–340).
   Depends on nothing but `Jason`.
8. **Create `Aiur.Codex.DynamicTool.Args`** in `src/lib/aiur/codex/dynamic_tool/args.ex`. Move verbatim, renaming as noted — **do not merge the near-duplicate `string/3` and `alert_string/3`** (risk §4.7):
   - `string/3` (was `normalize_dynamic_tool_string/3`, 609–620).
   - `alert_string/3` (was `normalize_emit_alert_string/3`, 634–645).
   - `emit_alert_value/2` (all three clauses, 647–654).
   - `has_key?/2` (was `emit_alert_has_key?/2`, 671–673).
   - `boolean/3` (was `normalize_emit_alert_boolean/3`, 675–687).
   Depends on nothing.
9. In the facade, replace the moved bodies with one-line private shims so the remaining executors compile unchanged (e.g. `defp dynamic_tool_response(s, o), do: Response.build(s, o)`, `defp failure_response(p), do: Response.failure(p)`, `defp encode_payload(p), do: Response.encode_payload(p)`, `defp result_jsonable(v), do: Response.jsonable(v)`, `defp normalize_dynamic_tool_string(a, k, r), do: Args.string(a, k, r)`, `defp normalize_emit_alert_string(a, k, r), do: Args.alert_string(a, k, r)`, `defp emit_alert_value(a, k), do: Args.emit_alert_value(a, k)`, `defp emit_alert_has_key?(a, k), do: Args.has_key?(a, k)`, `defp normalize_emit_alert_boolean(a, k, r), do: Args.boolean(a, k, r)`). Add `alias Aiur.Codex.DynamicTool.{Args, Handler, Response}`. Run the gate.

### Wave 2 — error catalog (`Errors`)

10. **Create `Aiur.Codex.DynamicTool.Errors`** in `src/lib/aiur/codex/dynamic_tool/errors.ex`. Move **all** `tool_error_payload/1` clauses (775–1068) to `payload/1` in the **same order, catch-all last** (risk §4.3 — the final `"Linear GraphQL tool execution failed."` clause is the shared fallback for every tool and must stay last and unchanged). Keep the `:custom_event_quota_exceeded` clause (1011–1017) even though it has no producer today — pre-existing data, do not delete (risk §4 note). Inside `Errors`, the six clauses that call `result_jsonable/1` become `Response.jsonable/1` (alias `Aiur.Codex.DynamicTool.Response`). In the facade, replace with `defp tool_error_payload(reason), do: Errors.payload(reason)` and add `Errors` to the alias. Run the gate.

### Wave 3 — `LinearGraphQL` + `ReviewThreads`

11. **Create `Aiur.Codex.DynamicTool.LinearGraphQL`** in `src/lib/aiur/codex/dynamic_tool/linear_graphql.ex`, implementing `@behaviour Aiur.Codex.DynamicTool.Handler`:
    - `tools/0` → `["linear_graphql"]`.
    - `specs/0` → `[%{"name" => "linear_graphql", "description" => @linear_graphql_description, "inputSchema" => @linear_graphql_input_schema}]` — move the `@linear_graphql_tool`/`@linear_graphql_description`/`@linear_graphql_input_schema` attributes (122–141) into this module verbatim.
    - `execute/3` → for tool `"linear_graphql"`, the body of `execute_linear_graphql/2` (572–582), keeping the injectable `Keyword.get(opts, :linear_client, &LinearClient.graphql/3)` default (add `alias Aiur.Linear.Client, as: LinearClient`).
    - Move verbatim: `normalize_linear_graphql_arguments/1` (all three clauses, 584–607), `normalize_query/1` (721–732), `normalize_variables/1` (734–739), `graphql_response/1` (741–750 — keep **both** the string-key and atom-key non-empty-`errors` clauses; risk §4.6). Calls to `graphql_response`/`failure_response`/`tool_error_payload`/`dynamic_tool_response`/`encode_payload` become `Response.build`/`Response.failure`/`Response.encode_payload`/`Errors.payload` as appropriate (alias `Response`, `Errors`).
12. **Create `Aiur.Codex.DynamicTool.ReviewThreads`** in `src/lib/aiur/codex/dynamic_tool/review_threads.ex`, implementing the `Handler` behaviour:
    - `tools/0` → `["aiur_reply_review_thread", "aiur_resolve_review_thread"]`.
    - `specs/0` → `[reply_spec, resolve_spec]` in that order — move the `@reply_review_thread_*` (142–164) and `@resolve_review_thread_*` (165–188) attributes verbatim.
    - `execute/3` → dispatch on tool name: `"aiur_reply_review_thread"` → body of `execute_reply_review_thread/2` (486–497), `"aiur_resolve_review_thread"` → body of `execute_resolve_review_thread/2` (511–524). Keep the `Keyword.get(opts, :review_thread_replier, &GitHubClient.reply_to_review_thread/3)` and `Keyword.get(opts, :review_thread_resolver, &GitHubClient.resolve_review_thread/2)` defaults (add `alias Aiur.GitHub.Client, as: GitHubClient`).
    - Move verbatim: `normalize_reply_review_thread_arguments/1` (499–509), `normalize_resolve_review_thread_arguments/1` (526–540). Their `normalize_dynamic_tool_string(...)` calls become `Args.string(...)`; envelope/error calls become `Response.*`/`Errors.payload`.
13. In the facade, route `execute/3`'s `@linear_graphql_tool`, `@reply_review_thread_tool`, `@resolve_review_thread_tool` branches to `LinearGraphQL.execute/3` / `ReviewThreads.execute/3`, and splice `LinearGraphQL.specs() ++ ReviewThreads.specs()` at the head of `tool_specs/0` in place of those three inline spec maps — preserving the exact positions 1–3. Delete the now-unused facade attributes and executor bodies for these three tools. Run the gate.

### Wave 4 — `EmitAlert` + `EmitEvent`

14. **Create `Aiur.Codex.DynamicTool.EmitAlert`** in `src/lib/aiur/codex/dynamic_tool/emit_alert.ex`, implementing the `Handler` behaviour:
    - `tools/0` → `["emit_alert"]`; `specs/0` → the `emit_alert` spec (move `@emit_alert_*` attributes, 9–38).
    - `execute/3` → body of `execute_emit_alert/2` (542–570), keeping `Keyword.get(opts, :alert_emitter)`.
    - Move verbatim: `normalize_emit_alert_arguments/1` (622–632), `normalize_emit_alert_reason/2` (656–661), `normalize_emit_alert_needs_attention/1` (663–669), `normalize_emit_alert_severity/2` (689–702), `default_alert_severity/1` (both clauses, 704–705), `call_alert_emitter/6` (**all three clauses in order** — 5-arity, legacy 2-arity, unavailable; 707–719; risk §4.5). Calls to `normalize_emit_alert_string`/`emit_alert_value`/`emit_alert_has_key?`/`normalize_emit_alert_boolean` become `Args.alert_string`/`Args.emit_alert_value`/`Args.has_key?`/`Args.boolean`; envelope/error calls become `Response.*`/`Errors.payload`.
15. **Create `Aiur.Codex.DynamicTool.EmitEvent`** in `src/lib/aiur/codex/dynamic_tool/emit_event.ex`, implementing the `Handler` behaviour:
    - `tools/0` → `["emit_event"]`; `specs/0` → the `emit_event` spec (move `@emit_event_*` attributes, 39–69).
    - `execute/3` → body of `execute_emit_event/2` (396–418), keeping `Keyword.get(opts, :event_publisher)`.
    - Move verbatim: `normalize_emit_event_arguments/1` (both clauses, 420–434 — its `normalize_emit_alert_string` calls become `Args.alert_string`), the `@agent_event_allowlist` and `@agent_event_exact` attributes (439–445), the quota attributes (452–453), `validate_emit_event_name/1` (455–461), `enforce_per_turn_quota/1` (both clauses, 463–474). **Do not touch the regexes, the exact-match list, or the threshold `2`** (risk §4.8).
    - Move the public `reset_turn_quotas/0` (476–484) into this module, keeping its `@doc`/`@spec`. **The process-dictionary key must be written as the literal `@progress_quota_key {Aiur.Codex.DynamicTool, :progress_emit_count}` — never as `{__MODULE__, ...}`** (risk §4.1: re-expanding `__MODULE__` in `EmitEvent` would give a different key and silently break the cap, since `AgentRunner` calls the facade's `reset_turn_quotas/0`). `enforce_per_turn_quota/1` and `reset_turn_quotas/0` must both read/write this one literal key. Do **not** convert the pdict counter to ETS/Task/GenServer — the per-process pdict is the correct one-source-of-truth for per-turn state.
16. In the facade, route `execute/3`'s `@emit_alert_tool` / `@emit_event_tool` branches to `EmitAlert.execute/3` / `EmitEvent.execute/3`; add `EmitAlert.specs()` and `EmitEvent.specs()` at positions 4 and 5 of `tool_specs/0`; replace the facade's `reset_turn_quotas/0` with `defdelegate reset_turn_quotas(), to: EmitEvent`. Delete the moved facade attributes, executor bodies, quota attributes, and the old `reset_turn_quotas/0` body. Run the gate (the progress-cap suite `test/aiur/codex/dynamic_tool_test.exs` is the gate here).

### Wave 5 — `Subscriptions` + `Blockers` + facade collapse

17. **Create `Aiur.Codex.DynamicTool.Subscriptions`** in `src/lib/aiur/codex/dynamic_tool/subscriptions.ex`, implementing the `Handler` behaviour:
    - `tools/0` → `["aiur_subscribe", "aiur_unsubscribe"]`; `specs/0` → `[subscribe_spec, unsubscribe_spec]` (move `@aiur_subscribe_*` and `@aiur_unsubscribe_*`, 93–121).
    - `execute/3` → dispatch tool name to `:subscribe` / `:unsubscribe`, running the body of `execute_subscription/3` (342–369, injected `:subscriber` / `:unsubscriber` closures). Move `normalize_topic_pattern/1` (both clauses, 371–394) verbatim — keep the `..` / leading-`.` / trailing-`.` validation exactly.
18. **Create `Aiur.Codex.DynamicTool.Blockers`** in `src/lib/aiur/codex/dynamic_tool/blockers.ex`, implementing the `Handler` behaviour:
    - `tools/0` → `["aiur_declare_blocker", "aiur_unblock"]`; `specs/0` → `[declare_spec, unblock_spec]` (move `@aiur_declare_blocker_*` and `@aiur_unblock_*`, 70–92; note `@aiur_unblock_input_schema` reuses the declare schema — preserve that alias).
    - `execute/3` → dispatch tool name to `:declare` / `:unblock`, running the body of `execute_dependency_action/3` (288–318, injected `:blocker_declarer` / `:unblocker` closures). Move `normalize_issue_number/1` (both clauses, 320–336) verbatim. The `result_jsonable(...)` call becomes `Response.jsonable(...)`.
19. **Collapse the facade** `src/lib/aiur/codex/dynamic_tool.ex` to ~85 lines:
    - Add an ordered compile-time registry `@handlers [LinearGraphQL, ReviewThreads, EmitAlert, EmitEvent, Subscriptions, Blockers]` — this exact order reproduces the 9-element `tool_specs/0` order (positions: linear_graphql; reply, resolve; emit_alert; emit_event; subscribe, unsubscribe; declare_blocker, unblock).
    - Replace `execute/3` and `execute_subscription_or_dependency_tool/3` with a single lookup: build a `tool_name => module` map from `Enum.flat_map(@handlers, fn m -> Enum.map(m.tools(), &{&1, m}) end)`; on hit call `module.execute(tool, arguments, opts)`; on miss return `Response.failure(%{"error" => %{"message" => "Unsupported dynamic tool: #{inspect(other)}.", "supportedTools" => supported_tool_names()}})` — byte-identical to today's unsupported-tool payload.
    - `tool_specs/0` becomes `Enum.flat_map(@handlers, & &1.specs())`.
    - `supported_tool_names/0` stays derived from `tool_specs/0` (`Enum.map(tool_specs(), & &1["name"])`).
    - `reset_turn_quotas/0` stays the `defdelegate` to `EmitEvent`.
    - Delete the Wave-1/Wave-2 private shim wrappers (`dynamic_tool_response`, `failure_response`, `encode_payload`, `result_jsonable`, `normalize_dynamic_tool_string`, `normalize_emit_alert_string`, `emit_alert_value`, `emit_alert_has_key?`, `normalize_emit_alert_boolean`, `tool_error_payload`) — they are now orphaned. Remove the now-unused `alias Aiur.GitHub.Client` and `alias Aiur.Linear.Client` (moved into `ReviewThreads` / `LinearGraphQL`). Keep `alias Aiur.Codex.DynamicTool.{...}` for `Response` (used by the miss branch) and the six handler modules.
    - Run the full gate.
20. **Write one test file per extracted module** (paths in Files), plain ExUnit, `async: true` (except where a module owns `async: false` process-dictionary state — see below), calling each new module's public functions directly. Required minimum coverage:
    - `handler_test.exs`: asserts every handler module implements the behaviour — for each of the six modules, `tools/0` returns the expected tool-name list, `specs/0` returns one map per name with `"name"`/`"description"`/`"inputSchema"` keys, and each `"name"` is in that module's `tools/0`.
    - `response_test.exs`: `build/2` returns the exact `%{"success" => _, "output" => _, "contentItems" => [%{"type" => "inputText", "text" => output}]}` shape; `failure/1` sets `"success" => false`; `encode_payload/1` pretty-prints a map/list and falls back to `inspect/1` for a non-JSON term (e.g. a tuple); `jsonable/1` maps an atom to its string, passes maps/lists/binaries through, and `inspect`s anything else.
    - `args_test.exs`: `string/3` trims and rejects blank/missing (returns the given error reason), accepts atom-key variants via `String.to_atom`; `alert_string/3` reads only `"name"`/`"message"`/`"reason"` (string or atom key); `emit_alert_value/2` returns `nil` for an absent key; `has_key?/2` is true for string or atom key; `boolean/3` accepts `true`/`false` and rejects a non-boolean present value and a missing key.
    - `errors_test.exs`: at least one representative clause per tool family renders its exact `"message"` (e.g. `:missing_query`, `:invalid_alert_arguments`, `:cycle_detected`, `:missing_topic_pattern`, `:invalid_issue_number`), the `{:linear_api_status, 500}` tuple clause includes `"status" => 500`, and the catch-all renders `"Linear GraphQL tool execution failed."` with an `inspect`ed reason for an unknown atom.
    - `linear_graphql_test.exs`: `execute/3` with an injected `:linear_client` returns success on a clean response, `success:false` on a non-empty `"errors"` list (string **and** atom key), and renders `:missing_query`/`:invalid_arguments`/`:invalid_variables` errors; raw-string argument and object-with-`variables` both accepted.
    - `review_threads_test.exs`: reply happy path via injected `:review_thread_replier`, resolve happy path via injected `:review_thread_resolver`, and the `:review_thread_reply_not_verified` / `:review_thread_resolution_not_permitted` failures render.
    - `emit_alert_test.exs`: 5-arity and legacy 2-arity emitters both succeed; defaulted `reason` (falls back to `message`) and defaulted `needs_attention` (`false` when absent, error on present non-boolean); explicit-`severity` passthrough and the `needs_attention: true → "warning"` / `false → "info"` defaults; unavailable emitter → `:alert_emitter_unavailable`.
    - `emit_event_test.exs` (**`async: false`** — owns the progress process-dictionary counter): allowlist accept (exact names + each regex family) and reject (`:event_name_not_in_allowlist` with examples); payload defaults to `%{}`; missing name/message and missing publisher errors; the bare-`progress` cap accepts 2 per turn and rejects the 3rd with `:progress_cap_exceeded`, and `reset_turn_quotas/0` restores the budget; assert `progress.<slug>` and `custom.*` do **not** consume the bare-`progress` budget.
    - `subscriptions_test.exs`: subscribe/unsubscribe via injected closures succeed; malformed pattern (`..`, leading/trailing `.`) and missing pattern rejected; missing closure → unavailable.
    - `blockers_test.exs`: declare/unblock via injected closures succeed (payload `%{"ok" => true, "issue_number" => n, "result" => ...}`); string/integer issue-number parse; zero/negative/non-numeric rejected; missing closure → unavailable; `:cycle_detected` renders.
21. Do **not** add any new module to `ignore_modules` in `src/mix.exs` — the eleven new modules are NOT coverage-exempt. Do not remove the existing `Aiur.Codex.DynamicTool` entry if one is present; leave `src/mix.exs` untouched.

## Files

- Create: `src/lib/aiur/codex/dynamic_tool/handler.ex`, `src/lib/aiur/codex/dynamic_tool/response.ex`, `src/lib/aiur/codex/dynamic_tool/args.ex`, `src/lib/aiur/codex/dynamic_tool/errors.ex`, `src/lib/aiur/codex/dynamic_tool/linear_graphql.ex`, `src/lib/aiur/codex/dynamic_tool/review_threads.ex`, `src/lib/aiur/codex/dynamic_tool/emit_alert.ex`, `src/lib/aiur/codex/dynamic_tool/emit_event.ex`, `src/lib/aiur/codex/dynamic_tool/subscriptions.ex`, `src/lib/aiur/codex/dynamic_tool/blockers.ex`
- Modify: `src/lib/aiur/codex/dynamic_tool.ex`
- Test: `src/test/aiur/codex/dynamic_tool/handler_test.exs`, `src/test/aiur/codex/dynamic_tool/response_test.exs`, `src/test/aiur/codex/dynamic_tool/args_test.exs`, `src/test/aiur/codex/dynamic_tool/errors_test.exs`, `src/test/aiur/codex/dynamic_tool/linear_graphql_test.exs`, `src/test/aiur/codex/dynamic_tool/review_threads_test.exs`, `src/test/aiur/codex/dynamic_tool/emit_alert_test.exs`, `src/test/aiur/codex/dynamic_tool/emit_event_test.exs`, `src/test/aiur/codex/dynamic_tool/subscriptions_test.exs`, `src/test/aiur/codex/dynamic_tool/blockers_test.exs`, `src/test/aiur/dynamic_tool_test.exs` (Wave 0: append new tests only)

## Out of scope

- `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/codex/coding_agent.ex`, `src/lib/aiur/claude/coding_agent.ex` — the three callers. The public API (`execute/3`, `tool_specs/0`, `reset_turn_quotas/0`) is frozen; do not touch these files.
- Merging the near-duplicate normalizers `Args.string/3` and `Args.alert_string/3` — behaviorally identical for today's keys but a **separate** post-refactor cleanup ticket (risk §4.7). Move both verbatim; do not consolidate.
- Splitting the `Errors` catalog per handler or giving any tool its own fallback — the shared, Linear-mislabeled catch-all is load-bearing (risk §4.3). It moves whole, clause order intact.
- Changing the `emit_event` allowlist regexes, the `@agent_event_exact` list, the progress cap threshold (`2`), or any tool's JSON input schema / description text — these are the wire contract.
- Converting the progress quota from the process dictionary to ETS/Task/GenServer (risk §4.1), and re-expanding the pdict key with `__MODULE__`.
- Deleting the producer-less `:custom_event_quota_exceeded` error clause (risk §4 note) — keep it.
- Existing tests other than the Wave-0 additions: do not edit or delete any pre-existing `test` block in `src/test/aiur/dynamic_tool_test.exs`; do not touch `src/test/aiur/codex/dynamic_tool_test.exs` or `src/test/aiur/claude/coding_agent_test.exs`.
- `src/mix.exs` (including `ignore_modules`) and any config/CI file.

## Inventory-IDs

From `docs/refactor/feature-inventory/cdx.md` (implemented in `dynamic_tool.ex`, moved by this ticket):

- FI-CDX-047 — Dynamic tool registry (`tool_specs/0`), the ordered 9-tool advertisement
- FI-CDX-048 — Dynamic tool response envelope (→ `Response`)
- FI-CDX-049 — `emit_alert` tool semantics (→ `EmitAlert`)
- FI-CDX-050 — `emit_event` vocabulary allowlist (→ `EmitEvent`)
- FI-CDX-051 — Bare-`progress` per-turn emit cap 2/turn (→ `EmitEvent`; risk §4.1)
- FI-CDX-052 — `aiur_declare_blocker` / `aiur_unblock` tools (→ `Blockers`)
- FI-CDX-053 — `aiur_subscribe` / `aiur_unsubscribe` tools (→ `Subscriptions`)
- FI-CDX-054 — `linear_graphql` tool (→ `LinearGraphQL`)
- FI-CDX-055 — `aiur_reply_review_thread` / `aiur_resolve_review_thread` tools (→ `ReviewThreads`)
- FI-CDX-030 — Dynamic tool call servicing (`execute/3` dispatch), boundary only: `DynamicTool.execute` stays the injected default; the caller in `codex/coding_agent.ex` is untouched
- FI-CDX-022 — `tool_specs()` advertised at thread/start, boundary only: the spec list stays byte-identical

From `docs/refactor/feature-inventory/evt.md` (the vocabulary/cap logic that lives in `dynamic_tool.ex`, moved into `EmitEvent`):

- FI-EVT-044 — `emit_event: progress` (bare) + 2-per-turn cap
- FI-EVT-046 — `emit_event: progress.<slug>` (allowlist regex family)
- FI-EVT-047 — `emit_event` name allowlist (vocabulary lock)

Note: FI-EVT-048…FI-EVT-055 (the individual `decision`/`blocked`/`unblocked`/`attention.*`/`pause.request`/`custom.<slug>` names, and the `ticket.<id>.agent.<name>` prefixing) are validated by the allowlist moving here but are otherwise **implemented in `agent_runner.ex` / `orchestrator.ex`**, which this ticket does not touch. FI-EVT-056 (`aiur_subscribe`/`aiur_unsubscribe`) and FI-EVT-075 (`emit_alert` prefixing) likewise have their behavior split between the frozen `agent_runner.ex` emit path and the tool-schema/validation layer moving here.

## Characterization-tests

None under `src/test/aiur/regression/` exercise `Aiur.Codex.DynamicTool` — the closest, `src/test/aiur/regression/event_flow_e2e_test.exs`, drives the `Exchange`/`SubscriptionStore` pipeline directly with a stub enqueue closure and never calls the dynamic-tool layer, so it does not pin this file's behavior. The binding pins for this area live outside `regression/` and must pass byte-identical (never edit them): `src/test/aiur/dynamic_tool_test.exs` (`Aiur.Codex.DynamicToolTest`, ~731 lines — spec contracts, ordered `supportedTools` list, every tool's happy/error paths), `src/test/aiur/codex/dynamic_tool_test.exs` (`DynamicToolProgressCapTest`, `async: false` — the 2/turn progress cap + reset), and `src/test/aiur/claude/coding_agent_test.exs:71–76` (asserts the claude bridge's `"dynamicTools"` param equals `DynamicTool.tool_specs()` exactly).

## Acceptance criteria

- The ten new modules exist with these exact names: `grep -l "defmodule Aiur.Codex.DynamicTool.Handler do" src/lib/aiur/codex/dynamic_tool/handler.ex` matches, and likewise `Response`/`Args`/`Errors`/`LinearGraphQL`/`ReviewThreads`/`EmitAlert`/`EmitEvent`/`Subscriptions`/`Blockers` each in their own file under `src/lib/aiur/codex/dynamic_tool/`.
- The facade keeps exactly its public surface: `grep -cE "^  def " src/lib/aiur/codex/dynamic_tool.ex` returns 2 (`execute/3` and `tool_specs/0`), and `grep -c "defdelegate reset_turn_quotas" src/lib/aiur/codex/dynamic_tool.ex` returns 1 (`reset_turn_quotas/0` delegates to `EmitEvent`).
- The moved executors and helpers are gone from the facade: `grep -cE "defp (execute_linear_graphql|execute_reply_review_thread|execute_resolve_review_thread|execute_emit_alert|execute_emit_event|execute_subscription|execute_dependency_action|normalize_linear_graphql_arguments|normalize_query|normalize_variables|graphql_response|normalize_reply_review_thread_arguments|normalize_resolve_review_thread_arguments|normalize_emit_alert_arguments|normalize_emit_alert_reason|normalize_emit_alert_needs_attention|normalize_emit_alert_severity|default_alert_severity|call_alert_emitter|normalize_emit_event_arguments|validate_emit_event_name|enforce_per_turn_quota|normalize_topic_pattern|normalize_issue_number|tool_error_payload|dynamic_tool_response|failure_response|encode_payload|result_jsonable|normalize_dynamic_tool_string|normalize_emit_alert_string|emit_alert_value|emit_alert_has_key\?|normalize_emit_alert_boolean)\(" src/lib/aiur/codex/dynamic_tool.ex` returns 0.
- The pdict key is a literal in `EmitEvent`, not `__MODULE__`: `grep -c "{Aiur.Codex.DynamicTool, :progress_emit_count}" src/lib/aiur/codex/dynamic_tool/emit_event.ex` returns 1, and `grep -c "__MODULE__, :progress_emit_count" src/lib/aiur/codex/dynamic_tool/emit_event.ex` returns 0.
- The `@handlers` registry lists the six handler modules in order: `grep -c "@handlers" src/lib/aiur/codex/dynamic_tool.ex` ≥ 1.
- Every new module has a `@moduledoc` (`grep -c "@moduledoc" <file>` ≥ 1 in all ten files) and a `@spec` for every public `def` (per file, `grep -cE "^  @spec " <file>` ≥ the number of distinct public function names in that file; the `Handler` behaviour file uses `@callback` and is exempt from `@spec`).
- File size: `wc -l` ≤ 200 for every new file **except** `errors.ex`, which is ≤ 320 (a flat data catalog — one clause per reason, zero logic; `giant-dynamic_tool.md` §2 explicitly waives it and forbids splitting it).
- Function size: every function clause written **new** in this ticket (registry lookup, test helpers) is ≤ 20 logic lines; verbatim-moved clauses are exempt — do not rewrite moved code to shorten it.
- The eleven test files in Files exist and are non-empty; `cd src && mix test test/aiur/codex/dynamic_tool` passes, and the Wave-0 additions in `test/aiur/dynamic_tool_test.exs` pass.
- `cd src && mix test` passes with zero failures; the three binding suites named in Characterization-tests are unchanged (`git diff --name-only` does not list `src/test/aiur/codex/dynamic_tool_test.exs` or `src/test/aiur/claude/coding_agent_test.exs`; `src/test/aiur/dynamic_tool_test.exs` shows only appended tests).
- `src/mix.exs` is unchanged (`git diff --name-only` does not contain `src/mix.exs`): the ten new modules are absent from `ignore_modules` and covered by the suite.
- No file outside the Files list is modified — in particular `git diff --name-only` never lists `agent_runner.ex`, `codex/coding_agent.ex`, or `claude/coding_agent.ex`.

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
- Check: PR diff touches only the 21 paths in Files; zero changes to `agent_runner.ex` / `codex/coding_agent.ex` / `claude/coding_agent.ex`, zero changes to the binding suites (`codex/dynamic_tool_test.exs`, `claude/coding_agent_test.exs`), `src/mix.exs` untouched.
- Check: `cd src && mix test test/aiur/dynamic_tool_test.exs` passes byte-identical — the ordered `supportedTools` assertion and every tool's happy/error path still hold, proving `tool_specs/0` order and the response envelope survived.
- Check: `cd src && mix test test/aiur/codex/dynamic_tool_test.exs` (the `async: false` progress-cap suite) passes — confirms the pdict key literal is shared and the 2/turn cap + `reset_turn_quotas/0` still work after the move to `EmitEvent`.
- Check: `cd src && mix test test/aiur/claude/coding_agent_test.exs` passes — confirms the claude bridge's `"dynamicTools"` param still equals `DynamicTool.tool_specs()` exactly.
- Check: `cd src && mix test --cover` reports coverage rows for all ten `Aiur.Codex.DynamicTool.*` modules (none exempt).
- Spot-check the facade diff: `execute/3` is a single registry lookup, `tool_specs/0` is `Enum.flat_map(@handlers, & &1.specs())`, `reset_turn_quotas/0` is a `defdelegate` to `EmitEvent`, and the orphaned Wave-1/2 shims and the `GitHub.Client`/`Linear.Client` aliases are gone; the facade lands at ~85 lines.
- Spot-check that no handler calls the facade or another handler, with the single permitted exception that `EmitEvent` and `EmitAlert` both call `Args.alert_string/3`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
