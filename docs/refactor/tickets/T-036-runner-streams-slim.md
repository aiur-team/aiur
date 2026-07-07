# T-036: agent_runner wave 3: MessageHandler, TurnStreams, ToolExecutor, TurnAlerts; slim

**Phase:** 3
**Depends-on:** T-035
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_runner.ex` began this refactor at 2,215 lines — the single
module driving one issue from claim to teardown, and the seam behind the
timing/submission-race hotspots (`docs/refactor/research-history-hotspots.md`
row 8 "agent backends", theme 1 "timing/submission races"). The behavior-
preserving decomposition and its **binding name map** are in
`docs/refactor/research-arch/giant-agent_runner.md` §2 (rows 11–14 and the
retained-facade row 1); §4 (Risks) names the semantics that must move verbatim.

T-034 extracted the session/turn spine (`SessionLifecycle`, `SessionResume`,
`TurnLoop`, `TurnPrompt`) and T-035 extracted the drain/digest/context cluster
(`QueueDrain`, `CheckpointDelivery`, `EventsDigest`, `BootstrapDigest`,
`CommentContext`). This is the **final agent_runner wave**: extract the last
four per-turn concerns — `Aiur.AgentRunner.MessageHandler`,
`Aiur.AgentRunner.TurnStreams`, `Aiur.AgentRunner.ToolExecutor`,
`Aiur.AgentRunner.TurnAlerts` — then slim `Aiur.AgentRunner` to concern A only
(run entry + worker-attempt lifecycle). After this wave the original ~2,215-line
body is gone and `agent_runner.ex` is the thin facade the name map (row 1)
specifies (`run/3`, `transient_run_error?/1`, worker-host selection, workspace
creation, before/after_run hooks, before_run pause/resume).

The already-extracted sibling modules `turn_loop.ex` (T-034) and
`queue_drain.ex` (T-035) call these four concerns from the per-turn spine; those
call sites are repointed to the new modules in this ticket. `run/3`,
`transient_run_error?/1`, and the public `post_aiur_turn_markers/4` surface stay
callable from `Aiur.AgentRunner` unchanged (orchestrator + test contract).

## Scope (exact)

**Binding name map:** `docs/refactor/research-arch/giant-agent_runner.md` §2,
rows 11 (`MessageHandler`), 12 (`TurnStreams`), 13 (`ToolExecutor`), 14
(`TurnAlerts`), and row 1 (retained facade). Module names, file paths, function-
to-module assignments, and the public-API renames below are taken verbatim from
that table and are **not negotiable**. Read §4 (Risks) before writing a line.

**Line numbers cannot be trusted this wave.** T-034 and T-035 already moved
~1,600 lines out of `agent_runner.ex`, so every line range in the research doc
and below has shifted. **Locate every function by name and arity**, never by
line number. The parenthetical line ranges below are the *pre-refactor* census
from the research doc, given only to identify which body is which.

**Decomposition-wave rules (apply to every extraction in this ticket):**

- Move code **verbatim** — extract, do not rewrite. Do not reformat beyond what
  `mix format` does, do not rename variables, do not "improve", do not collapse
  clauses, do not re-scope a `case`/`with`. Comments move with their function.
- Public function **signatures and observable behavior are unchanged**. Return-
  tuple shapes, message tuples sent to the recipient pid, topic strings, and
  `Logger` message strings stay byte-identical.
- The parent `Aiur.AgentRunner` and the sibling per-turn modules **delegate** to
  the extracted modules; every caller keeps working. No module imports the
  facade (dependency direction is strictly downward, research doc §2).
- A `defp` that moves out becomes a `def` (`@doc false` where it stays internal
  test/sibling surface) in its new module, renamed only where the name map's
  "public API" column dictates (see step renames below).
- Every new module gets a `@moduledoc` (2–4 sentences derived from the
  responsibility sentence in the name-map row) and an `@spec` on every public
  `def` (`mix specs.check` enforces this).
- Every new module gets its own test file (step 7). New modules are **NOT**
  coverage-exempt — do not add them to `ignore_modules` in `src/mix.exs`; the
  85% coverage threshold enforces that tests exist.
- After every sub-step: `mix compile --warnings-as-errors` and the full
  `mix test` pass. Commit each sub-step separately.

Execute as four extraction sub-steps (steps 1–4), then repoint callers (step 5),
then slim the facade (step 6), then tests (step 7). Sub-modules of
`Aiur.AgentRunner` live under `src/lib/aiur/agent_runner/` (in-repo precedent:
`Aiur.Orchestrator.TrackedSet` at `src/lib/aiur/orchestrator/tracked_set.ex`).

### Step 1: `Aiur.AgentRunner.MessageHandler`

1. Create `src/lib/aiur/agent_runner/message_handler.ex` — module
   `Aiur.AgentRunner.MessageHandler`. Move verbatim, renaming only where noted
   (research doc §2 row 11; census §D, pre-refactor lines 511–632 + 1687–1693):
   - `codex_message_handler/6` → **rename to public `build/6`** (keep the
     `turn_id \\ nil` default; it returns the `fn message -> … end` on_message
     closure).
   - `send_control_state/3` → public `@doc false` (keep the name; both clauses,
     the `status in [:paused, :working]` guard and the catch-all).
   - `send_worker_runtime_info/4` → public `@doc false` (keep the name; both
     clauses).
   - Private (stay `defp`): `maybe_broadcast_transcript/4`,
     `maybe_broadcast_turn_event/3`, `transcript_event_from/3`,
     `legacy_transcript_event/2`, `role_for_event/1`, `event_kind/1`,
     `body_for_event/1`, `get/2`, `timestamp_for/1`, `send_codex_update/3`.
   `MessageHandler` aliases `Aiur.{AgentEventLog, AgentEvents, AgentPubSub,
   CodingAgent, Issue}`; every `AgentEventLog.write`, `AgentPubSub.*`,
   `CodingAgent.normalize_event`/`transcript_module`, and `AgentEvents.*` call
   moves unchanged.

### Step 2: `Aiur.AgentRunner.TurnStreams`

2. Create `src/lib/aiur/agent_runner/turn_streams.ex` — module
   `Aiur.AgentRunner.TurnStreams`. Move verbatim, renaming only where noted
   (research doc §2 row 12; census §K, pre-refactor lines 1704–1750):
   - `open_aiur_turn_streams/1` → **rename to public `open/1`** (both clauses;
     the `Issue` clause and the catch-all returning `nil`).
   - `post_aiur_turn_markers/4` → **keep the name**, public (keep its `@doc`,
     `@spec`, and the `post_fn \\ &ApiClient.post_message/3` default). `open/1`
     calls it locally as `post_aiur_turn_markers(...)`.
   - `close_aiur_turn_streams/3` → **rename to public `close/3`** (both clauses).
   `TurnStreams` aliases `Aiur.{AgentPubSub, Issue}` and
   `Aiur.Opencode.{ActiveTurns, ApiClient, SessionWriterRegistry, TurnMarkers}`.

### Step 3: `Aiur.AgentRunner.ToolExecutor`

3. Create `src/lib/aiur/agent_runner/tool_executor.ex` — module
   `Aiur.AgentRunner.ToolExecutor`. Move verbatim, renaming only where noted
   (research doc §2 row 13; census §M, pre-refactor lines 2005–2149):
   - `tool_executor/3` → **rename to public `build/3`** (returns the `fn tool,
     arguments -> DynamicTool.execute(...) end` closure with all six injected
     closures — `alert_emitter`, `event_publisher`, `subscriber`,
     `unsubscriber`, `blocker_declarer`, `unblocker` — moved byte-for-byte).
   - Private (stay `defp`): `prefix_with_ticket_namespace/2`,
     `declare_blocker_for_issue/2`, `unblock_for_issue/2`, `issue_number_of/1`,
     `subscribe_for_issue/2`, `unsubscribe_for_issue/2`, `issue_identifier/1`,
     `emit_agent_event/4`.
   `ToolExecutor` aliases `Aiur.{Alerts, Issue, Orchestrator}`,
   `Aiur.Codex.DynamicTool`, `Aiur.Events.{Publisher, SubscriptionStore}`, and
   `Aiur.GitHub.IssueDependencies`; the
   `Aiur.Orchestrator.subscribe_for_declared_blocker/2` call inside
   `declare_blocker_for_issue/2` moves unchanged.

### Step 4: `Aiur.AgentRunner.TurnAlerts`

4. Create `src/lib/aiur/agent_runner/turn_alerts.ex` — module
   `Aiur.AgentRunner.TurnAlerts`. Move verbatim (research doc §2 row 14; census
   §N, pre-refactor lines 2156–2210):
   - `maybe_emit_usage_limit_alert/4` → public (keep name; both clauses — the
     `%{kind: :usage_limit_exhausted}` clause and the catch-all).
   - `maybe_emit_more_tokens_alert/4` → public (keep name).
   - `more_tokens_reason?/1` → private (stay `defp`; the `inspect/1` +
     `String.contains?/2` substring list moves byte-for-byte).
   `TurnAlerts` aliases `Aiur.{Alerts, Issue}`.

### Step 5: repoint every caller to the new modules

5. Locate every remaining call site of the moved functions **by name** across
   `src/lib/aiur/agent_runner.ex` and `src/lib/aiur/agent_runner/` (the callers
   are the facade's concern-A path plus the already-extracted `turn_loop.ex` and
   `queue_drain.ex`). Repoint each to its new module and renamed function:
   - `codex_message_handler(...)` → `MessageHandler.build(...)`
   - `send_control_state(...)` → `MessageHandler.send_control_state(...)`
   - `send_worker_runtime_info(...)` → `MessageHandler.send_worker_runtime_info(...)`
   - `open_aiur_turn_streams(issue)` → `TurnStreams.open(issue)`
   - `close_aiur_turn_streams(...)` → `TurnStreams.close(...)`
   - `tool_executor(...)` → `ToolExecutor.build(...)`
   - `maybe_emit_usage_limit_alert(...)` → `TurnAlerts.maybe_emit_usage_limit_alert(...)`
   - `maybe_emit_more_tokens_alert(...)` → `TurnAlerts.maybe_emit_more_tokens_alert(...)`
   Add the corresponding `alias Aiur.AgentRunner.{MessageHandler, TurnStreams,
   ToolExecutor, TurnAlerts}` (as needed per file) to each caller file. If a
   caller currently reaches one of these through a **transitional public
   `@doc false` function on `Aiur.AgentRunner`** (left by T-034/T-035 so the
   earlier-extracted `turn_loop.ex`/`queue_drain.ex` could call it), replace that
   `AgentRunner.<fn>` call with a direct call to the new module and **delete the
   transitional facade function** — no module may call back into the facade.

### Step 6: retain the marker wrapper and slim the facade

6. In `agent_runner.ex`, after step 5:
   - **Retain a public wrapper** `def post_aiur_turn_markers(identifier,
     aiur_turn_id, writers, post_fn \\ &ApiClient.post_message/3), do:
     TurnStreams.post_aiur_turn_markers(identifier, aiur_turn_id, writers,
     post_fn)` (keep its `@doc` and `@spec`; NOT `defdelegate`, so the default-
     arg arity survives). This wrapper is load-bearing: the guarded regression
     pin `agent_runner_test.exs` and T-013's fan-out census both call
     `AgentRunner.post_aiur_turn_markers/4` and must pass unmodified.
   - Delete the four moved-function bodies and every alias / module attribute
     your moves orphaned (`AgentEventLog`, `AgentEvents`, `AgentPubSub`,
     `Alerts`, `DynamicTool`, `Publisher`, `SubscriptionStore`,
     `IssueDependencies`, `ActiveTurns`, `SessionWriterRegistry`, `TurnMarkers`,
     etc. — keep only aliases the retained concern-A path still uses, plus
     `ApiClient` and the four new `Aiur.AgentRunner.*` aliases the wrapper /
     repointed callers need). Leave `run/3`, `transient_run_error?/1`, and the
     rest of concern A untouched.

**Preserve verbatim (research doc §4 Risks) — must survive byte-for-byte:**

- **Register-before-post** (`TurnStreams.open/1`): `ActiveTurns.put/2` must
  precede `post_aiur_turn_markers/4`, or the bridge treats live markers as
  phantom. `close/3` must reuse the same `aiur_turn_id` and call **both**
  `AgentPubSub.broadcast_aiur_turn_done/3` and `ActiveTurns.mark_closed/3`
  (FI-ORC-071; pinned by `opencode/active_turns_test.exs` and T-013's census).
- **Fire-and-forget markers**: `post_aiur_turn_markers/4` returns immediately
  even with slow/blocking posters and swallows post errors (delegates to
  `Opencode.TurnMarkers.post_all/4`). Do **not** add synchronous waiting or
  change the return to anything but `:ok` (pinned by `agent_runner_test.exs`).
- **Transcript vs audit split** (`MessageHandler.build/6`): every backend
  message is normalized, written to `AgentEventLog`, broadcast as a transcript
  event (falling back to `legacy_transcript_event/2` for
  `agent_message`/`task_finished`; empty bodies skipped), broadcast as a turn
  event only when a binary `turn_id` is present, then forwarded to the
  orchestrator as `{:codex_worker_update, issue_id, message}` — do not reorder,
  drop, or merge these (FI-ORC-079). `send_control_state/3` and
  `send_worker_runtime_info/4` no-op for unknown/non-pid recipients
  (FI-ORC-062). The DisplayTailer deliberately does **not** route through this
  handler — do not wire `MessageHandler.build/6` into `SessionLifecycle`'s
  tailer (that module is out of scope; leave it).
- **Immediate blocker subscribe** (`ToolExecutor`): `declare_blocker_for_issue/2`
  calls `Orchestrator.subscribe_for_declared_blocker/2` immediately on the
  `{:ok, _}` result (which covers `:already_present`), bypassing GitHub poll
  lag; without it the blockee never auto-resumes (FI-ORC-049, FI-ORC-077).
  `prefix_with_ticket_namespace/2` passes `ticket.`/`system.` names through
  unchanged and namespaces others as `ticket.<id>.agent.<name>`;
  `emit_agent_event/4` maps `Publisher` `:filtered`→`{:error, :event_filtered}`
  and `:deduped`→`{:error, :event_deduped}`. Move all branches intact.
- **Alert gating** (`TurnAlerts`): `maybe_emit_usage_limit_alert/4` fires only
  for `%{kind: :usage_limit_exhausted}` (ordinary pauses no-op);
  `more_tokens_reason?/1` is substring matching over `inspect(reason)` — fragile
  by design, move byte-for-byte, do not "harden" it (FI-ORC-078).

### Step 7: tests for the new modules (NOT coverage-exempt)

7. Create one test file per extracted module under
   `src/test/aiur/agent_runner/` (`async: true` — all four are pure closure
   builders / message senders reached with a `self()` recipient or injected
   stubs, no global state). Drive each module's public functions; use
   `assert_receive`/`refute_receive` (windows `>= 2_000` ms) and injected
   `post_fn`/stub closures. Copy stub shapes from
   `src/test/aiur/agent_runner_test.exs`. Required coverage per file (add more
   if trivial, never fewer):
   - `message_handler_test.exs` (`Aiur.AgentRunner.MessageHandlerTest`):
     `build/6` returns a 1-arity closure that, when called with a message,
     forwards `{:codex_worker_update, issue_id, message}` to a `self()`
     recipient (`assert_receive`) and, for a binary `identifier`, broadcasts a
     transcript event (subscribe via `AgentPubSub`); a message with an empty
     body is skipped (no transcript broadcast); `send_control_state/3` sends
     `{:worker_control_state, id, :paused}` / `:working` to a pid and no-ops for
     `nil`/non-pid recipient and for a non-binary issue id;
     `send_worker_runtime_info/4` sends `{:worker_runtime_info, id, %{worker_host:
     _, workspace_path: _}}`; `event_kind/1`/`get/2` tolerate both atom- and
     string-keyed maps.
   - `turn_streams_test.exs` (`Aiur.AgentRunner.TurnStreamsTest`): `open/1`
     registers the id in `ActiveTurns` **before** posting (drive with an
     attached writer whose stubbed `post_fn` asserts `ActiveTurns` already
     shows `:active`), returns a binary `aiur_turn_id`, and returns `nil` for a
     non-`Issue`; `close/3` broadcasts `aiur_turn_done` and marks the entry
     closed (subscribe to the turn-done broadcast); `post_aiur_turn_markers/4`
     fires exactly one post per attached writer, returns `:ok`, and returns `:ok`
     even when the `post_fn` raises/returns an error (fire-and-forget).
   - `tool_executor_test.exs` (`Aiur.AgentRunner.ToolExecutorTest`): `build/3`
     returns a 2-arity closure; `prefix_with_ticket_namespace/2` passes
     `ticket.*`/`system.*` through and namespaces a bare name as
     `ticket.<id>.agent.<name>`; `emit_agent_event/4` publishes
     `ticket.<id>.agent.<name>` and maps a filtered/deduped publish to
     `{:error, :event_filtered}`/`{:error, :event_deduped}`;
     `declare_blocker_for_issue/2` returns `{:error, :no_issue_number}` for an
     issue with no number. (Reach the private helpers through `build/3`'s
     injected closures, or make the minimal set `@doc false` public as the name
     map allows — do not add test-only exports beyond the name map.)
   - `turn_alerts_test.exs` (`Aiur.AgentRunner.TurnAlertsTest`):
     `maybe_emit_usage_limit_alert/4` emits the
     `ticket.<id>.agent.usage_limit_exhausted` alert for a
     `%{kind: :usage_limit_exhausted}` payload and is a no-op for any other
     payload; `maybe_emit_more_tokens_alert/4` emits
     `ticket.<id>.agent.error.tokens_exhausted` when the reason contains a match
     phrase (e.g. `"token budget"`, `"context length"`) and is a no-op
     otherwise. Mirror the alert-assertion pattern in
     `src/test/aiur/alerts_test.exs`.
8. Do **not** add any of the four new modules
   (`Aiur.AgentRunner.MessageHandler`, `.TurnStreams`, `.ToolExecutor`,
   `.TurnAlerts`) to `ignore_modules` in `src/mix.exs`. Do not remove
   `Aiur.AgentRunner` from it either (that is not this ticket).

## Files

- Create:
  - `src/lib/aiur/agent_runner/message_handler.ex`
  - `src/lib/aiur/agent_runner/turn_streams.ex`
  - `src/lib/aiur/agent_runner/tool_executor.ex`
  - `src/lib/aiur/agent_runner/turn_alerts.ex`
  - `src/test/aiur/agent_runner/message_handler_test.exs`
  - `src/test/aiur/agent_runner/turn_streams_test.exs`
  - `src/test/aiur/agent_runner/tool_executor_test.exs`
  - `src/test/aiur/agent_runner/turn_alerts_test.exs`
- Modify:
  - `src/lib/aiur/agent_runner.ex` (extract the four bodies; repoint concern-A
    callers of `send_control_state`/`send_worker_runtime_info`; retain the
    `post_aiur_turn_markers/4` wrapper; slim to concern A)
  - `src/lib/aiur/agent_runner/turn_loop.ex` (repoint its per-turn-spine calls to
    the four new modules; T-034)
  - `src/lib/aiur/agent_runner/queue_drain.ex` (repoint its queue-item-turn calls
    to the four new modules; T-035)
- Test: the 4 new test files above; existing pins run unchanged (see
  Characterization-tests).

## Out of scope

- The sibling modules extracted in T-034/T-035 — `session_lifecycle.ex`,
  `session_resume.ex`, `turn_loop.ex`, `turn_prompt.ex`, `queue_drain.ex`,
  `checkpoint_delivery.ex`, `events_digest.ex`, `bootstrap_digest.ex`,
  `comment_context.ex` — are edited **only** to repoint the `turn_loop.ex` /
  `queue_drain.ex` call sites named in step 5. Do not otherwise touch their
  logic, and make **no** edits to the other seven.
- The shared execute-one-turn spine of `do_run_codex_turns/…` (TurnLoop) and
  `run_queue_item_turn/…` (QueueDrain) — the research doc §2 flags deduplicating
  it as a follow-up **after** this wave lands, behind the characterization
  tests; this ticket is a mechanical move + repoint only. Do not dedupe.
- `SessionLifecycle`'s DisplayTailer path — it deliberately bypasses the message
  handler; do not wire `MessageHandler.build/6` into it.
- The backend-behaviour migration (T-016) and any residual claude/claude-repl
  branching — not here.
- `src/mix.exs` `ignore_modules` — do not add the four new modules; do not
  remove `Aiur.AgentRunner`.
- Any existing test under `src/test/aiur/` — must pass unmodified; in particular
  `src/test/aiur/agent_runner_test.exs` (the sync-marker fan-out pin) and
  everything under `src/test/aiur/regression/` and `src/test/fixtures/` are
  read-only. Do not edit or reformat them.
- `Aiur.Orchestrator`, `Aiur.Codex.DynamicTool`, `Aiur.Opencode.*`,
  `Aiur.Events.*`, `Aiur.GitHub.IssueDependencies`, `Aiur.Alerts` — called,
  never modified.

## Inventory-IDs

Files in this ticket implement/touch, from
`docs/refactor/feature-inventory/orc.md`:

- FI-ORC-079 — Transcript and turn-event broadcasting → `MessageHandler`
- FI-ORC-062 — Runner runtime-info reporting to the orchestrator
  (`send_worker_runtime_info`, `send_control_state`, codex_worker_update via
  `send_codex_update`) → `MessageHandler`
- FI-ORC-071 — Aiur turn markers / ActiveTurns registration ordering → `TurnStreams`
- FI-ORC-077 — Agent tool executor wiring (alerts, events, subscriptions,
  blockers) → `ToolExecutor`
- FI-ORC-049 — `subscribe_for_declared_blocker` immediate subscribe at
  `aiur_declare_blocker` time (called from `declare_blocker_for_issue/2`) → `ToolExecutor`
- FI-ORC-078 — Quota-exhaustion pause alert (#721) and tokens-exhausted alert → `TurnAlerts`

Consumed but owned elsewhere (not re-implemented here): FI-ORC-052/FI-ORC-053
(orchestrator queue APIs) live in `Aiur.Orchestrator`; the DisplayTailer
(FI-ORC-069) and residual backend branching (FI-ORC-066/068) live in
`Aiur.AgentRunner.SessionLifecycle` (T-034). This wave calls them unchanged.

## Characterization-tests

The Phase-1 regression file that guards this area is
`src/test/aiur/regression/agent_runner_lifecycle_test.exs` (created by T-013) —
its "sync-marker fan-out census" describe drives
`AgentRunner.post_aiur_turn_markers/4` and pins the fire-and-forget contract; it
must pass **unmodified**. `src/test/aiur/regression/event_flow_e2e_test.exs`
(digest render through the runner-visible closure) and
`src/test/aiur/regression/done_agent_detach_test.exs` must also stay green.

The byte-level pins that are not under `regression/` but must stay green every
sub-step and must **not** be edited: `src/test/aiur/agent_runner_test.exs`
(the `post_aiur_turn_markers/4` describe block at lines 20–86, session
start/fallback, digest trust rendering, resume gates),
`src/test/aiur/core_test.exs` (`AgentRunner.run/3` end-to-end scenarios — the
strongest guard for the repointed turn spine),
`src/test/aiur/opencode/active_turns_test.exs` (marker/bridge race semantics),
`src/test/aiur/orchestrator_deactivate_test.exs` (runtime reporting +
`subscribe_for_declared_blocker`), and `src/test/aiur/dynamic_tool_test.exs`
(tool executor wiring). If any of these fails, your change is wrong — fix the
code, never the test.

## Acceptance criteria

Mechanically checkable (run from repo root unless noted):

- All four new lib modules exist at their exact paths and names:
  `grep -c "defmodule Aiur.AgentRunner.MessageHandler do" src/lib/aiur/agent_runner/message_handler.ex` → 1;
  `grep -c "defmodule Aiur.AgentRunner.TurnStreams do" src/lib/aiur/agent_runner/turn_streams.ex` → 1;
  `grep -c "defmodule Aiur.AgentRunner.ToolExecutor do" src/lib/aiur/agent_runner/tool_executor.ex` → 1;
  `grep -c "defmodule Aiur.AgentRunner.TurnAlerts do" src/lib/aiur/agent_runner/turn_alerts.ex` → 1.
- The renamed public entries exist in their new homes (each ≥ 1):
  `grep -c "def build(" src/lib/aiur/agent_runner/message_handler.ex`;
  `grep -cE "def (open|close)\(" src/lib/aiur/agent_runner/turn_streams.ex` → ≥ 2;
  `grep -c "def post_aiur_turn_markers(" src/lib/aiur/agent_runner/turn_streams.ex` → 1;
  `grep -c "def build(" src/lib/aiur/agent_runner/tool_executor.ex`;
  `grep -cE "def maybe_emit_usage_limit_alert\(|def maybe_emit_more_tokens_alert\(" src/lib/aiur/agent_runner/turn_alerts.ex` → ≥ 2.
- The four concerns no longer have live definitions in the facade — each prints
  `0`:
  `grep -c "defp codex_message_handler\|def codex_message_handler" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp tool_executor\|def tool_executor" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp maybe_emit_usage_limit_alert\|def maybe_emit_usage_limit_alert" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp maybe_emit_more_tokens_alert\|def maybe_emit_more_tokens_alert" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp open_aiur_turn_streams\|defp close_aiur_turn_streams" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp send_control_state\|defp send_worker_runtime_info" src/lib/aiur/agent_runner.ex`;
  `grep -c "defp send_codex_update\|defp emit_agent_event\|defp declare_blocker_for_issue" src/lib/aiur/agent_runner.ex`.
