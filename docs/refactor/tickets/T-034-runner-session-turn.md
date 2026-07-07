# T-034: agent_runner wave 1: SessionLifecycle, SessionResume, TurnLoop, TurnPrompt

**Phase:** 3
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_runner.ex` is a 2,215-line module and the #7 characterization
hotspot in `docs/refactor/research-history-hotspots.md` (item 7: queued-message
drain outcomes, events-digest filtering, session-resume handle lifecycle). The
decomposition plan in `docs/refactor/research-arch/giant-agent_runner.md` splits
it into 14 focused modules under `src/lib/aiur/agent_runner/`, delivered across
three serialized tickets (T-034 → T-035 → T-036).

This ticket is **wave 1 of 3**. It extracts four modules —
`Aiur.AgentRunner.SessionLifecycle`, `Aiur.AgentRunner.SessionResume`,
`Aiur.AgentRunner.TurnLoop`, `Aiur.AgentRunner.TurnPrompt` — from the parent
module (which is renamed nowhere; it stays `Aiur.AgentRunner` and remains the
run entry point). The remaining nine concerns (queue drain, checkpoint delivery,
events digest, bootstrap digest, comment context, message handler, turn streams,
tool executor, turn alerts) stay in the facade and move in T-035/T-036.

Baseline assumption: **T-016 has already merged** (backend `@behaviour` +
migration of the residual backend branching). The function names below are the
binding contract from the research doc's name map (§2); the line numbers are
from the pre-refactor snapshot and will have drifted after T-016 — **locate
every function by name, not by line number.**

This is a **verbatim code move, not a rewrite.** Function bodies, guards, clause
order, comments, and the `# credo:disable-for-next-line
Credo.Check.Refactor.FunctionArity` marker all move unchanged. Observable
behavior and every currently-public function signature are unchanged. No test
file is edited.

## Scope (exact)

Read these rules first; every step below obeys them.

- **R1 — verbatim move.** Copy each named function (with its leading comment
  block) byte-for-byte into its new module. Do not reformat, rename parameters,
  reorder clauses, merge clauses, or "simplify". The only edits allowed to a
  moved body are the call-site rewrites R2 mandates.
- **R2 — cross-module calls.** After a function moves, a call inside it to a
  function that now lives elsewhere must be qualified:
  - callee co-moved into a **sibling module in this ticket** → `Module.fn(...)`
    (e.g. `SessionResume.load_resume_thread_id(...)`);
  - callee **still in `Aiur.AgentRunner`** (a "bridge" function — it belongs to
    a T-035/T-036 module and will relocate later) → `Aiur.AgentRunner.fn(...)`.
    Step 5 lists exactly which facade functions become bridge functions.
  - callee is an external module (`CodingAgent`, `Config`, `Aiur.Orchestrator`,
    `DynamicTool`, `Aiur.Boot`, `Logger`, …) → unchanged.
- **R3 — public visibility.** Any moved function that is called from another
  module (sibling or facade) must be a public `def` with `@doc false` and a
  `@spec`. Functions called only within their own new module stay `defp`.
  Mutual runtime references between the four new modules are expected and
  compile fine (they are plain function calls, never GenServer calls).
- **R4 — process identity is sacred.** Every moved function keeps executing
  **in the runner Task's own process** as a plain function call. Never wrap any
  moved code in `Task.async`, `spawn`, `GenServer`, or `Process.send`. The
  `try/after` blocks and the `receive`-adjacent call chains move as-is.

### 1. Create `src/lib/aiur/agent_runner/session_resume.ex` — `Aiur.AgentRunner.SessionResume`

Move these functions verbatim from `agent_runner.ex` (census §F + the resume
helpers in §E). Give every one `@doc false` and a `@spec` (five already carry
`@spec`/`@doc false` — keep them). They are all reachable cross-module, so all
are public:

- `load_resume_thread_id/3`
- `resume_thread_id/3` (already `@doc false @spec`)
- `maybe_put_resume_thread_id/2`
- `session_resumed?/1` (already `@doc false @spec`)
- `log_resume_outcome/3` (all clauses)
- `maybe_persist_turn_handle/4`
- `turn_handle_attrs/2` (already `@doc false @spec`)
- `persist_session_handle/3`
- `persist_handle_best_effort/3` (already `@doc false @spec`, keep the `\\ []`
  default and the `rescue` clause verbatim)
- `session_handle_to_save/2` (already `@doc false @spec`, both clauses)

R2 rewrites inside this module: `turn_handle_attrs/2` and
`session_handle_to_save/2` call `session_backend/1` → rewrite to
`SessionLifecycle.session_backend(...)`.
Aliases the file needs: `alias Aiur.{CodingAgent, Issue, SessionHandle}` and
`alias Aiur.AgentRunner.SessionLifecycle`. Add `require Logger`.
Do **not** add, call, or reference `SessionHandle.clear/2` here — terminal-state
handle clearing lives in the orchestrator (`orchestrator.ex`) and stays there
(see Out of scope).

### 2. Create `src/lib/aiur/agent_runner/turn_prompt.ex` — `Aiur.AgentRunner.TurnPrompt`

Pure text policy (census §H). Move verbatim:

- `build_turn_prompt/4` (both clauses — first-turn resumed/cold-start, and
  continuation). Make it a public `def` with `@doc false` + `@spec` (it is
  called by `TurnLoop` and by the facade's test delegation).
- `resumed_turn_prompt/0` — keep `defp` (called only by `build_turn_prompt/4`).
- `turn_of/1` (both clauses) — keep `defp` (called only by `build_turn_prompt/4`).

R2 rewrites: `build_turn_prompt/4` calls `PromptBuilder.build_prompt(issue, opts)`
→ unchanged (external). Aliases needed: `alias Aiur.{Issue, PromptBuilder}`.

### 3. Create `src/lib/aiur/agent_runner/session_lifecycle.ex` — `Aiur.AgentRunner.SessionLifecycle`

Start/stop one agent session, backend/model/effort/RC resolution, display
tailer, repl-runtime reporting (census §E). Move verbatim:

- `run_codex_turns/5` **renamed to `run_session/5`** — public `def` `@doc false`
  `@spec` (the facade calls it). Keep all five positional parameters and the
  entire body, **including the `try do … after stop_display_tailer(...) +
  CodingAgent.stop_session(session) end` block, verbatim** (this teardown
  ordering is load-bearing — see Risks).
- `report_repl_session/3` (all clauses) — keep `defp`.
- `headless_os_pid/1` (both clauses) — keep `defp`.
- `maybe_start_display_tailer/3` — keep `defp`.
- `should_display_tail?/3` — public `def` `@doc false @spec` (already annotated).
- `stop_display_tailer/1` (both clauses, incl. `catch`) — keep `defp`.
- `maybe_put_rc_name/3` (both clauses) — keep `defp`.
- `remote_session_backend/2` — public `def` `@doc false @spec` (already annotated).
- `rc_session_name/2` — public `def` `@doc false @spec` (already annotated; keep
  the `\\ Tracker.project_identity()` default head verbatim).
- `rc_session_prefix/1` — keep `defp`.
- `repo_short_name/1` (both clauses) — keep `defp`.
- `maybe_trust_remote_control_workspace/4` — public `def` `@doc false @spec`
  (already annotated; keep the multi-clause head and the standalone spec-only
  head verbatim).
- `start_agent_session/3` — public `def` `@doc false @spec` (already annotated;
  keep the `\\ &CodingAgent.start_session/2` default head verbatim).
- `session_workspace/1`, `session_worker_host/1`, `session_backend/1` (both
  clauses each) — public `def` `@doc false @spec` (shared accessors called by
  `SessionResume`, `TurnLoop`, and facade code).

R2 rewrites inside this module:
- `run_session/5` calls `load_resume_thread_id/3`, `maybe_put_resume_thread_id/2`,
  `persist_session_handle/3`, `log_resume_outcome/3`, `session_resumed?/1` →
  `SessionResume.<fn>(...)`.
- `run_session/5` calls `do_run_codex_turns(…)` → `TurnLoop.run_turns(...)`
  (same 10 positional args, in the same order).
- `run_session/5` calls `issue_context/1` → `Aiur.AgentRunner.issue_context(...)`
  (bridge, step 5).
- `maybe_start_display_tailer/3` calls `session_backend/1` (own module) →
  leave unqualified.

Aliases the file needs: `alias Aiur.{CodingAgent, Config, Issue, Tracker}`,
`alias Aiur.Claude.DisplayTailer`, `alias Aiur.AgentPubSub`,
`alias Aiur.AgentRunner.{SessionResume, TurnLoop}`. Add `require Logger`.

### 4. Create `src/lib/aiur/agent_runner/turn_loop.ex` — `Aiur.AgentRunner.TurnLoop`

The autonomous multi-turn loop (census §G). Move verbatim:

- `do_run_codex_turns/10` **renamed to `run_turns/10`** — public `def`
  `@doc false @spec`. **Move the `# credo:disable-for-next-line
  Credo.Check.Refactor.FunctionArity` comment immediately above it.** Keep all
  10 positional parameters and the full body verbatim; do **not** convert the
  signature to a struct.
- `turn_done_reason/1` (all clauses) — public `def` `@doc false @spec` (the
  facade's `run_queue_item_turn` also calls it).
- `finalize_turn_completion/3` — keep `defp`.
- `wait_for_resume/3` — keep `defp`.
- `continue_issue_turn/2` — keep `defp`.
- `continue_with_issue?/2` (both clauses) — keep `defp`.
- `active_issue_state?/1` (both clauses) — keep `defp`.
- `normalize_issue_state/1` — keep `defp`.
- `max_turns_display/1` (both clauses) — keep `defp`.

R2 rewrites inside this module (these are the T-035/T-036 bridge callees, all
reached via `Aiur.AgentRunner.<fn>` per step 5, **except** the four listed as
sibling calls):
- sibling calls: `build_turn_prompt(...)` → `TurnPrompt.build_turn_prompt(...)`;
  `session_backend(app_session)` → `SessionLifecycle.session_backend(...)`;
  `maybe_persist_turn_handle(...)` → `SessionResume.maybe_persist_turn_handle(...)`.
- bridge calls → `Aiur.AgentRunner.<fn>(...)`: `codex_message_handler/6`,
  `safe_checkpoint_handler/2`, `send_control_state/3`, `open_aiur_turn_streams/1`,
  `close_aiur_turn_streams/3`, `operator_immediate_handler/2`, `tool_executor/3`,
  `drain_operator_messages/5`, `wait_for_operator_message/5`,
  `maybe_emit_usage_limit_alert/4`, `maybe_emit_more_tokens_alert/4`,
  `write_pause_log/2`, `issue_context/1`.
- external calls unchanged: `DynamicTool.reset_turn_quotas/0`,
  `CodingAgent.run_turn/4`, `Aiur.Orchestrator.consume_delivered_queue_items/2`,
  `Aiur.Orchestrator.restore_delivered_queue_items/2`,
  `Aiur.Orchestrator.fail_delivered_queue_items/3`, `Aiur.Boot.elapsed_ms/0`,
  `Logger.*`.

Aliases the file needs: `alias Aiur.{Config, Issue}`,
`alias Aiur.AgentRunner.{SessionLifecycle, SessionResume, TurnPrompt}`.
Add `require Logger`.

### 5. Turn the T-035/T-036 bridge callees public in the facade

The functions in the bridge list above stay in `Aiur.AgentRunner` for now (they
belong to modules extracted in T-035/T-036, where they will be public API).
`TurnLoop` and `SessionLifecycle` now call them cross-module, so each must be a
public `def`. For every function in this list, change `defp` → `def`, add
`@doc false`, and add a `@spec`:

`codex_message_handler/6`, `safe_checkpoint_handler/2`, `send_control_state/3`,
`open_aiur_turn_streams/1`, `close_aiur_turn_streams/3`,
`operator_immediate_handler/2`, `tool_executor/3`, `drain_operator_messages/5`,
`wait_for_operator_message/5`, `maybe_emit_usage_limit_alert/4`,
`maybe_emit_more_tokens_alert/4`, `write_pause_log/2` (and its `/3` sibling
clause), `issue_context/1`.

For a closure-returning function whose precise `@spec` is non-obvious
(`codex_message_handler`, `safe_checkpoint_handler`, `operator_immediate_handler`,
`tool_executor`), use the loosest correct spec (`... :: (... -> any())` or a
`fun()` return): `specs.check` only requires a spec to exist and dialyzer to
accept it, not maximal precision. Do not change any body.

### 6. Edit the facade `src/lib/aiur/agent_runner.ex`

1. Delete every function body moved in steps 1–4 (and its leading comments).
2. Add `alias Aiur.AgentRunner.{SessionLifecycle, SessionResume, TurnLoop,
   TurnPrompt}` to the alias block.
3. **Keep every currently-public (`@doc false`) moved function reachable under
   its old name** so existing tests call it unchanged. For each of these, keep
   the original head verbatim (including default args) and replace the body with
   a single delegating call:
   - `def resume_thread_id(backend, worker_host, handle), do:
     SessionResume.resume_thread_id(backend, worker_host, handle)`
   - `def session_resumed?(session), do: SessionResume.session_resumed?(session)`
   - `def turn_handle_attrs(a, b), do: SessionResume.turn_handle_attrs(a, b)`
   - `def session_handle_to_save(s, w), do: SessionResume.session_handle_to_save(s, w)`
   - `def persist_handle_best_effort(id, attrs, opts \\ []), do:
     SessionResume.persist_handle_best_effort(id, attrs, opts)`
   - `def should_display_tail?(b, rc?, id), do:
     SessionLifecycle.should_display_tail?(b, rc?, id)`
   - `def remote_session_backend(b, rc?), do:
     SessionLifecycle.remote_session_backend(b, rc?)`
   - `def start_agent_session(ws, opts, start_fun \\ &CodingAgent.start_session/2),
     do: SessionLifecycle.start_agent_session(ws, opts, start_fun)`
   - `def maybe_trust_remote_control_workspace(ws, rc?, wh, fun), do:
     SessionLifecycle.maybe_trust_remote_control_workspace(ws, rc?, wh, fun)`
   - `def rc_session_name(issue, repo \\ Tracker.project_identity()), do:
     SessionLifecycle.rc_session_name(issue, repo)`
   - `def build_turn_prompt_for_test(issue, opts, turn_number, max_turns), do:
     TurnPrompt.build_turn_prompt(issue, opts, turn_number, max_turns)`
   Keep each delegation's existing `@doc false`/`@spec`.
4. Update the remaining facade call sites of moved functions (R2 direction:
   facade → new module):
   - `run_worker_attempt_once/5` calls `run_codex_turns(...)` →
     `SessionLifecycle.run_session(...)`.
   - `run_queue_item_turn/6` calls `session_workspace/1`, `session_worker_host/1`,
     `session_backend/1` → `SessionLifecycle.session_*(...)`; and
     `turn_done_reason(result)` → `TurnLoop.turn_done_reason(result)`.
   - Any other remaining facade reference to a moved private name (e.g. inside
     `run_queue_item_turn`, `queue_item_text`, checkpoint handlers) is repointed
     the same way. Mechanical loop: `mix compile --warnings-as-errors`, fix each
     "undefined function" by qualifying it to its new module, repeat until clean.
5. The bridge functions from step 5 stay physically in the facade (now `def`);
   `run_queue_item_turn`, `queue_item_text`, `drain_queued_operator_messages`,
   and the whole checkpoint/queue/digest/tool/alert cluster are **not** moved in
   this ticket.

### 7. Edit `src/mix.exs`

Do **not** add `Aiur.AgentRunner.SessionLifecycle`,
`Aiur.AgentRunner.SessionResume`, `Aiur.AgentRunner.TurnLoop`, or
`Aiur.AgentRunner.TurnPrompt` to `test_coverage.ignore_modules` — new modules
are not coverage-exempt; the 85% threshold enforces their tests. Leave the
existing `Aiur.AgentRunner` entry and every other entry untouched.

### 8. Create one test file per new module (new files only)

- `src/test/aiur/agent_runner/session_resume_test.exs` —
  `Aiur.AgentRunner.SessionResumeTest`, `use ExUnit.Case, async: false`. Cover:
  `resume_thread_id/3` returns the id only for a resumable backend on the local
  worker (`nil` host) with a `{:ok, %{thread_id: ...}}` handle, and `nil` for
  remote host / `:none` / non-resumable; `session_resumed?/1` true only on
  `%{resumed: true}`; `turn_handle_attrs/2` returns `{:ok, attrs}` only on a
  binary thread-id drift and `:skip` otherwise; `session_handle_to_save/2`
  gates on local host + resumable backend + binary thread id; `persist_handle_
  best_effort/3` returns `:ok` and swallows a raise (point `:dir` at a path that
  raises, or assert `:ok` on a valid dir).
- `src/test/aiur/agent_runner/turn_prompt_test.exs` —
  `Aiur.AgentRunner.TurnPromptTest`, `async: true`. Cover: turn 1 non-resumed →
  `PromptBuilder.build_prompt` output; turn 1 with `resumed: true` → the
  "session resumed after an aiur restart" text; turn N>1 → the continuation text
  containing `continuation turn #<n>` and the `of <max>` / `∞` rendering of
  `turn_of/1` via a nil vs integer `max_turns`.
