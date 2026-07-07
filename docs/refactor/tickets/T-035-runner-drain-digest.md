# T-035: agent_runner wave 2: QueueDrain, CheckpointDelivery, digests, CommentContext

**Phase:** 3
**Depends-on:** T-034
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_runner.ex` (2,215 lines at the start of this chain) is the
#8 regression hotspot in `docs/refactor/research-history-hotspots.md` (RC
prompt-delivery races, quota misclassification, the #552 queued-operator-message
drain, session-handle staleness #610/#701). The decomposition plan in
`docs/refactor/research-arch/giant-agent_runner.md` §2 splits it into 14 modules
under `src/lib/aiur/agent_runner/` across three strictly serialized tickets
(T-034 → T-035 → T-036). T-034 already extracted `SessionLifecycle`,
`SessionResume`, `TurnLoop`, and `TurnPrompt`; this ticket is wave 2 of 3.

This ticket extracts five modules — `Aiur.AgentRunner.QueueDrain`,
`Aiur.AgentRunner.CheckpointDelivery`, `Aiur.AgentRunner.EventsDigest`,
`Aiur.AgentRunner.BootstrapDigest`, and `Aiur.AgentRunner.CommentContext` —
carrying the queued-message drain, mid-turn checkpoint delivery, agent-visible
`<aiur:events>` digest rendering, first-turn bootstrap replay, and GitHub
comment-context fetch/filter concerns respectively.

This is a **verbatim code move, not a rewrite**. Function bodies, guards, clause
order, and every comment move unchanged. Public function signatures and all
observable behavior are unchanged; the parent module (`Aiur.AgentRunner`, the
retained facade) delegates so all existing callers keep working. The
never-convert-success-to-failure drain semantics and the no-eager-claim pause
protocol (both pinned by T-013 and enumerated in the research doc §4 risks) must
survive byte-for-byte. Line numbers below are from the pre-chain 2,215-line
state; T-034 has already moved code and shifted them, so **locate functions by
name** — the function names and their module assignments in the §2 name map are
the binding contract.

## Scope (exact)

Move each function listed to its assigned module **verbatim** (body, guards,
clause order, attached comments). Each moved `defp` becomes a `def` on the new
module with an added `@spec`; each new module gets a `@moduledoc`. The internal
wave order below is mandatory: leaves (`EventsDigest`, `CommentContext`) first,
then their dependents, then the receive-loop core (`QueueDrain`) last — so every
intermediate state compiles without forward stubs. Run the Agent gate after each
of steps 1–8.

1. **Create `src/lib/aiur/agent_runner/events_digest.ex`** defining
   `defmodule Aiur.AgentRunner.EventsDigest`. Move, verbatim, §1 section J
   (lines 1503–1685): `render_events_digest/2` (1503–1521) becomes public
   `render/2`; `author_trusted_for_digest?/1` (1538–1546); the debounce cluster
   `debounce_block_state_events/1`, `block_state_group_key/1`, `debounce_group/2`,
   `debounce_keep_or_drop/4`, `within_debounce_window?/3`,
   `block_state_debounce_seconds/0` (1553–1629); `render_event_line/1`,
   `event_field/2`, `event_summary/1` (1631–1648); `maybe_wrap_external_content/2`,
   `wrap_external/2`, `html_attr_escape/1` (1655–1685). Make `event_field/2`
   public (`@doc false`) — `BootstrapDigest`, `QueueDrain`, and
   `CheckpointDelivery` all use it. Aliases needed: `alias Aiur.Events.DebugLog`.
   **Move byte-for-byte** (research §4 "security-sensitive filters"): the
   default-untrusted github gate in `author_trusted_for_digest?/1`, the
   external-content wrap + `html_attr_escape/1` prompt-injection defense, and the
   `Enum.sort_by(..., :id)` ordering after debounce merge. The DebugLog `:read`
   audit broadcast (1504–1510) fires for **all** events **before** the trust
   filter — do not merge the audit path into the filtered agent-visible path.

2. **Create `src/lib/aiur/agent_runner/comment_context.ex`** defining
   `defmodule Aiur.AgentRunner.CommentContext`. Move, verbatim, §1 section C
   (lines 201–431): `current_comment_context_events/2` (207–223) becomes public
   `events/2` (keep the default-arg clause `events(issue, fetchers \\
   comment_context_fetchers())`); `issue_comment_context/2`,
   `pr_comment_context_events/3`, `pr_comment_context_events_for_pr/4`,
   `log_comment_context_open_pr_failed/2`, `comment_context_fetchers/0`,
   `fetch_comment_events/3`, `fetch_unaddressed_review_thread_events/3`,
   `comments_to_events/2`, `comments_after_workpad/2`,
   `latest_workpad_comment_datetime/1`, `latest_datetime/1`, `workpad_comment?/1`,
   `comment_after_cutoff?/2`, `comment_datetime/1`, `parse_comment_datetime/1`,
   `comment_context_event/2`, `comment_author/1`, `comment_body/1`,
   `comment_event_id/1`, `pr_number/1`. Aliases needed:
   `alias Aiur.{Issue, Tracker}` and `alias Aiur.Events.Sanitizer`. **Move
   byte-for-byte** (research §4): the `Sanitizer.scrub` + trust flag in
   `comment_context_event/2`, and the workpad-cutoff + unaddressed-review-thread
   exception (the #634→#642→#682 fix-of-fix chain lives exactly on this filter).
   Do NOT move `comment_event_id_or_nil/1` here — it belongs to `BootstrapDigest`
   (step 3).

3. **Create `src/lib/aiur/agent_runner/bootstrap_digest.ex`** defining
   `defmodule Aiur.AgentRunner.BootstrapDigest`. Move, verbatim, §1 section B
   (lines 150–199 and 433–509): `maybe_enqueue_bootstrap_digest/1` (150–172, both
   clauses incl. the no-op `_issue` fallback), `maybe_attach_universal_subscriptions/1`
   (182–186), `bootstrap_events/2` (188–199), `bootstrap_event_key/1` (433–439),
   `comment_event_id_or_nil/1` (441–448), `bootstrap_cursor_for_log/1` (450–451),
   `publisher_ids_for_patterns/1` and `publisher_ids_for_pattern/1` (460–473),
   `matches_any_pattern?/2` (475–483), `enqueue_bootstrap_if_any/3` (485–503),
   `enqueue_bootstrap_batch/2` (505–509). This module calls
   `CommentContext.events/1` (the former `current_comment_context_events(issue)`
   call at line 162) and `EventsDigest.event_field/2` (the sort key at line 167,
   `Enum.sort_by(&event_field(&1, :id))`). Aliases needed:
   `alias Aiur.Issue`, `alias Aiur.Events.UniversalSubscriptions`, and
   `alias Aiur.AgentRunner.{CommentContext, EventsDigest}` — plus whatever the
   moved bodies already reference (e.g. `Publisher`). **Move byte-for-byte**
   (research §4): the single batched `GenServer.call` in `enqueue_bootstrap_batch/2`
   (5s timeout, `catch :exit`) — do NOT reintroduce per-event orchestrator calls;
   the `system.*` publisher-log skip and wildcard-id pattern mapping in
   `bootstrap_events/2`/`publisher_ids_for_patterns/1` (documented replay gap —
   lock current behavior, do not "fix" it).

4. **Create `src/lib/aiur/agent_runner/checkpoint_delivery.ex`** defining
   `defmodule Aiur.AgentRunner.CheckpointDelivery`. Move, verbatim, §1 section L
   (lines 1759–1860): `operator_immediate_handler/2`, `immediate_operator_delivery/3`
   (1759–1775), `safe_checkpoint_handler/2`, `fallback_checkpoint_claim/3`
   (1777–1797), `urgent_checkpoint_delivery/4`, `render_urgent_events_digest/1`
   (1799–1815), `claim_blocker_critical_events_digest/2`,
   `claim_next_checkpoint_queue_item/2` (1817–1831), `safe_checkpoint_delivery/4`
   (1833–1842), `handle_checkpoint_delivery_failure/4` (1844–1860, all four
   clauses). This module calls `EventsDigest.render/2` (the
   `render_events_digest(events, ...)` call at 1811) and `QueueDrain.queue_item_text/1`
   (the fallback clause `render_urgent_events_digest(item), do: queue_item_text(item)`
   at 1815). Aliases needed: `alias Aiur.OperatorWaitLog` and
   `alias Aiur.AgentRunner.{EventsDigest, QueueDrain}` plus whatever the bodies
   reference. The `CheckpointDelivery ↔ QueueDrain` mutual runtime reference is
   expected and compiles fine (Elixir resolves cross-module calls at runtime).
   **Move byte-for-byte** (research §4 "never convert success to failure"):
   `handle_checkpoint_delivery_failure/4` restores on `:parent_turn_completed` /
   `{:turn_interrupted, _}` / `{:turn_cancelled, _}` and marks failed otherwise —
   these four clauses and their order are the FI-ORC-075 contract.

5. **Create `src/lib/aiur/agent_runner/queue_drain.ex`** defining
   `defmodule Aiur.AgentRunner.QueueDrain`. Move, verbatim, §1 section I
   (lines 1245–1501): `drain_operator_messages/5` (1245–1254),
   `wait_for_operator_message/5` (1278–1314, **including the no-eager-claim
   comment at 1270–1277** — move it verbatim above the function),
   `try_claim_after_queue_update/6` (1316–1329), `claim_after_queue_update/3`
   (1339–1343, both clauses) becomes public, `claim_and_run_or_continue/5`
   (1345–1353), `drain_queued_operator_messages/5` (1355–1364),
   `claim_next_queue_item/2`, `claim_next_wake_queue_item/2`,
   `claim_next_operator_item/2` (1366–1384), `run_operator_turn/6`,
   `run_queue_item_turn/6` (1386–1464), `queue_item_turn_id/1`,
   `record_operator_delivery/2`, `queue_item_text/1` (1466–1501).
   Make `queue_item_text/1` public (`@doc false`) — `CheckpointDelivery` uses it.
   `queue_item_text/1` calls `EventsDigest.render/2` (the `render_events_digest`
   call at 1487). Aliases needed: `alias Aiur.{AgentPubSub, OperatorWaitLog}`,
   `alias Aiur.Codex.DynamicTool`, and
   `alias Aiur.AgentRunner.{CheckpointDelivery, EventsDigest}` plus whatever the
   bodies reference.
   - **Forward references to wave-3 (T-036) concerns:** `run_queue_item_turn/6`
     (and `run_operator_turn/6` through it) references functions that are NOT
     extracted until T-036 and still live on the facade as public `@doc false`
     seams: `codex_message_handler/6`, `send_control_state/3` (→ MessageHandler),
     `open_aiur_turn_streams/1`, `close_aiur_turn_streams/3` (→ TurnStreams),
     `tool_executor/3` (→ ToolExecutor), `maybe_emit_usage_limit_alert/4`
     (→ TurnAlerts). Reference each of these **exactly as `turn_loop.ex` already
     references it** (T-034 made these facade functions public `@doc false` for
     that reason — match that call form verbatim, e.g. `AgentRunner.<name>(...)`).
     T-036 repoints all such references to their final modules. Do NOT change the
     visibility of, or move, any of these facade functions in this ticket.
     Likewise reference `turn_done_reason/1` (TurnLoop, T-034),
     `session_workspace/1` / `session_worker_host/1` / `session_backend/1`
     (SessionLifecycle, T-034), and `write_pause_log/2` / `issue_context/1`
     (facade concern A) at their current homes exactly as `turn_loop.ex` does.
   - **Preserve the concurrency semantics verbatim** (research §4 risks): every
     receive loop stays a plain function call that keeps executing IN the runner
     Task process — do NOT wrap `wait_for_operator_message/5`,
     `drain_operator_messages/5`, or any moved function in a new process,
     `Task.async`, or `GenServer`; wrapping silently loses `:pause_agent` /
     `:resume_agent` / `:agent_queue_updated` control messages. Keep
     `wait_for_operator_message`'s no-eager-claim behavior (claims only on
     `deliver_now? == true`; re-parks on `:pause_agent`). Keep
     `drain_operator_messages`'s `receive ... after 0` ordering (pending
     `:pause_agent` wins over draining). Keep the exactly-once queue-item
     settlement in `run_queue_item_turn/6`: the
     `{:error, {:turn_start_failed, :response_timeout | :turn_timeout}}` clause
     (1445–1453) **restores** the item and returns `:ok` (requeue-after-parent-turn,
     never a failure); do not duplicate or drop the `consume` / `restore` / `fail`
     branches.

6. **Edit the facade `src/lib/aiur/agent_runner.ex`:**
   - Add `alias Aiur.AgentRunner.{BootstrapDigest, CheckpointDelivery,
     CommentContext, EventsDigest, QueueDrain}` next to the existing
     `agent_runner/` submodule aliases T-034 added.
   - Delete every moved definition (and its moved comments) from the facade.
   - Repoint the one facade caller of a moved function:
     `run_worker_attempt_once/5` (concern A, stays in the facade) calls
     `maybe_enqueue_bootstrap_digest(issue)` at line 108 → change to
     `BootstrapDigest.maybe_enqueue_bootstrap_digest(issue)`.
   - **Retain three `*_for_test` wrappers** on the facade as one-line public
     `@doc false` delegations (keep their existing `@spec`), because tests call
     them and the T-013 guarded regression file calls two of them and must pass
     unmodified:
     - `render_events_digest_for_test(events, id)` → `EventsDigest.render(events, id)`
     - `claim_after_queue_update_for_test(orch, id, deliver_now?)` →
       `QueueDrain.claim_after_queue_update(orch, id, deliver_now?)`
     - `current_comment_context_events_for_test(issue, fetchers)` →
       `CommentContext.events(issue, fetchers)`
   - Mechanical delegate loop for any OTHER moved function still referenced by
     remaining facade code: add a one-line delegating `defp` with the same
     name/arity, run `mix compile --warnings-as-errors`, delete exactly the
     delegates the compiler reports as unused, repeat until clean (an unused
     `defp` fails `--warnings-as-errors`).

7. **Edit T-034's `src/lib/aiur/agent_runner/` files that reference a moved
   function** (locate by grep; `turn_loop.ex` is the known caller,
   `session_lifecycle.ex` if grep finds a reference — repoint only, no logic
   edits). `turn_loop.ex`'s `do_run_codex_turns` spine (and `wait_for_resume` /
   `finalize_turn_completion`) reference `drain_operator_messages`,
   `wait_for_operator_message` (→ `QueueDrain.*`), `safe_checkpoint_handler`,
   and `operator_immediate_handler` (→ `CheckpointDelivery.*`). Repoint every
   such reference to the new module; add the matching alias. Run
   `grep -rEn "drain_operator_messages|wait_for_operator_message|safe_checkpoint_handler|operator_immediate_handler|render_events_digest|current_comment_context_events|maybe_enqueue_bootstrap_digest|urgent_checkpoint_delivery|handle_checkpoint_delivery_failure" src/lib/aiur/agent_runner/` and confirm zero unqualified (non-`ModuleName.`) references remain.

8. **Create one test file per new module** under `src/test/aiur/agent_runner/`
   (new files; never touch any existing test file). Follow the authoring rules
   in `docs/refactor/regression-safety.md` §2 (no `Process.sleep`; every
   `assert_receive` window ≥ 2000 ms; unique orchestrator names + issue
   identifiers per test; `async: false`):
   - `events_digest_test.exs` — cover `EventsDigest.render/2`: github event
     missing `author_trusted?` is dropped from agent-visible text but still
     DebugLog-broadcast (`:read`); `author_trusted?: false` dropped; trusted
     github content wrapped in escaped `<external-content source="github"
     author="...">`; non-github events pass through unwrapped; block/unblock
     within the default 10s window collapses to the latest id; missing timestamps
     always collapse; outside-window survivors both render ordered by id;
     different tickets do not collapse together. (FI-ORC-074.)
   - `comment_context_test.exs` — cover `CommentContext.events/2` with injected
     `fetchers`: issue comments after the `## Agent Workpad` cutoff, PR
     conversation + review comments, unaddressed review threads regardless of
     cutoff, dedupe by (topic, comment id), `Sanitizer.scrub` applied, fetch
     failure degrades to `[]`. (FI-ORC-065.)
   - `bootstrap_digest_test.exs` — cover `bootstrap_events/2` pattern→publisher-log
     mapping incl. the `system.*` skip and wildcard-id patterns; the single
     batched `enqueue_bootstrap_batch/2` (one `GenServer.call`, not N); the no-op
     `maybe_enqueue_bootstrap_digest/1` fallback for a non-binary identifier.
     (FI-ORC-065.)
   - `checkpoint_delivery_test.exs` — cover `handle_checkpoint_delivery_failure/4`
     all four clauses (restore on `:parent_turn_completed` /
     `{:turn_interrupted, _}` / `{:turn_cancelled, _}`, mark-failed otherwise) and
     `render_urgent_events_digest/1` events-vs-fallback branches, driven through
     the orchestrator queue seam / pure inputs. (FI-ORC-075.)
   - `queue_drain_test.exs` — cover the drivable pure/claim helpers:
     `claim_after_queue_update/3` (`true` claims, `false` → `:ignored`),
     `queue_item_turn_id/1` extraction clauses, and `queue_item_text/1` rendering
     (events_digest item → `EventsDigest.render/2`, operator item → text).
     Exactly-once accounting is driven through the orchestrator queue API
     (`claim_next_queue_item` / `consume_delivered_queue_items` /
     `restore_delivered_queue_items` / `fail_delivered_queue_items`), mirroring
     T-013's approach. The private receive loops
     (`wait_for_operator_message/5`, `drain_operator_messages/5`) are NOT directly
     drivable without production changes — do NOT add test-only exports to reach
     them; their process-identity + never-success-to-failure semantics stay pinned
     by `core_test.exs` and the T-013 regression file. (FI-ORC-072, FI-ORC-073.)

