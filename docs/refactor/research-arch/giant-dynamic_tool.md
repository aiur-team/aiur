# Decomposition proposal: `src/lib/aiur/codex/dynamic_tool.ex` (1073 lines)

Behavior-preserving split of `Aiur.Codex.DynamicTool` — the registry + dispatcher + per-tool
executors for the agent-facing dynamic tool surface (`linear_graphql`, review-thread
reply/resolve, `emit_alert`, `emit_event`, `aiur_subscribe`/`aiur_unsubscribe`,
`aiur_declare_blocker`/`aiur_unblock`).

Public API today (must stay byte-identical for callers):

- `execute/3` — called by `src/lib/aiur/codex/coding_agent.ex:112`, `src/lib/aiur/claude/coding_agent.ex:77`, and via `tool_executor/3` closures built in `src/lib/aiur/agent_runner.ex:2007`.
- `tool_specs/0` — advertised as `"dynamicTools"` to the codex app-server (`codex/coding_agent.ex:454`) and the claude bridge (`claude/coding_agent.ex:270`).
- `reset_turn_quotas/0` — called at both turn boundaries in `agent_runner.ex:1096` and `agent_runner.ex:1407`.

Because the entire external surface is these three functions, the facade module keeps its
name and file; everything else becomes `Aiur.Codex.DynamicTool.*` submodules under a new
`src/lib/aiur/codex/dynamic_tool/` directory (matching the repo's `Aiur.Events.*` /
`aiur/events/` path convention).

---

## 1. Function / responsibility census

| # | Concern | Functions | Lines | ~Size |
|---|---------|-----------|-------|-------|
| A | Tool contract constants: names, descriptions, JSON input schemas for all 9 tools | `@emit_alert_*`, `@emit_event_*`, `@aiur_declare_blocker_*`, `@aiur_unblock_*`, `@aiur_subscribe_*`, `@aiur_unsubscribe_*`, `@linear_graphql_*`, `@reply_review_thread_*`, `@resolve_review_thread_*` module attributes | 9–188 | ~180 |
| B | Dispatch | `execute/3` (190–211), `execute_subscription_or_dependency_tool/3` (213–235), `supported_tool_names/0` (1070–1072) | 190–235, 1070–1072 | ~50 |
| C | Spec registry | `tool_specs/0` (fixed-order list of 9 spec maps) | 237–286 | ~50 |
| D | Blocker/dependency executor | `execute_dependency_action/3` (288–318), `normalize_issue_number/1` ×2 (320–336) | 288–336 | ~50 |
| E | Subscription executor | `execute_subscription/3` (342–369), `normalize_topic_pattern/1` ×2 (371–394) | 342–394 | ~53 |
| F | emit_event executor + locked vocabulary + per-turn progress quota | `execute_emit_event/2` (396–418), `normalize_emit_event_arguments/1` ×2 (420–434), `@agent_event_allowlist`/`@agent_event_exact`/quota attrs (436–453), `validate_emit_event_name/1` (455–461), `enforce_per_turn_quota/1` ×2 (463–474), **public** `reset_turn_quotas/0` (476–484) | 396–484 | ~89 |
| G | Review-thread executors (reply + resolve) | `execute_reply_review_thread/2` (486–497), `normalize_reply_review_thread_arguments/1` ×2 (499–509), `execute_resolve_review_thread/2` (511–524), `normalize_resolve_review_thread_arguments/1` ×2 (526–540) | 486–540 | ~55 |
| H | emit_alert executor + normalization + emitter arity dispatch | `execute_emit_alert/2` (542–570), `normalize_emit_alert_arguments/1` ×2 (622–632), `normalize_emit_alert_string/3` (634–645), `emit_alert_value/2` ×3 (647–654), `normalize_emit_alert_reason/2` (656–661), `normalize_emit_alert_needs_attention/1` (663–669), `emit_alert_has_key?/2` (671–673), `normalize_emit_alert_boolean/3` (675–687), `normalize_emit_alert_severity/2` (689–702), `default_alert_severity/1` ×2 (704–705), `call_alert_emitter/6` ×3 clauses — 5-arity, legacy 2-arity, unavailable (707–719) | 542–570, 622–719 | ~125 |
| I | linear_graphql executor | `execute_linear_graphql/2` (572–582), `normalize_linear_graphql_arguments/1` ×3 (584–607), `normalize_query/1` (721–732), `normalize_variables/1` (734–739), `graphql_response/1` — errors-key success flag (741–750) | 572–607, 721–750 | ~65 |
| J | Shared argument normalization | `normalize_dynamic_tool_string/3` (609–620); `result_jsonable/1` ×3 (338–340) | 609–620, 338–340 | ~16 |
| K | Response envelope (wire contract) | `failure_response/1` (752–754), `dynamic_tool_response/2` — `"success"`/`"output"`/`"contentItems"` shape (756–767), `encode_payload/1` ×2 — `Jason.encode!(…, pretty: true)` with `inspect` fallback (769–773) | 752–773 | ~22 |
| L | Error payload catalog | `tool_error_payload/1` — ~45 clauses mapping reason atoms/tuples to agent-visible error maps, ending in a Linear-flavored catch-all used by **every** tool | 775–1068 | ~294 |