- The `post_aiur_turn_markers/4` public wrapper is retained and delegates:
  `grep -c "def post_aiur_turn_markers(" src/lib/aiur/agent_runner.ex` → 1;
  `grep -c "TurnStreams.post_aiur_turn_markers" src/lib/aiur/agent_runner.ex` → 1;
  and no `defdelegate` in the facade:
  `grep -c "defdelegate" src/lib/aiur/agent_runner.ex` → 0.
- No module calls back into the facade for the moved concerns — each prints `0`:
  `grep -c "AgentRunner.codex_message_handler\|AgentRunner.tool_executor\|AgentRunner.open_aiur_turn_streams\|AgentRunner.close_aiur_turn_streams\|AgentRunner.send_control_state\|AgentRunner.send_worker_runtime_info\|AgentRunner.maybe_emit_usage_limit_alert\|AgentRunner.maybe_emit_more_tokens_alert" src/lib/aiur/agent_runner/turn_loop.ex`;
  same grep against `src/lib/aiur/agent_runner/queue_drain.ex`. The repointed
  callers reference the new modules instead:
  `grep -cE "MessageHandler\.|TurnStreams\.|ToolExecutor\.|TurnAlerts\." src/lib/aiur/agent_runner/turn_loop.ex` → ≥ 1 and same for `queue_drain.ex` → ≥ 1.