## Files

- Create:
  `src/lib/aiur/agent_runner/events_digest.ex`,
  `src/lib/aiur/agent_runner/comment_context.ex`,
  `src/lib/aiur/agent_runner/bootstrap_digest.ex`,
  `src/lib/aiur/agent_runner/checkpoint_delivery.ex`,
  `src/lib/aiur/agent_runner/queue_drain.ex`,
  `src/test/aiur/agent_runner/events_digest_test.exs`,
  `src/test/aiur/agent_runner/comment_context_test.exs`,
  `src/test/aiur/agent_runner/bootstrap_digest_test.exs`,
  `src/test/aiur/agent_runner/checkpoint_delivery_test.exs`,
  `src/test/aiur/agent_runner/queue_drain_test.exs`
- Modify:
  `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/agent_runner/turn_loop.ex`,
  `src/lib/aiur/agent_runner/session_lifecycle.ex` (only if step-7 grep finds a
  reference to a moved function; repoint only, no logic edits)
- Test: the five created test files above; all existing
  `src/test/aiur/agent_runner_test.exs`, `src/test/aiur/core_test.exs`,
  `src/test/aiur/issue_log_event_history_test.exs`, and
  `src/test/aiur/regression/` files run unmodified as the behavior pin.

## Out of scope

- The T-036 modules — `MessageHandler`, `TurnStreams`, `ToolExecutor`,
  `TurnAlerts` — and their functions (`codex_message_handler/6`,
  `send_control_state/3`, `maybe_broadcast_transcript/4`, `open_aiur_turn_streams/1`,
  `post_aiur_turn_markers/4`, `close_aiur_turn_streams/3`, `tool_executor/3`,
  `declare_blocker_for_issue/2`, `maybe_emit_usage_limit_alert/4`,
  `maybe_emit_more_tokens_alert/4`, …). They STAY on the facade this wave; do not
  move them, do not change their visibility.