Cross-concern facts worth naming before the split:

- `normalize_emit_alert_string/3` (H) is also used by emit_event normalization (lines 421–423) — it is shared by two tools, not alert-private.
- `result_jsonable/1` (J) is used by both the blocker executor (D, line 307) and six error-payload clauses (L).
- The `tool_error_payload/1` catch-all (1061–1068) says "Linear GraphQL tool execution failed" but is the fallback for *any* unrecognized error reason from *any* tool.
- `@progress_quota_key {__MODULE__, :progress_emit_count}` (453) is process-dictionary state; `reset_turn_quotas/0` and `enforce_per_turn_quota/1` only work because AgentRunner resets and then runs the whole turn (including inline tool execution) in the same BEAM process.

---

## 2. Proposed module split (NAME MAP — the downstream contract)

All new files live in `src/lib/aiur/codex/dynamic_tool/`. Handler modules are named after
the tool surface they own; `EmitAlert`/`EmitEvent` (not `Alerts`/`Events`) deliberately avoid
alias collisions with the existing `Aiur.Alerts` and `Aiur.Events.*` modules.

| Module | Path | Responsibility (one sentence) | ~LOC | Key functions moving there |
|---|---|---|---|---|
| `Aiur.Codex.DynamicTool` *(facade, existing file)* | `src/lib/aiur/codex/dynamic_tool.ex` | Unchanged public API: `execute/3` dispatch over a fixed-order handler registry, `tool_specs/0` assembly, `reset_turn_quotas/0` delegation, and the unsupported-tool failure. | ~85 | `execute/3`, `tool_specs/0`, `reset_turn_quotas/0` (defdelegate to `EmitEvent`), `supported_tool_names/0`, ordered `@handlers` registry |
| `Aiur.Codex.DynamicTool.Handler` | `src/lib/aiur/codex/dynamic_tool/handler.ex` | Behaviour contract every tool handler implements: `tools/0` (names handled), `specs/0` (advertised spec maps, in advertisement order), `execute/3`. | ~20 | `@callback tools() :: [String.t()]`, `@callback specs() :: [map()]`, `@callback execute(String.t(), term(), keyword()) :: map()` |
| `Aiur.Codex.DynamicTool.Response` | `src/lib/aiur/codex/dynamic_tool/response.ex` | The codex tool-response wire envelope, one source of truth for the `"success"`/`"output"`/`"contentItems"` shape and payload JSON encoding. | ~55 | `build/2` (was `dynamic_tool_response/2`), `failure/1` (was `failure_response/1`), `encode_payload/1`, `jsonable/1` (was `result_jsonable/1`) |
| `Aiur.Codex.DynamicTool.Errors` | `src/lib/aiur/codex/dynamic_tool/errors.ex` | The complete reason→agent-visible-error-payload catalog, moved verbatim including clause order and the Linear-flavored catch-all. | ~300 | `payload/1` (was `tool_error_payload/1`, all ~45 clauses) |
| `Aiur.Codex.DynamicTool.Args` | `src/lib/aiur/codex/dynamic_tool/args.ex` | Shared argument-normalization primitives (string-or-atom-key fetch, trimmed non-empty strings, boolean/key presence), moved verbatim without merging near-duplicates. | ~50 | `string/3` (was `normalize_dynamic_tool_string/3`), `alert_string/3` (was `normalize_emit_alert_string/3`), `emit_alert_value/2`, `has_key?/2` (was `emit_alert_has_key?/2`), `boolean/3` (was `normalize_emit_alert_boolean/3`) |
| `Aiur.Codex.DynamicTool.LinearGraphQL` | `src/lib/aiur/codex/dynamic_tool/linear_graphql.ex` | `linear_graphql` tool: spec, executor with injectable `LinearClient.graphql/3` default, query/variables normalization, and the GraphQL-`errors`-key success flag. | ~100 | spec constants; `execute/3`; `normalize_linear_graphql_arguments/1`, `normalize_query/1`, `normalize_variables/1`, `graphql_response/1` |
| `Aiur.Codex.DynamicTool.ReviewThreads` | `src/lib/aiur/codex/dynamic_tool/review_threads.ex` | `aiur_reply_review_thread` + `aiur_resolve_review_thread`: specs and executors with `GitHubClient.reply_to_review_thread/3` / `resolve_review_thread/2` defaults and read-after-write argument contracts. | ~115 | spec constants; `execute/3`; `execute_reply_review_thread/2`, `execute_resolve_review_thread/2`, both `normalize_*_arguments/1` pairs |
| `Aiur.Codex.DynamicTool.EmitAlert` | `src/lib/aiur/codex/dynamic_tool/emit_alert.ex` | `emit_alert` tool: spec, executor, reason/needs_attention/severity normalization and defaults, and the 5-arity-vs-legacy-2-arity emitter dispatch. | ~155 | spec constants; `execute/3`; `normalize_emit_alert_arguments/1`, `normalize_emit_alert_reason/2`, `normalize_emit_alert_needs_attention/1`, `normalize_emit_alert_severity/2`, `default_alert_severity/1`, `call_alert_emitter/6` (all 3 clauses) |
| `Aiur.Codex.DynamicTool.EmitEvent` | `src/lib/aiur/codex/dynamic_tool/emit_event.ex` | `emit_event` tool: spec, executor, the locked agent vocabulary allowlist, and the per-turn bare-`progress` quota (process-dictionary counter + `reset_turn_quotas/0`). | ~150 | spec constants; `execute/3`; `normalize_emit_event_arguments/1`, `@agent_event_allowlist`/`@agent_event_exact`, `validate_emit_event_name/1`, `enforce_per_turn_quota/1`, `reset_turn_quotas/0` (with the pdict key written as the **literal** `{Aiur.Codex.DynamicTool, :progress_emit_count}`) |
| `Aiur.Codex.DynamicTool.Subscriptions` | `src/lib/aiur/codex/dynamic_tool/subscriptions.ex` | `aiur_subscribe` + `aiur_unsubscribe`: specs, executor over injected subscriber/unsubscriber closures, and AMQP topic-pattern validation. | ~95 | spec constants; `execute/3`; `execute_subscription/3`, `normalize_topic_pattern/1` |
| `Aiur.Codex.DynamicTool.Blockers` | `src/lib/aiur/codex/dynamic_tool/blockers.ex` | `aiur_declare_blocker` + `aiur_unblock`: specs, executor over injected declarer/unblocker closures, and issue-number normalization. | ~95 | spec constants; `execute/3`; `execute_dependency_action/3`, `normalize_issue_number/1` |