- `src/test/aiur/agent_runner/session_lifecycle_test.exs` —
  `Aiur.AgentRunner.SessionLifecycleTest`, `async: false`. Cover the pure/
  injectable seams: `remote_session_backend("claude", true) == "claude-repl"`
  and pass-through otherwise; `should_display_tail?/3` true only for `rc? and
  backend == "claude-repl" and binary identifier`; `rc_session_name/2` prefix +
  60-char clamp + control-char scrub with an injected repo and a `nil` repo;
  `maybe_trust_remote_control_workspace/4` invokes the trust fun only for
  `true`/local and swallows `{:error, _}`; `start_agent_session/3` tags
  `:backend`, and on a `claude-repl` start error falls back once to `"claude"`
  (inject a `start_fun` that fails the first call), while a non-`claude-repl`
  error propagates unchanged; `session_backend/1` default is `Config.agent_kind()`.
- `src/test/aiur/agent_runner/turn_loop_test.exs` —
  `Aiur.AgentRunner.TurnLoopTest`, `async: true`. Cover the pure helpers:
  `turn_done_reason/1` maps `{:ok, _}`→`:done`, `{:paused, _}`→`:input_required`,
  `{:error, r}`→`{:failed, r}`, other→`:done`; `max_turns_display/1` renders
  `"∞"` for nil and the integer otherwise. (The full turn-loop lifecycle is
  pinned by the T-013 characterization file and `core_test.exs` — do not
  re-drive `run_turns/10` end-to-end here.)