- Concern A (run entry / worker-attempt lifecycle: `run/3`,
  `transient_run_error?/1`, `run_worker_attempt_once/5`, `write_pause_log`,
  `issue_context/1`, worker-host selection) — stays on the facade permanently.
- The T-034 modules `SessionLifecycle`, `SessionResume`, `TurnLoop`, `TurnPrompt`
  — do not re-extract or refactor; touch `turn_loop.ex` / `session_lifecycle.ex`
  ONLY to repoint references to functions this ticket moves.
- Deduplicating the shared execute-one-turn spine between `do_run_codex_turns/10`
  and `run_queue_item_turn/6` — an explicit post-wave follow-up (research §2), NOT
  part of this mechanical move.
- `src/mix.exs` `test_coverage.ignore_modules` — do NOT add the five new modules
  (new modules are not coverage-exempt; the 85% threshold enforces their tests)
  and do NOT remove or reorder any entry; `Aiur.AgentRunner` (the facade) stays
  exempt. No `mix.exs` edit is required.
- Any behavior, signature, log-message, config, timer, or `receive`-clause change
  whatsoever.
- Any edit to any existing file under `src/test/` (including the T-013 guarded
  regression file and `agent_runner_test.exs`).
- Other giant files (`orchestrator.ex`, `github/client.ex`, `init.ex`, …).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` — the features whose implementing
functions this ticket moves (behavior must be identical after the move):

- FI-ORC-065 — Universal subscriptions + bootstrap event digest at runner start
  (`BootstrapDigest`: `maybe_enqueue_bootstrap_digest`, `bootstrap_events`, single
  batched enqueue; `CommentContext`: issue/PR comment context after workpad
  cutoff, unaddressed review threads, dedupe).
- FI-ORC-072 — Turn result → queue item settlement, incl. the
  `:turn_start_failed` restore (`QueueDrain.run_queue_item_turn`, exactly-once
  consume/restore/fail).
- FI-ORC-073 — Paused wait loop: explicit wake only / no eager claim
  (`QueueDrain.wait_for_operator_message`, `claim_after_queue_update`).
- FI-ORC-074 — Events digest rendering: trust filter, debounce, external-content
  wrap (`EventsDigest.render`, `author_trusted_for_digest?`, debounce cluster,
  `maybe_wrap_external_content`/`html_attr_escape`).
- FI-ORC-075 — Safe-checkpoint mid-turn delivery, blocker-critical first
  (`CheckpointDelivery.safe_checkpoint_handler`, `urgent_checkpoint_delivery`,
  `handle_checkpoint_delivery_failure` restore-vs-fail policy).
- FI-ORC-076 — Immediate operator delivery for the REPL backend
  (`CheckpointDelivery.operator_immediate_handler`,
  `immediate_operator_delivery`; `QueueDrain.claim_next_operator_item`).

## Characterization-tests

These files under `src/test/aiur/regression/` protect this ticket's area and
must pass **UNMODIFIED**; the entire `src/test/aiur/regression/` directory runs
unchanged:

- `src/test/aiur/regression/agent_runner_lifecycle_test.exs` (landed by T-013) —
  the primary pin: the "queued-message drain accounting (#552 class: success
  never becomes failure)" describe block, the "events-digest filtering" describe
  block, and the session-resume block. This file calls
  `AgentRunner.render_events_digest_for_test/2` and
  `AgentRunner.claim_after_queue_update_for_test/3` — the two `*_for_test`
  wrappers step 6 retains on the facade for exactly this reason.
- `src/test/aiur/regression/event_flow_e2e_test.exs` — digest render through the
  runner-visible closure.

Non-guarded existing pins that must also stay green and untouched:
`src/test/aiur/agent_runner_test.exs` (digest trust rendering, wake claiming),
`src/test/aiur/core_test.exs` (`AgentRunner.run/3` end-to-end drain/pause/resume
scenarios — the strongest guard for the receive-loop moves),
`src/test/aiur/issue_log_event_history_test.exs` (bootstrap replay from publisher
logs), `src/test/aiur/claude/repl_agent_test.exs` (immediate operator delivery).

A failing characterization test means your change is wrong. Never edit the test.
Stop: comment on the issue describing the failing test, emit `emit_alert` with
`needs_attention: true`, and end your turn without opening a PR.

## Acceptance criteria

All checks run from `src/`; every one must hold.

- The five new modules exist at their exact paths:
  - `grep -c "^defmodule Aiur.AgentRunner.EventsDigest do" lib/aiur/agent_runner/events_digest.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.CommentContext do" lib/aiur/agent_runner/comment_context.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.BootstrapDigest do" lib/aiur/agent_runner/bootstrap_digest.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.CheckpointDelivery do" lib/aiur/agent_runner/checkpoint_delivery.ex` == 1
  - `grep -c "^defmodule Aiur.AgentRunner.QueueDrain do" lib/aiur/agent_runner/queue_drain.ex` == 1