Total ≈ 1220 LOC (net +~150 for moduledocs/behaviour boilerplate). Every module lands under
the 200-line target except `Errors` (~300) — a deliberate judgment call: it is a flat
data catalog (one clause per reason atom, zero nesting, zero logic) and splitting it per-tool
would either change the shared catch-all behavior or force a clause-ordering fan-out. Same
waiver logic as the schema constants: data, not logic.

Dependency direction (one way, no cycles):
`DynamicTool` (facade) → handler modules → `Args`/`Errors`/`Response`; `Errors` → `Response`
(for `jsonable/1`); `Handler` behaviour has no deps. Handlers never call the facade or each
other, with one exception: `EmitEvent` and `EmitAlert` both call `Args.alert_string/3` (the
shared normalizer they share today).

---

## 3. Extraction sequencing (strictly serialized waves; repo compiles + tests green after each)

Verification gate for every wave:
`mix compile --warnings-as-errors` + `mix test test/aiur/dynamic_tool_test.exs test/aiur/codex/dynamic_tool_test.exs test/aiur/claude/coding_agent_test.exs` (paths relative to `src/`), then the full suite before merge.

- **Wave 0 — characterization backfill (test-only, ~120 new test lines, no src moves).**
  Add the missing pins listed in §4 *before* any move: blocker/unblock execution paths,
  the Linear-flavored catch-all reached from a non-linear tool, emit_alert
  `needs_attention: true → severity "warning"` default, explicit-severity passthrough.