- Facade slimmed: `wc -l src/lib/aiur/agent_runner.ex` → **≤ 280** (target ~200),
  down from the pre-refactor 2,215.
- Every new lib file has a moduledoc (`grep -c "@moduledoc" <file>` → 1 for each
  of the four) and each public `def` has an `@spec` (`grep -c "@spec" <file>` ≥ 1
  mechanically; reviewer spot-checks 1:1).
- File-size norms (verbatim comment-bearing moves): `wc -l` prints ≤ **200** for
  `message_handler.ex`, ≤ **110** for `turn_streams.ex`, ≤ **200** for
  `tool_executor.ex`, ≤ **90** for `turn_alerts.ex`. New code you author
  (wrappers, aliases, test helpers) keeps functions ≤ 20 logic lines; **moved**
  functions keep their exact current bodies — the verbatim `tool_executor/3`
  (now `ToolExecutor.build/3`, ~37 lines of closure wiring) and
  `maybe_emit_usage_limit_alert/4` are cohesive single-concern moves and are
  exempt from the 20-line norm; do not rewrite a moved function to satisfy it.
- New modules are NOT coverage-exempt:
  `grep -c "Aiur.AgentRunner.MessageHandler\|Aiur.AgentRunner.TurnStreams\|Aiur.AgentRunner.ToolExecutor\|Aiur.AgentRunner.TurnAlerts" src/mix.exs`
  → 0 (none added to `ignore_modules`); `grep -c "Aiur.AgentRunner," src/mix.exs`
  → 1 (the facade stays exempt — unchanged).