- Each new module has a `@moduledoc`: `grep -c "@moduledoc" <file>` >= 1 for all
  five lib files. `mix credo --strict` (which runs `specs.check`) passes, proving
  an `@spec` on every public def.
- The moved concerns are gone from the facade (all five == 0):
  - `grep -cE "defp (render_events_digest|author_trusted_for_digest\?|debounce_block_state_events|maybe_wrap_external_content)\(" lib/aiur/agent_runner.ex` == 0
  - `grep -cE "defp (current_comment_context_events|comment_context_event|workpad_comment\?)\(" lib/aiur/agent_runner.ex` == 0
  - `grep -cE "defp (maybe_enqueue_bootstrap_digest|bootstrap_events|enqueue_bootstrap_batch)\(" lib/aiur/agent_runner.ex` == 0
  - `grep -cE "defp (safe_checkpoint_handler|urgent_checkpoint_delivery|handle_checkpoint_delivery_failure)\(" lib/aiur/agent_runner.ex` == 0
  - `grep -cE "defp (drain_operator_messages|wait_for_operator_message|run_queue_item_turn|claim_after_queue_update)\(" lib/aiur/agent_runner.ex` == 0
- No `case`/`if` on a removed concern remains in the facade:
  - `grep -c "turn_start_failed" lib/aiur/agent_runner.ex` == 0 (the
    never-success-to-failure branch moved to `queue_drain.ex`)
  - `grep -c "author_trusted_for_digest" lib/aiur/agent_runner.ex` == 0
  - `grep -c "workpad" lib/aiur/agent_runner.ex` == 0