- Follow the authoring rules in `docs/refactor/regression-safety.md` §2: no
  `Process.sleep` synchronization, no exact counts on shared singletons,
  `assert_receive` windows ≥ 2000 ms (these are pure-function tests and should
  need none of that).

### 9. Run the Agent gate

Run the full gate (below) after the wave lands and once at the end. Every
existing test — all of `src/test/aiur/regression/`,
`src/test/aiur/agent_runner_test.exs`, `core_test.exs`, `live_e2e_test.exs` —
passes with zero edits to any test file.

## Files

- Create:
  - `src/lib/aiur/agent_runner/session_lifecycle.ex`
  - `src/lib/aiur/agent_runner/session_resume.ex`
  - `src/lib/aiur/agent_runner/turn_loop.ex`
  - `src/lib/aiur/agent_runner/turn_prompt.ex`
  - `src/test/aiur/agent_runner/session_lifecycle_test.exs`
  - `src/test/aiur/agent_runner/session_resume_test.exs`
  - `src/test/aiur/agent_runner/turn_loop_test.exs`
  - `src/test/aiur/agent_runner/turn_prompt_test.exs`
- Modify:
  - `src/lib/aiur/agent_runner.ex`
  - `src/mix.exs`
- Test (run unmodified as the behavior pin):
  - the four created test files above
  - `src/test/aiur/regression/agent_runner_lifecycle_test.exs` (T-013)
  - `src/test/aiur/regression/event_flow_e2e_test.exs`
  - `src/test/aiur/agent_runner_test.exs`
  - `src/test/aiur/core_test.exs`, `src/test/aiur/live_e2e_test.exs`