- Four new test files exist under `src/test/aiur/agent_runner/` and
  `mix test test/aiur/agent_runner/message_handler_test.exs test/aiur/agent_runner/turn_streams_test.exs test/aiur/agent_runner/tool_executor_test.exs test/aiur/agent_runner/turn_alerts_test.exs`
  (from `src/`) passes, 0 failures.
- Full suite green after every sub-step commit (`mix test`, 0 failures, no
  skips). The pins named in Characterization-tests pass unmodified:
  `git diff --name-only origin/v2...HEAD` lists none of them (and nothing under
  `src/test/aiur/regression/` or `src/test/fixtures/`).

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
  `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/agent_runner.ex src/lib/aiur/agent_runner/`
  renders the four extractions as moved blocks, not rewrites (only the
  `defp name` → `def new_name` header lines and repointed call sites change).
- Check FI-ORC-071 (register-before-post): read `TurnStreams.open/1` — the
  `ActiveTurns.put/2` call precedes `post_aiur_turn_markers/4`, and
  `agent_runner_test.exs:20-86` plus T-013's fan-out census
  (`agent_runner_lifecycle_test.exs`) pass through the retained
  `AgentRunner.post_aiur_turn_markers/4` wrapper. `opencode/active_turns_test.exs`
  green.
- Check FI-ORC-079/FI-ORC-062: `core_test.exs` `AgentRunner.run/3` scenarios and
  `orchestrator_deactivate_test.exs` runtime-reporting tests pass — the
  transcript/turn-event/codex_worker_update fan-out and the
  `worker_control_state`/`worker_runtime_info` messages are byte-identical after
  the move.