- **Wave 1 — foundations (~170 lines moved).** Create `Handler` (new), `Response`, and
  `Args`. Move envelope helpers (`dynamic_tool_response`, `failure_response`,
  `encode_payload`, `result_jsonable`) and the shared normalizers
  (`normalize_dynamic_tool_string`, `normalize_emit_alert_string`, `emit_alert_value`,
  `emit_alert_has_key?`, `normalize_emit_alert_boolean`) verbatim. The facade keeps
  one-line private wrappers delegating to the new modules so all remaining executor code
  compiles unchanged.
- **Wave 2 — error catalog (~300 lines moved).** Move all `tool_error_payload/1` clauses to
  `Errors.payload/1` in the same order, catch-all last. Facade keeps
  `defp tool_error_payload(reason), do: Errors.payload(reason)`.
- **Wave 3 — LinearGraphQL + ReviewThreads (~230 lines moved).** Extract both handlers with
  their spec constants; `execute/3` branches for these three tool names call the handler
  modules; `tool_specs/0` splices `LinearGraphQL.specs() ++ ReviewThreads.specs()` at the
  head, preserving exact order.
- **Wave 4 — EmitAlert + EmitEvent (~250 lines moved).** Extract both handlers.
  `reset_turn_quotas/0` becomes a facade `defdelegate` to `EmitEvent`; the pdict key moves
  as the literal `{Aiur.Codex.DynamicTool, :progress_emit_count}` (never re-expand
  `__MODULE__` in the new module — enforce and reset must share one key). Progress-cap
  suite (`test/aiur/codex/dynamic_tool_test.exs`) is the gate.
- **Wave 5 — Subscriptions + Blockers + facade collapse (~210 lines moved).** Extract the
  last two handlers; replace `execute/3` + `execute_subscription_or_dependency_tool/3` with
  a single lookup over the ordered `@handlers` registry (`tool → module` map built at
  compile time); `tool_specs/0` becomes `Enum.flat_map(@handlers, & &1.specs())`;
  `supported_tool_names/0` derives from `tool_specs/0` as today. Delete the Wave-1/2 shim
  wrappers now orphaned by this wave. Facade lands at ~85 lines. Full suite + one manual
  `scripts/aiur` smoke of an agent emitting `progress`/`emit_alert`.

Each wave is a single reviewable ticket ≤400 lines moved; waves touch this file serially
(no parallel tickets on `dynamic_tool.ex`). No wave requires edits to `agent_runner.ex`,
`codex/coding_agent.ex`, or `claude/coding_agent.ex` — the public API is frozen.

---

## 4. Risks: semantics to preserve verbatim, existing pins, missing coverage

### Concurrency / state / timing semantics (preserve exactly)

1. **Per-turn progress quota is process-dictionary state with a same-process invariant.**
   `AgentRunner` calls `reset_turn_quotas/0` (`agent_runner.ex:1096`, `:1407`) and then runs
   `CodingAgent.run_turn/4` in the same process; both coding agents invoke the
   `tool_executor` closure inline in their receive loops (`codex/coding_agent.ex:1122`,
   `claude/coding_agent.ex:451`), so `Process.get/put` on the quota key sees one counter per
   turn. Two things break it silently: (a) moving tool execution into a `Task`/`GenServer`
   (fresh pdict → cap never trips); (b) key drift — `@progress_quota_key
   {__MODULE__, :progress_emit_count}` re-expands if the attribute moves to `EmitEvent`, so
   enforce and reset must move together in one wave and the key should be written as a
   literal. Do **not** "improve" this to ETS in the behavior-preserving pass — the pdict is
   the correct one-source-of-truth for per-process/per-turn state.
2. **`tool_specs/0` order and the `supportedTools` list are a wire contract.** The exact
   9-element order is pinned by `test/aiur/dynamic_tool_test.exs:77–92` and is advertised
   verbatim to live codex/claude app-server sessions (`codex/coding_agent.ex:454`,
   `claude/coding_agent.ex:270`). The registry list must reproduce it exactly.
3. **The error catch-all is shared, and mislabeled — keep it that way.**
   `tool_error_payload/1`'s final clause renders *any* unrecognized reason from *any* tool
   as "Linear GraphQL tool execution failed." Splitting the catalog per handler with
   per-tool fallbacks would change agent-visible messages (e.g. an `alert_emitter` returning
   `{:error, :weird}`). The catalog moves whole, clause order intact.
4. **Response envelope + pretty JSON.** `%{"success" => _, "output" => _, "contentItems" =>
   [%{"type" => "inputText", ...}]}` and `Jason.encode!(…, pretty: true)` (with `inspect`
   fallback for non-encodable payloads) are consumed by `normalize_tool_result` in both
   coding agents and asserted byte-for-byte by tests.