## Out of scope

- The nine other concerns and their functions — they stay in the facade this
  wave: queue drain (`drain_operator_messages`, `wait_for_operator_message`,
  `run_queue_item_turn`, `queue_item_text`, claim helpers), checkpoint delivery,
  events digest (`render_events_digest`, debounce, external-content wrap),
  bootstrap digest, comment context, message handler
  (`codex_message_handler`, transcript/turn broadcasts, `send_control_state`),
  turn streams (`open/close_aiur_turn_streams`, `post_aiur_turn_markers`), tool
  executor, turn alerts. They are T-035/T-036. In this wave they are only made
  `@doc false` public where TurnLoop calls them (step 5); their bodies are not
  touched.
- `run/3`, `transient_run_error?/1`, `run_on_worker_host/4`,
  `run_worker_attempt/5`, `run_worker_attempt_once/5`,
  `pause_for_before_run_failure/7`, `wait_for_before_run_resume/3`,
  `selected_worker_host/2`, `maybe_attach_issue_log/1`, `trim_hook_output/1` —
  the run-entry / worker-attempt concern (A) stays in the facade permanently.
- `SessionHandle.clear/2` and terminal-state handle clearing — wired in the
  orchestrator (`src/lib/aiur/orchestrator.ex`), not here. Do not add clearing
  to any file in this ticket (Risks: #610/#701).
- Deduplicating the shared `run_turns` / `run_queue_item_turn` turn spine — a
  follow-up after all three waves land, not a mechanical move.
- Any behavior, signature, log-string, config, or test change whatsoever.
- Other giant files (`orchestrator.ex`, `github/client.ex`, `init.ex`, …).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` and `.../cdx.md` — the features
whose implementing functions this ticket's files move (behavior identical after
the move):

- **FI-ORC-066** — Backend/model/effort resolution and RC decision
  (`run_session`, `remote_session_backend`, `maybe_put_rc_name`,
  `maybe_trust_remote_control_workspace`, `rc_session_name`) → SessionLifecycle.
- **FI-ORC-067** — Session resume across aiur restarts (#378/#613)
  (`load_resume_thread_id`, `resume_thread_id`, `session_resumed?`,
  `log_resume_outcome`, `persist_session_handle`, `maybe_persist_turn_handle`,
  `session_handle_to_save`, `persist_handle_best_effort`) → SessionResume.
- **FI-ORC-068** — claude-repl start fallback to headless claude
  (`start_agent_session`) → SessionLifecycle.
- **FI-ORC-069** — Display tailer for RC claude-repl (display-only mirror)
  (`maybe_start_display_tailer`, `should_display_tail?`, `stop_display_tailer`)
  → SessionLifecycle.
- **FI-ORC-062** — Runner runtime-info reporting to the orchestrator
  (`report_repl_session`, `headless_os_pid` — the abort-path pane/os-pid report)
  → SessionLifecycle.
- **FI-ORC-058** — `ensure_remote_control_trust` serialized trust seeding — the
  call boundary in `maybe_trust_remote_control_workspace` → SessionLifecycle
  (orchestrator-side impl untouched).
- **FI-ORC-070** — Turn loop: prompts, max_turns, active-state continuation
  (`run_turns`, `finalize_turn_completion`, `wait_for_resume`,
  `continue_issue_turn`, `continue_with_issue?`, `active_issue_state?`,
  `max_turns_display`) → TurnLoop; (`build_turn_prompt`, `resumed_turn_prompt`,
  `turn_of`) → TurnPrompt.
- **FI-ORC-072** — Turn result → queue-item settlement — the **main-turn**
  branch only (`run_turns`' `{:ok}`→consume / `{:paused}`→restore /
  `{:error}`→fail via `Aiur.Orchestrator.*_delivered_queue_items`) → TurnLoop.
  (The queue-item-turn completion-race branch stays in the facade → T-035.)
- **FI-CDX-013** — Resumability flags (`CodingAgent.resumable?/1`) — the resume
  gates in SessionResume call this (impl stays in `coding_agent.ex`).
- **FI-CDX-015** — Session-handle sidecar artifact — `SessionHandle.load/save`
  call sites in SessionResume (impl stays in `session_handle.ex`).
- **FI-CDX-023** — Codex session resume with graceful degradation (#378) — the
  silent degrade-to-clean-start path across SessionResume + SessionLifecycle.

## Characterization-tests

These Phase-1 characterization files protect this area and **must pass
UNMODIFIED**:

- `src/test/aiur/regression/agent_runner_lifecycle_test.exs` (T-013) — pins the
  session-resume handle lifecycle (`resume_thread_id/3`, `turn_handle_attrs/2`,
  `session_handle_to_save/2`, `persist_handle_best_effort/3` via `AgentRunner`),
  events-digest filtering, and queued-message drain outcomes. The facade
  delegations from step 6 keep every `AgentRunner.*` call in this file resolving.
- `src/test/aiur/regression/event_flow_e2e_test.exs` — digest render through the
  runner-visible closure.
- The whole `src/test/aiur/regression/` directory.

Additional behavior pins that must also pass unmodified (not under
`regression/`, but they call the moved public surface via the facade):
`src/test/aiur/agent_runner_test.exs`, `src/test/aiur/core_test.exs`
(~13 `AgentRunner.run/3` scenarios), `src/test/aiur/live_e2e_test.exs`.

A failing characterization test means your change is wrong. Never edit the test.
Stop: comment on the issue describing the failing test, emit `emit_alert` with
`needs_attention: true`, and end your turn without opening a PR.

## Acceptance criteria

All checks run from the repo root; every one must hold.

- New modules exist at exact paths:
  - `grep -c "^defmodule Aiur.AgentRunner.SessionLifecycle do" src/lib/aiur/agent_runner/session_lifecycle.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.SessionResume do" src/lib/aiur/agent_runner/session_resume.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.TurnLoop do" src/lib/aiur/agent_runner/turn_loop.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.TurnPrompt do" src/lib/aiur/agent_runner/turn_prompt.ex` == 1
- Each new lib file has a `@moduledoc`: `grep -c "@moduledoc" <file>` >= 1 for
  all four. `mix credo --strict` (which runs `specs.check`) passes, proving a
  `@spec` on every public `def`.
- The moved concerns are gone from the facade (each grep on
  `src/lib/aiur/agent_runner.ex` returns 0):
  - `grep -c "Continuation guidance" src/lib/aiur/agent_runner.ex` == 0  (TurnPrompt)
  - `grep -c "PromptBuilder.build_prompt" src/lib/aiur/agent_runner.ex` == 0  (TurnPrompt)
  - `grep -c "aiur_autonomous_loop phase=recurse" src/lib/aiur/agent_runner.ex` == 0  (TurnLoop)
  - `grep -c "defp do_run_codex_turns" src/lib/aiur/agent_runner.ex` == 0  (→ TurnLoop.run_turns)
  - `grep -c "falling back to headless claude" src/lib/aiur/agent_runner.ex` == 0  (SessionLifecycle)
  - `grep -c "defp run_codex_turns(" src/lib/aiur/agent_runner.ex` == 0  (→ SessionLifecycle.run_session)
  - `grep -c "Resume requested but degraded" src/lib/aiur/agent_runner.ex` == 0  (SessionResume)
- The test-facing public API still resolves on the facade (delegations present):
  `grep -cE "def (resume_thread_id|turn_handle_attrs|session_handle_to_save|persist_handle_best_effort|should_display_tail\?|remote_session_backend|start_agent_session|maybe_trust_remote_control_workspace|rc_session_name|build_turn_prompt_for_test|session_resumed\?)\(" src/lib/aiur/agent_runner.ex`
  == 11, and each such `def`'s body is a single delegating call to
  `SessionLifecycle.`/`SessionResume.`/`TurnPrompt.` (no multi-line logic).
- Parent file shrank: `wc -l < src/lib/aiur/agent_runner.ex` <= 1850
  (from 2,215; ~650 lines move out, delegations + newly-public bridge
  annotations add back < 150).
- File-size budget (per the research doc's ~LOC estimates; verbatim moves
  cannot fit the generic 200-line norm without a forbidden rewrite):
  `wc -l` on `session_resume.ex` <= 200, `turn_prompt.ex` <= 110,
  `session_lifecycle.ex` <= 300, `turn_loop.ex` <= 300. No **new** function
  (anything not moved verbatim) exceeds 20 logic lines; moved bodies are not
  rewritten to game any limit.
- Coverage is enforced for the new modules:
  `grep -cE "Aiur\.AgentRunner\.(SessionLifecycle|SessionResume|TurnLoop|TurnPrompt)" src/mix.exs`
  == 0, and all four test files exist:
  `ls src/test/aiur/agent_runner/{session_lifecycle,session_resume,turn_loop,turn_prompt}_test.exs`.
- No handle-clearing crept in:
  `grep -c "SessionHandle.clear" src/lib/aiur/agent_runner.ex` == 0 and
  `grep -rc "SessionHandle.clear" src/lib/aiur/agent_runner/` == 0.
- No test file changed: `git diff --name-only origin/v2 -- src/test/` is empty.
- The full Agent gate below is green.

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

- `cd src && mix test --cover` — the 85% threshold passes with the four new
  modules counted (none in `ignore_modules`).
- Diff review: every hunk in `src/lib/aiur/agent_runner.ex` is a deletion, an
  alias line, a one-line delegation, or a `defp`→`def` + `@doc false`/`@spec`
  annotation on a step-5 bridge function — **zero logic edits**. The four new
  lib files contain only moved bodies plus `@moduledoc`/`@spec`/aliases.
- FI-ORC-068 spot-check (`Check:` probe): `mix test test/aiur/agent_runner_test.exs`
  alone — the `start_agent_session` claude-repl→headless fallback, RC
  trust/naming, and `remote_session_backend` cases pass through the facade
  delegations to `SessionLifecycle`.
- FI-ORC-067 spot-check: `mix test test/aiur/regression/agent_runner_lifecycle_test.exs`
  alone, plus a 10× reseed loop
  (`for i in $(seq 1 10); do mix test test/aiur/regression/agent_runner_lifecycle_test.exs --seed $RANDOM || break; done`)
  — resume-handle lifecycle (incl. terminal-state clearing owned by the
  orchestrator) unchanged.
- FI-ORC-070 spot-check: `mix test test/aiur/core_test.exs` — the
  `AgentRunner.run/3` end-to-end scenarios (prompts, max_turns, active-state
  continuation) drive the moved `run_session`/`run_turns` and pass unmodified.
- Confirm `git log --oneline` shows no commit touching
  `src/test/aiur/regression/` and the tripwire CI check (T-005) is green.
- Fleet health: the phase-3 aiur run on `v2` stays healthy after merge — agents
  start sessions, resume across restarts, and run multi-turn loops on every
  dispatch, exercising all four moved modules.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
