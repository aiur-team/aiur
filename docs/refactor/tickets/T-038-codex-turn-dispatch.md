# T-038: codex wave 2: TurnLoop dispatch, Interrupts, OperatorDelivery

**Phase:** 3
**Depends-on:** T-037
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/codex/coding_agent.ex` is the largest single module in the tree
(1,997 lines at commit `8712a32f`). `docs/refactor/research-arch/giant-coding_agent.md`
maps it to focused modules under `Aiur.Codex.*`, extracted in strictly
serialized waves. This ticket is **wave 2 of 3** (T-037 was wave 1, T-039 is
wave 3). It extracts the codex-specific turn-handling residue that T-014 and
T-037 left inline in the facade into three focused modules:
`Aiur.Codex.TurnLoop`, `Aiur.Codex.Interrupts`, and
`Aiur.Codex.OperatorDelivery`.

**Reconcile with T-014 and T-037 first (binding).** Two earlier tickets already
moved most of what the name map's "loop/state/delivery" rows describe:

- **T-014** ("Extract Aiur.AppServer shared adapter core", Phase 2) extracted the
  *shared* per-turn machinery into `Aiur.AppServer.*`, byte-identical across the
  codex and claude backends:
  - `Aiur.AppServer.TurnLoop` — the blocking `receive_loop/2` and the
    `handle_decoded_incoming/6` **dispatch skeleton**, including the fallback
    `:other_message` clause and the two pending-interrupt-id clauses. The
    skeleton calls back into the backend via `state.backend.handle_method/5`,
    `state.backend.handle_malformed/3`, and `state.backend.handle_interrupt_error/2`.
  - `Aiur.AppServer.TurnState` — `continue_after_turn_completion/1`,
    `continue_after_turn_interrupted/2`, `turn_completion_status/1`,
    `fail_pending_operator_requests/2`, `maybe_finish_after_pending_response/1`,
    `safe_invoke_success_callback/2`, `safe_invoke_failure_callback/2`.
  - `Aiur.AppServer.OperatorDelivery` — `maybe_process_safe_checkpoint/3`,
    `handle_pending_operator_response/5`, `handle_claimed_operator_response/8`.
  - `Aiur.AppServer.Interrupts` — `handle_pause_request/3`,
    `handle_operator_queue_update/2`, `interrupt_turn/3`.
  - `Aiur.AppServer.Messages` — `emit_message/4`, `default_on_message/1`, etc.
  - `Aiur.AppServer.Rpc` — `send_line/2`, `with_timeout_response/5`,
    `handle_response/5`, `log_non_json_stream_line/3`.

  T-014 also gave the codex facade `@behaviour Aiur.AppServer.Adapter` and made
  it implement these codex-specific hooks (its Step 9, item 2):
  `handle_method/5`, `handle_malformed/3`, `handle_interrupt_error/2`,
  `loop_state_extras/1`, `send_frame/2`, `metadata_from_message/2`,
  `backend_label/0`. These `@impl` callbacks — plus their private helpers and the
  `handle_notification_outcome/4` cond — are the codex-only residue this ticket
  now moves out of the facade and behind the `@impl` delegates.

- **T-037** (wave 1) extracted `AppServerPort`, `Rpc`, `Frames`, `Handshake`, and
  refit `send_operator_message/2` to build its frame via
  `Aiur.Codex.Frames.operator_turn_frame/3`. That function still lives in the
  facade after T-037; this ticket moves it down into `Aiur.Codex.OperatorDelivery`.

**Because of T-014, the name map's `Aiur.Codex.TurnState` module is NOT created
here** — its entire responsibility (completion/interrupt algebra) was extracted
into the *shared* `Aiur.AppServer.TurnState` by T-014, and codex has no
state-algebra residue of its own. This is the same reconciliation T-037 §0
applied to the shared frame builders. This ticket adds **zero behaviour**: it is
a verbatim relocation of codex-specific dispatch/interrupt/delivery code into
three new modules, with the facade delegating down through its existing `@impl`
callbacks.

> **Temporary upward calls are expected.** After this wave, `Aiur.Codex.TurnLoop`
> still calls the facade's inline approval and notification-policy functions
> (`maybe_handle_approval_request/8`, the quota/error predicates,
> `checkpoint_for_method/1`, `metadata_from_message/2`) **fully qualified** as
> `Aiur.Codex.CodingAgent.<fn>`. That upward reference is exactly what T-039
> removes when it extracts `Aiur.Codex.Approvals` / `NotificationPolicy` /
> `TurnEvents` and retargets these call-sites. Do NOT try to fix the direction in
> this ticket, and do NOT move those functions — they are T-039's scope.

## Scope (exact)

**Wave rules (binding for every step).** Move code **verbatim** where possible —
extract, do not rewrite. Public function signatures and observable behaviour are
unchanged; the facade's `@impl` callbacks delegate to the extracted modules so
`Aiur.AppServer.TurnLoop` keeps reaching the codex hooks through `state.backend`.
Every new module gets a `@moduledoc` and an `@spec` on every public `def`
(`mix specs.check` enforces this inside the `mix lint`/`mix credo` gate). Every
new module gets its own test file; new modules are NOT coverage-exempt — do NOT
touch `ignore_modules` in `src/mix.exs` (the 85% threshold enforces the tests).
Preserve every semantic listed under "Semantics to preserve verbatim" below.
After this ticket the repo compiles and the full suite passes.

Line numbers below are the pre-T-014 numbers (commit `8712a32f`, branch
`refactor-planning-prompt`) and are **locators only** — T-014 and T-037 will have
shifted them and reshaped the two-clause `handle_decoded_incoming/6` codex
clauses into `handle_method/5` `@impl` clauses. The **function names are the
contract**; find the named function/callback in the current file.

### §0 — Reconciliation (do this mentally before editing)

- `Aiur.Codex.TurnState` is **not created**. Completion/interrupt algebra lives in
  `Aiur.AppServer.TurnState` (T-014). Every call to `turn_completion_status/1`,
  `continue_after_turn_completion/1`, `continue_after_turn_interrupted/2`, and
  `fail_pending_operator_requests/2` inside the moved code retargets to
  `Aiur.AppServer.TurnState.*`.
- The shared receive loop, the two pending-interrupt-id clauses, and the fallback
  `:other_message` clause are already in `Aiur.AppServer.TurnLoop` (T-014) — do
  NOT move or duplicate them. This ticket moves only the **codex-specific**
  `handle_method/5` method clauses and the helpers they call.
- Checkpoint delivery (`maybe_process_safe_checkpoint/3`), operator-response
  claiming (`handle_pending_operator_response/5`,
  `handle_claimed_operator_response/8`), and pause/queue interrupts
  (`handle_pause_request/3`, `handle_operator_queue_update/2`, `interrupt_turn/3`)
  are already shared in `Aiur.AppServer.*` (T-014). `Aiur.Codex.OperatorDelivery`
  in this ticket owns ONLY the codex `send_operator_message/2` send that the
  shared `Aiur.AppServer.OperatorDelivery` calls back into via
  `state.backend.send_operator_message/2` — it is not a second copy of the shared
  delivery machinery.

### §1 — Create `Aiur.Codex.TurnLoop` (`src/lib/aiur/codex/turn_loop.ex`)

Owns codex method routing: the `@impl Aiur.AppServer.Adapter` `handle_method/5`
and `handle_malformed/3` bodies plus every private helper they call. Move these,
making `handle_method/5` and `handle_malformed/3` **public** (they are the entry
points the facade's `@impl` callbacks delegate to):

| Move | From (pre-T-014) | New public name/arity |
|---|---|---|
| the codex `handle_method/5` method clauses (`turn/completed`, `turn/failed`, `turn/cancelled`, generic `is_binary(method)` → `handle_turn_method`) as T-014 shaped them onto the `@impl` callback | 625–659 | `handle_method/5` |
| `handle_malformed/3` (`log_non_json_stream_line` + `protocol_message_candidate?` gating) | 675–691 | `handle_malformed/3` |

Move these as **private** helpers of the new module (their only callers move with
them):

| Move | From (pre-T-014) |
|---|---|
| `emit_turn_event/6` | 700–711 |
| `handle_turn_method/5` | 713–753 |
| `handle_unhandled_method/7` | 755–763 |
| `handle_notification_outcome/4` (the ordered cond + its load-bearing comment 765–776) | 777–807 |
| `protocol_message_candidate?/1` | 693–698 |

Rewiring inside the moved bodies:
- `emit_message/4` → `Aiur.AppServer.Messages.emit_message/4` (T-014).
- `turn_completion_status/1`, `continue_after_turn_interrupted/2`,
  `continue_after_turn_completion/1`, `fail_pending_operator_requests/2` →
  `Aiur.AppServer.TurnState.*` (T-014).
- `maybe_process_safe_checkpoint/3` →
  `Aiur.AppServer.OperatorDelivery.maybe_process_safe_checkpoint/3` (T-014).
- `log_non_json_stream_line/2` →
  `Aiur.AppServer.Rpc.log_non_json_stream_line(payload_string, "turn stream", "Codex")`
  (T-014 — the third arg is the backend label).
- `metadata_from_message/2` → `Aiur.Codex.CodingAgent.metadata_from_message/2`
  (still the facade's public `@impl`; T-039 retargets to
  `Aiur.Codex.TurnEvents.metadata_from_message/2`).
- `maybe_handle_approval_request/8`, `checkpoint_for_method/1`, `needs_input?/2`,
  `codex_quota_exhausted?/2`, `codex_error_method?/1`,
  `unretryable_codex_error?/1`, `codex_error_reason/2`, `turn_started_method?/1`,
  `thread_idle_status?/2`, `usage_limit_pause/2` → **all still in the facade**;
  call each **fully qualified** as `Aiur.Codex.CodingAgent.<fn>` (T-039 retargets
  these to `Aiur.Codex.Approvals` / `NotificationPolicy`). See the temporary-upward-
  calls note above — this is expected.

Alias `Aiur.AppServer.{Messages, TurnState, OperatorDelivery, Rpc}`,
`require Logger`.

### §2 — Create `Aiur.Codex.Interrupts` (`src/lib/aiur/codex/interrupts.ex`)

Owns the codex interrupt-error tolerance — the one place codex diverges from
claude on interrupt handling (FI-CDX-035). Move **verbatim**:

| Move | From (pre-T-014) | New public name/arity |
|---|---|---|
| `handle_interrupt_error/2` (the `@impl` body T-014 created from the pending-interrupt-error clause: `if no_active_turn_error?(error) -> {:continue, %{state \| pending_interrupt_request_id: nil}}` else `{:error, {:turn_interrupt_failed, error}}`, INCLUDING the full explanatory comment) | 595–613 | `handle_interrupt_error/2` |
| `no_active_turn_error?/1` (all three clauses: `%{"code" => -32600}`, `%{"message" => msg}` binary "no active turn", fallback `false`) | 1057–1067 | `no_active_turn_error?/1` (private) |

This module has **zero upward dependencies** — it is a pure classifier. Do NOT
add a `-32600` rescue anywhere else and do NOT weaken the tolerance.

### §3 — Create `Aiur.Codex.OperatorDelivery` (`src/lib/aiur/codex/operator_delivery.ex`)

Owns the codex operator `turn/start` send that the shared
`Aiur.AppServer.OperatorDelivery.maybe_process_safe_checkpoint/3` reaches through
`state.backend.send_operator_message/2`. Move **verbatim** (both clauses):

| Move | From (pre-T-037) | New public name/arity |
|---|---|---|
| `send_operator_message/2` valid-session clause (fresh `:erlang.unique_integer([:positive])` id; frame via `Aiur.Codex.Frames.operator_turn_frame/3` after T-037; send; `{:ok, request_id}`; `rescue ArgumentError -> {:error, :port_closed}`) | 185–208 | `send_operator_message/2` |
| `send_operator_message(_session, _payload)` invalid-session fallback → `{:error, :invalid_session}` | 210 | `send_operator_message/2` (2nd clause) |

Rewiring inside the moved body:
- the frame build stays `Aiur.Codex.Frames.operator_turn_frame(session, request_id, text)`
  (T-037 already made this change in the facade).
- the send becomes `Aiur.Codex.Rpc.send_message(port, frame)` (T-037) — it RAISES
  on a closed port; keep the `rescue ArgumentError -> {:error, :port_closed}`
  exactly (FI-CDX-032). Do NOT add a `jsonrpc` field.

Alias `Aiur.Codex.{Frames, Rpc}`.

### §4 — Refit the facade `Aiur.Codex.CodingAgent` (`src/lib/aiur/codex/coding_agent.ex`)

Delete every function moved in §1–§3 from the facade and rewire the `@impl`
callbacks to delegate down:

1. `@impl Aiur.AppServer.Adapter handle_method/5` → one-line delegate
   `Aiur.Codex.TurnLoop.handle_method(session, state, payload, payload_string, method)`.
   Keep `@impl`, `@spec`, and the head unchanged.
2. `@impl Aiur.AppServer.Adapter handle_malformed/3` → one-line delegate
   `Aiur.Codex.TurnLoop.handle_malformed(state, payload_string, port)`.
3. `@impl Aiur.AppServer.Adapter handle_interrupt_error/2` → one-line delegate
   `Aiur.Codex.Interrupts.handle_interrupt_error(state, error)`.
4. `send_operator_message/2` (the `@impl Aiur.CodingAgent` behaviour callback,
   pre-T-037 183–210) → one-line delegate
   `Aiur.Codex.OperatorDelivery.send_operator_message(session, payload)`. Keep
   `@impl Aiur.CodingAgent`, `@spec`, and the head unchanged so
   `state.backend.send_operator_message/2` still resolves from the shared
   `Aiur.AppServer.OperatorDelivery`. Delete the now-orphaned facade helpers that
   only `send_operator_message` used.
5. Remove only the facade aliases your extraction orphaned (e.g. `require Logger`
   if nothing else in the facade logs after the moves — check first; the
   approvals/quota sections still log, so it almost certainly stays). Leave every
   alias still in use.
6. Keep `alias Aiur.Codex.{TurnLoop, Interrupts, OperatorDelivery}` for the four
   delegates.

Do NOT touch, in this ticket: `run/4`, `run_turn/4` (the T-014 delegate),
`start_session/2`, `stop_session/1`, the other `@impl` callbacks
(`backend_label/0`, `send_frame/2`, `metadata_from_message/2`,
`loop_state_extras/1`, `start_turn/3`), the entire approvals/requestUserInput
section (pre-T-014 1087–1449), the quota/error classification (1802–1996), the
`normalize_event`/rate-limit section (1557–1744), and `emit_message`/
`metadata_from_message`/`maybe_set_usage`/`default_on_message` (1746–1767). Those
are all T-039.

### §5 — Semantics to preserve verbatim (from giant-coding_agent.md §4)

- **`handle_method/5` clause order (risk 2).** `turn/completed`, `turn/failed`,
  and `turn/cancelled` must stay distinct clauses ahead of the generic
  `is_binary(method)` clause; `turn/cancelled` routes to `{:paused, ...}` when
  `state.pause_request_id` is an integer, else `{:error, {:turn_cancelled, ...}}`
  (FI-CDX-027). Claude has no `turn/cancelled` clause — do NOT add one there and
  do NOT unify the two backends' method handling.
- **`-32600` interrupt tolerance (risk 2, FI-CDX-035).** A `turn/interrupt` error
  with code `-32600` or a message containing "no active turn" is treated as a
  successful interrupt (clear `pending_interrupt_request_id`, `{:continue, ...}`);
  any other interrupt error ends the turn `{:error, {:turn_interrupt_failed, error}}`.
  This is the fix for the AgentRunner Task crash + `system:` chat-pane dump on
  U5's reactivation race — keep the tolerance and the comment verbatim.
- **Quota/notification cond order (risk 7, FI-CDX-036/037/038/039).**
  `handle_notification_outcome/4` must evaluate in this exact order: quota-pause →
  unretryable-error → `turn/started` → idle-as-completion (only when
  `state.turn_started?`) → error-log → debug. Moving it must not reorder the
  `cond` arms or change any log level. The predicates it calls stay in the facade
  (T-039); only the call receivers change when T-039 lands, not in this ticket.
- **Idle-as-completion gating (risk 7, FI-CDX-039).** The
  `thread_idle_status?(method, payload)` arm fires ONLY after `state.turn_started?`
  is true, so a stale idle before the turn starts can never instantly complete a
  turn that never ran. Preserve the guard.
- **Emit-vs-transition ordering (risk 9).** `emit_turn_event` runs BEFORE the
  completion/interrupt accounting in every `handle_method/5` clause (e.g.
  `turn/completed` emits `:turn_completed` before `turn_completion_status`
  routing). Codex emits WITH a `:details` key (claude does not) — preserve.
- **Malformed gating (risk 10, FI-CDX-038).** `handle_malformed/3` emits
  `:malformed` only when `protocol_message_candidate?/1` is true (the line trims
  to something starting `{` or `[`); everything else goes only to the triaged
  `log_non_json_stream_line`. Codex gates; claude does not — do NOT copy the gate
  to claude.
- **Operator send id + rescue (FI-CDX-032).** `send_operator_message/2` uses a
  fresh `:erlang.unique_integer([:positive])` id (NOT the fixed turn id 3), builds
  the operator `turn/start` frame with the session's `threadId`/`cwd`/policies, and
  keeps the `rescue ArgumentError -> {:error, :port_closed}`; a malformed session
  returns `{:error, :invalid_session}`.

### §6 — Tests for every new module

Create the three test files under Files. Model port-driven tests on the existing
fake-app-server harnesses (`src/test/aiur/coding_agent_checkpoint_test.exs` and
`src/test/aiur/app_server_test.exs` spawn scripted fake binaries). Because the
moved code calls back up into the facade's still-inline policy functions, unit
tests may drive `handle_method/5` / `handle_notification_outcome`-driven paths
through the public facade `run/4` (the e2e harness) where a pure call would
otherwise need the facade; keep the direct-call tests for the parts that stand
alone. Minimum coverage per module:

- `turn_loop_test.exs`: `handle_method/5` for `turn/completed` (status `"completed"`
  → completion, status `"interrupted"` → interrupted routing), `turn/failed`
  (`{:error, {:turn_failed, params}}` and pending-operator requests failed),
  `turn/cancelled` (paused when `pause_request_id` set vs error otherwise), and a
  generic method routing into `handle_turn_method` → approval outcomes
  (`:approved`/`:approval_required`/`:input_required`/`:unhandled`);
  `handle_notification_outcome` cond order (quota-pause, unretryable, turn_started,
  idle-gated-on-turn_started?, error-log, debug); `handle_malformed/3` emits
  `:malformed` only for a `{`/`[`-leading line and never for plain text.
- `interrupts_test.exs`: `handle_interrupt_error/2` returns `{:continue, ...}` with
  the pending interrupt id cleared for `%{"code" => -32600}` and for
  `%{"message" => "... no active turn ..."}`, and `{:error, {:turn_interrupt_failed, e}}`
  for any other error; `no_active_turn_error?/1` true/true/false across its three
  shapes.
- `operator_delivery_test.exs`: `send_operator_message/2` writes a `turn/start`
  with a fresh positive integer id, the session policies, and single text input,
  returning `{:ok, request_id}`; a closed port degrades to `{:error, :port_closed}`;
  a malformed session returns `{:error, :invalid_session}` (drive a fake port, or
  reuse the operator-frame assertions in `coding_agent_test.exs`).

## Files

- Create: `src/lib/aiur/codex/turn_loop.ex`,
  `src/lib/aiur/codex/interrupts.ex`,
  `src/lib/aiur/codex/operator_delivery.ex`
- Create (tests): `src/test/aiur/codex/turn_loop_test.exs`,
  `src/test/aiur/codex/interrupts_test.exs`,
  `src/test/aiur/codex/operator_delivery_test.exs`
- Modify: `src/lib/aiur/codex/coding_agent.ex`
- Test (existing, must pass with ZERO edits):
  `src/test/aiur/app_server_test.exs`,
  `src/test/aiur/coding_agent_checkpoint_test.exs`,
  `src/test/aiur/coding_agent_test.exs`,
  `src/test/aiur/codex/coding_agent_test.exs`

## Out of scope

- `Aiur.Codex.TurnState` — NOT created; the algebra is in `Aiur.AppServer.TurnState`
  (T-014). Do NOT re-home or duplicate it.
- Everything already shared by T-014 in `Aiur.AppServer.*` (receive loop,
  checkpoint delivery, pause/queue interrupts, operator-response claiming, Rpc,
  Messages) — call it, do not copy it.
- Everything T-037 extracted (`AppServerPort`, `Rpc`, `Frames`, `Handshake`) — call
  it, do not touch it.
- The facade's approvals / requestUserInput / tool-result section (pre-T-014
  1087–1449), the quota/error classification (1802–1996), the
  `normalize_event`/usage/rate-limit section (1557–1744), and
  `emit_message`/`metadata_from_message`/`maybe_set_usage`/`default_on_message`
  (1746–1767) — all T-039. Do NOT move them, and do NOT "fix" the temporary
  upward calls from `Aiur.Codex.TurnLoop` into these functions.
- `src/lib/aiur/claude/coding_agent.ex` and `Aiur.Claude.*` — untouched (its
  interrupt handling stays hard-fail; do NOT add codex's `-32600` tolerance).
- `src/mix.exs` — do NOT touch; new modules must NOT be added to `ignore_modules`.
- Anything under `src/test/aiur/regression/` and the existing pinning test files
  listed under Test — they must pass UNMODIFIED (facade delegates keep them green).

## Inventory-IDs

Features implemented by the moved/refit code — behaviour for every one must be
identical after the extraction (all in `docs/refactor/feature-inventory/cdx.md`):

- **TurnLoop:** FI-CDX-027 (turn receive-loop terminal outcomes —
  completed/failed/cancelled routing + outstanding_turns algebra via
  `AppServer.TurnState`), FI-CDX-036 (quota-exhaustion pause — routing arm; the
  predicate stays in the facade until T-039), FI-CDX-037 (unretryable errors end
  the turn hard — routing arm), FI-CDX-038 (error-class notification surfacing +
  non-JSON/malformed triage), FI-CDX-039 (idle status treated as completion, gated
  on `turn_started?`), FI-CDX-040 (`turn_input_required` detection — routing),
  FI-CDX-043 (message envelope via `emit_turn_event`).
- **Interrupts:** FI-CDX-035 ("no active turn" `-32600` interrupt error tolerated
  as success).
- **OperatorDelivery:** FI-CDX-032 (`send_operator_message` nested `turn/start`
  with fresh id, session policies, port-closed and invalid-session error paths).

## Characterization-tests

Everything under `src/test/aiur/regression/` must pass UNMODIFIED — in particular
the suites added by **T-013** (agent_runner drain/resume & digest — drives
operator-queue drain, deliver-now interrupts, and checkpoint delivery through this
adapter) and **T-009** (engine identity, reap & control RPC). Additionally, the
pre-existing fake-app-server harnesses that pin this exact code drive the
unchanged public facade `run/4` and must pass with zero edits:
`src/test/aiur/app_server_test.exs` (approval-required vs auto-approve, malformed-
event gating, `turn/failed`/`turn/cancelled` routing, side-output logging),
`src/test/aiur/coding_agent_checkpoint_test.exs` (checkpoint follow-up delivery;
idle-as-completion both cases — before and after `turn/started`; deliver-now queue
update triggers `turn/interrupt`), `src/test/aiur/coding_agent_test.exs` (operator
`turn/start` frame contents, fresh id, invalid-session, port-closed send),
`src/test/aiur/codex/coding_agent_test.exs` (stop-session tree reap; thread-init
frames).

## Acceptance criteria

All commands run from `src/` unless noted.

- The three modules exist at their exact paths, one `defmodule` each:
  `grep -q "defmodule Aiur.Codex.TurnLoop do" lib/aiur/codex/turn_loop.ex`,
  `grep -q "defmodule Aiur.Codex.Interrupts do" lib/aiur/codex/interrupts.ex`,
  `grep -q "defmodule Aiur.Codex.OperatorDelivery do" lib/aiur/codex/operator_delivery.ex`
  — all three match. `Aiur.Codex.TurnState` is NOT created:
  `test ! -f lib/aiur/codex/turn_state.ex`.
- Each new lib file is <= 200 lines (`wc -l` on each of the three Create paths);
  each new public function <= 20 logic lines EXCEPT the `handle_notification_outcome`
  cond and the `handle_method/5` clauses the Scope marks as verbatim moves — never
  rewrite a moved body to satisfy the limit.
- The facade shrank: `wc -l lib/aiur/codex/coding_agent.ex` <= 1300.
- The method-dispatch residue left the facade:
  `grep -c "handle_notification_outcome" lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "handle_notification_outcome" lib/aiur/codex/turn_loop.ex` >= 1;
  `grep -c "handle_turn_method\|handle_unhandled_method\|emit_turn_event\|protocol_message_candidate?" lib/aiur/codex/coding_agent.ex` → 0.
- The interrupt tolerance left the facade:
  `grep -c "no_active_turn_error?" lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "no_active_turn_error?" lib/aiur/codex/interrupts.ex` >= 2;
  `grep -c "turn_interrupt_failed" lib/aiur/codex/interrupts.ex` >= 1.
- The operator send left the facade body:
  `grep -c "operator_turn_frame" lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "operator_turn_frame" lib/aiur/codex/operator_delivery.ex` >= 1;
  the facade still exposes the delegating callback:
  `grep -q "def send_operator_message.*OperatorDelivery.send_operator_message" lib/aiur/codex/coding_agent.ex`
  (or an equivalent one-line delegate).
- The three `@impl` delegates are one-liners into the new modules:
  `grep -q "TurnLoop.handle_method" lib/aiur/codex/coding_agent.ex`,
  `grep -q "TurnLoop.handle_malformed" lib/aiur/codex/coding_agent.ex`,
  `grep -q "Interrupts.handle_interrupt_error" lib/aiur/codex/coding_agent.ex`.
- Shared T-014 machinery is NOT re-created in the codex modules:
  `grep -c "def receive_loop\|def handle_pause_request\|def maybe_process_safe_checkpoint\|continue_after_turn_completion\b.*do$" lib/aiur/codex/turn_loop.ex` → 0
  (TurnLoop only *calls* `Aiur.AppServer.*` for these).
- Each new module has a `@moduledoc` (`grep -c "@moduledoc" <file>` >= 1 for all
  three) and its named test file exists (the three test paths under Files).
- Coverage exemptions unchanged: `git diff origin/v2 -- src/mix.exs` is empty;
  `grep -c "Codex.TurnLoop\|Codex.Interrupts\|Codex.OperatorDelivery" src/mix.exs` → 0.
- `cd src && mix specs.check` passes (every new public def has `@spec`).
- `git diff --name-only origin/v2...HEAD` lists exactly the Create + Modify files
  above — nothing else, and NOTHING under `src/test/aiur/regression/` or the
  existing pinning test files listed under Test.

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

- Check (FI-CDX-035): queue a deliver-now operator message at a FRESH codex agent
  before its first turn starts — confirm no AgentRunner Task crash and no `system:`
  line dumped into the chat pane (the `-32600` tolerance still fires through the
  `@impl handle_interrupt_error` → `Aiur.Codex.Interrupts` delegate).
- Check (FI-CDX-036/037): drive a `willRetry:false` usage-limit notification and
  confirm the agent PAUSES (`{:paused, %{kind: :usage_limit_exhausted}}`) rather
  than respawning; a retryable quota error must NOT pause.
- Check (FI-CDX-039): with the checkpoint harness, confirm a `thread/status/changed`
  idle BEFORE `turn/started` is ignored and the same idle AFTER completes the turn.
- Check (FI-CDX-032): send an operator message to a live codex agent mid-turn and
  confirm it is delivered at the next safe checkpoint (the shared
  `AppServer.OperatorDelivery` still reaches the codex send through
  `state.backend.send_operator_message`).
- Diff review: confirm `turn/cancelled` handling and the `-32600` tolerance did NOT
  leak into the claude adapter, the `handle_notification_outcome` cond arms kept
  their order, and `Aiur.Codex.TurnLoop`'s remaining upward calls into the facade
  (`maybe_handle_approval_request`, quota predicates, `checkpoint_for_method`,
  `metadata_from_message`) are the only facade references — they are removed by T-039.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