5. **emit_alert dual-arity emitter dispatch and defaults.** `is_function(emitter, 5)` first,
   legacy `is_function(emitter, 2)` second, unavailable third; `reason` defaults to
   `message`; `needs_attention` defaults `false` only when the key is absent (explicit
   non-boolean is an error); severity defaults `"warning"`/`"info"` by `needs_attention`.
   `agent_runner.ex`'s `tool_executor` builds a 5-arity emitter; older callers may still
   pass 2-arity.
6. **GraphQL success flag.** `graphql_response/1` flips success on a non-empty `"errors"`
   list under either string or atom keys — both clauses and the non-empty check must
   survive the move.
7. **Near-duplicate normalizers must not be merged during moves.**
   `normalize_emit_alert_string/3` (via `emit_alert_value/2`, string keys "name"/"message"/
   "reason" only) vs `normalize_dynamic_tool_string/3` (any key, `String.to_atom`) are
   behaviorally identical for the keys used today; merging them is a semantic-change
   candidate for a separate post-refactor cleanup ticket, not a move wave.
8. **Hotspot-map adjacency.** `dynamic_tool.ex` is not itself a named hotspot in
   `docs/refactor/research-history-hotspots.md`, but both `reset_turn_quotas` callsites sit
   inside `agent_runner.ex`'s two turn paths — hotspot item 7 ("queued-message drain
   outcomes… never converts success to failure"). The map also warns that "every
   filter/cutoff/cap clipped a legitimate case on first ship" — the progress cap and the
   event-name allowlist are exactly that class; move them without touching thresholds,
   regexes, or the exact-match list. Since the public API is frozen, no wave should touch
   `agent_runner.ex` at all.

### Existing tests that pin this file

- `src/test/aiur/dynamic_tool_test.exs` (`Aiur.Codex.DynamicToolTest`, 731 lines): spec
  contracts for linear_graphql/review-threads/emit_alert; unsupported-tool payload with the
  exact ordered `supportedTools` list and `contentItems` echo; linear_graphql success,
  raw-string args, legacy `operationName`, multi-op passthrough, blank-query,
  invalid-args/variables, transport/auth/status error rendering, atom-key errors,
  non-JSON `inspect` fallback; review-thread reply/resolve happy paths, not-verified and
  not-permitted failures; emit_alert 5-arity + legacy 2-arity emitters, defaulted
  reason/needs_attention, non-boolean rejection, reserved-scope error; emit_event
  allowlist accept/reject, exact-name list, payload passthrough, missing name/message,
  missing publisher; subscribe/unsubscribe closures, malformed/missing patterns, missing
  closure.
- `src/test/aiur/codex/dynamic_tool_test.exs` (`DynamicToolProgressCapTest`,
  `async: false`): bare-`progress` acceptance, 2-per-turn cap, 3rd-emit rejection with the
  exact "per-turn `progress` cap" message, reset-at-turn-boundary, no shared budget with
  `custom.*` or `progress.<slug>`.
- `src/test/aiur/claude/coding_agent_test.exs:71–76`: asserts the claude bridge's
  `"dynamicTools"` param equals `DynamicTool.tool_specs()` exactly.

### Missing characterization coverage (add in Wave 0)

- **`aiur_declare_blocker` / `aiur_unblock` executors: zero execution tests** — the names
  appear only in the `supportedTools` assertion. Untested at this layer:
  `normalize_issue_number` (string parse, trim, zero/negative rejection), handler-arity
  gate, success payload shape (`ok`/`issue_number`/`result` with `result_jsonable`
  atom→string), and the `:cycle_detected` / `:blocker_not_found` / `:rate_limited` /
  `:permission_denied` error renderings.
- **The shared catch-all reached from a non-linear tool** (e.g. `event_publisher` returning
  `{:error, :unexpected}` → "Linear GraphQL tool execution failed") — this is exactly risk
  #3 and must be pinned before Wave 2.
- **emit_alert severity paths**: explicit `severity` passthrough and the
  `needs_attention: true → "warning"` default (only `"info"` paths are tested).
- **Atom-key argument variants** (`%{name: …}` etc.) — supported by every normalizer,
  tested by none.
- **emit_event publisher wrong-arity** (e.g. `fn/2`) → unavailable failure.
- Note: the `:custom_event_quota_exceeded` payload clause (lines 1011–1017) currently has
  no producer — pre-existing dead-ish data; keep it, do not delete during the refactor.