- Check FI-ORC-049/FI-ORC-077: `declare_blocker_for_issue/2` in
  `tool_executor.ex` still calls `Orchestrator.subscribe_for_declared_blocker/2`
  on the `{:ok, _}` branch; `dynamic_tool_test.exs` and
  `orchestrator_deactivate_test.exs` green.
- Check FI-ORC-078: `turn_alerts.ex` — `maybe_emit_usage_limit_alert/4` matches
  only `%{kind: :usage_limit_exhausted}` and `more_tokens_reason?/1` keeps its
  exact substring list; `alerts_test.exs` green.
- Confirm the facade is a concern-A module: `run/3` and `transient_run_error?/1`
  stay exported at their current arities:
  `cd src && mix run -e 'Code.ensure_loaded(Aiur.AgentRunner); IO.puts(function_exported?(Aiur.AgentRunner, :run, 3) and function_exported?(Aiur.AgentRunner, :transient_run_error?, 1) and function_exported?(Aiur.AgentRunner, :post_aiur_turn_markers, 4))'`
  → `true`.
- Confirm no out-of-scope sibling module was edited beyond the step-5 repoint:
  `git diff --name-only origin/v2...HEAD` under `src/lib/aiur/agent_runner/`
  contains only the four new files plus `turn_loop.ex` and `queue_drain.ex`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