- The three retained `*_for_test` wrappers are one-line delegations on the facade:
  - `grep -cE "def (render_events_digest_for_test|claim_after_queue_update_for_test|current_comment_context_events_for_test)\(" lib/aiur/agent_runner.ex` == 3
  - each delegates: `grep -A2 "def render_events_digest_for_test" lib/aiur/agent_runner.ex` shows a `EventsDigest.render(` body (and likewise `QueueDrain.claim_after_queue_update(` / `CommentContext.events(`).
- No unqualified reference to a moved function remains anywhere under
  `lib/aiur/agent_runner/` (step-7 grep returns only `ModuleName.`-qualified
  hits or definitions in the owning module).
- Parent file shrank: `wc -l < lib/aiur/agent_runner.ex` <= 1050 (it holds only
  concern A + the not-yet-moved T-036 concerns + delegates after this wave).
- File-size budget (per the research §2 ~LOC estimates; these cohesive moves
  cannot fit the generic 200-line norm without rewriting, which is forbidden):
  `events_digest.ex` <= 240, `comment_context.ex` <= 300, `bootstrap_digest.ex`
  <= 200, `checkpoint_delivery.ex` <= 170, `queue_drain.ex` <= 320. No NEW
  function (anything not moved verbatim — i.e. the delegates) exceeds 20 logic
  lines; moved bodies are not rewritten to game any limit.
- New modules are covered, not exempt:
  - `grep -cE "Aiur\.AgentRunner\.(EventsDigest|CommentContext|BootstrapDigest|CheckpointDelivery|QueueDrain)" mix.exs` == 0
  - all five test files exist:
    `ls test/aiur/agent_runner/{events_digest,comment_context,bootstrap_digest,checkpoint_delivery,queue_drain}_test.exs`
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

- `cd src && mix test --cover` — the 85% threshold passes with the five new
  modules counted (none in `ignore_modules`).
- Diff review: every hunk in `src/lib/aiur/agent_runner.ex` is a deletion, a
  one-line delegate, an alias line, or the single `BootstrapDigest.` repoint;
  every hunk in `turn_loop.ex` (and `session_lifecycle.ex` if touched) is a
  `QueueDrain.` / `CheckpointDelivery.` repoint plus an alias — zero logic edits.
  The five new lib files contain only moved bodies plus `@moduledoc`/`@spec`/aliases.
- Check FI-ORC-072 / FI-ORC-073 (never-success-to-failure + no-eager-claim): run
  `mix test test/aiur/regression/agent_runner_lifecycle_test.exs --seed 0` and
  `mix test test/aiur/core_test.exs` alone — both green; the "restore" and
  "deliver_now? false is ignored" tests pass unchanged.
- Check FI-ORC-074 (digest trust/debounce/wrap): the events-digest describe
  block in the T-013 regression file passes; spot-check
  `AgentRunner.render_events_digest_for_test([%{id: 1, topic: "ticket.X.issue.commented", source: :github, message: "x"}], "X")` in `iex -S mix` drops the untrusted line (the wrapper still delegates).
- Check FI-ORC-065 (bootstrap single batched enqueue): run
  `mix test test/aiur/issue_log_event_history_test.exs` alone — green;
  `enqueue_bootstrap_batch/2` still issues one `GenServer.call`.
- Check FI-ORC-075 / FI-ORC-076 (checkpoint restore-vs-fail + immediate delivery):
  run `mix test test/aiur/claude/repl_agent_test.exs` alone — green.
- Confirm `git log --oneline` shows no commit touching `src/test/aiur/regression/`
  and the tripwire CI check (T-005) is green.
- Fleet health: the phase-3 aiur run on `v2` stays healthy after merge (queued
  operator messages, mid-turn checkpoints, and event digests exercise the moved
  code on every turn).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
