# T-039: codex wave 3: Approvals, UserInputAnswers, NotificationPolicy, normalizers; slim

**Phase:** 3
**Depends-on:** T-038
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/codex/coding_agent.ex` began this refactor at 1,997 lines as a
single-module Codex app-server adapter (`Aiur.Codex.CodingAgent`,
`@behaviour Aiur.CodingAgent`). Tickets T-037 and T-038 already extracted the
process/handshake/wire layer (`AppServerPort`, `Rpc`, `Frames`, `Handshake`)
and the loop/state/delivery layer (`TurnLoop`, `TurnState`, `Interrupts`,
`OperatorDelivery`). What still lives inline in the facade is the pure policy
and normalization code: server-initiated **approvals** and tool-call
servicing, `requestUserInput` **auto-answer** policy, codex **notification /
error classification**, **event normalization** into canonical usage/rate-limit
keys, and the **on_message** emission helper. Those inline private functions
are still the reason modules extracted in T-037/T-038 (notably `TurnLoop`,
`Interrupts`, `OperatorDelivery`) have to reach *up* into the facade — the
dependency inversion the name map (`docs/refactor/research-arch/giant-coding_agent.md`
§2) exists to remove.

This ticket is the final Codex wave. It extracts the five remaining
concern-modules from `docs/refactor/research-arch/giant-coding_agent.md` §2
(rows 10–14: `Approvals`, `UserInputAnswers`, `NotificationPolicy`,
`EventNormalizer`, `TurnEvents`), retargets every caller — in the facade and in
the T-037/T-038 modules — to the new public functions, deletes the now-dead
`@doc false` `*_for_test` seams, and slims the facade to a thin
`@behaviour Aiur.CodingAgent` delegator. This is a pure move-and-delegate wave:
the fail-closed approval decision strings (FI-CDX-028), the auto-answer option
selection (FI-CDX-029), the quota/notification cond predicates, and the
token/rate-limit normalization must move **verbatim** — no rewrites, no
behavior change.

## Scope (exact)

This is a **verbatim extraction**. Move each function body character-for-character
into its new module; the only edits permitted are (a) changing `defp` to `def`
where the function becomes a public entry point another module now calls,
(b) adding `@moduledoc`/`@spec`, and (c) retargeting internal calls to the new
module names. Public function signatures and observable behavior are unchanged.
Line ranges below are from the pre-refactor file
(`src/lib/aiur/codex/coding_agent.ex` on `refactor-planning-prompt`); after
T-037/T-038 the numbers will have shifted, so **locate by function name**, using
the ranges only as a cross-check against the census in
`docs/refactor/research-arch/giant-coding_agent.md` §1.

Create the five modules under `src/lib/aiur/codex/`, all in the `Aiur.Codex`
namespace, in this order (each compiles + full suite green before the next):

1. **`Aiur.Codex.TurnEvents`** → `src/lib/aiur/codex/turn_events.ex`.
   Move `emit_message/4` (1746–1749), `metadata_from_message/2` (1751–1753),
   `maybe_set_usage/2` (1755–1765), `default_on_message/1` (1767). Make
   `emit_message/4`, `metadata_from_message/2`, and `default_on_message/1`
   public (`def`). `metadata_from_message/2` calls `port_metadata/2` which lives
   in `Aiur.Codex.AppServerPort` (T-037): call `Aiur.Codex.AppServerPort.port_metadata/2`.
   Retarget **every** `emit_message(...)` call-site in the facade and in the
   already-extracted `TurnLoop` / `Interrupts` / `OperatorDelivery` / (this
   ticket's) `Approvals` to `Aiur.Codex.TurnEvents.emit_message/4`; retarget
   `metadata_from_message/2` and `default_on_message/1` likewise. Preserve the
   emit-vs-state-transition ordering exactly (risk 9): the message map is
   `metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())`
   and `metadata_from_message` recomputes `port_metadata` per message **without**
   `worker_host` — do not "fix" this.

2. **`Aiur.Codex.EventNormalizer`** → `src/lib/aiur/codex/event_normalizer.ex`.
   Move the entire section-L block (1557–1744): `normalize_event/1` plus
   `normalize_usage/1`, `normalize_rate_limits/1`, `absolute_token_usage/1`,
   `turn_completed_usage/1`, `direct_token_map/1`, `canonicalize_usage/1`,
   `token_value/2`, `parse_token_value/1`, `has_token_field?/1`,
   `token_like_value?/1`, `find_rate_limits/1`, `search_rate_limits/1`,
   `rate_limits_map?/1`, `dig/2`. Make `normalize_event/1` public. This block
   has zero in-file dependencies — it moves clean. In the facade, the
   `@impl`/behaviour callback `normalize_event/1` **stays** and delegates:
   `def normalize_event(event), do: Aiur.Codex.EventNormalizer.normalize_event(event)`.
   Preserve the total (`inspect`-scan, no `is_map` guard) usage-limit detection
   verbatim — it is intentionally permissive to survive codex field-name drift
   (risk 7).

3. **`Aiur.Codex.UserInputAnswers`** → `src/lib/aiur/codex/user_input_answers.ex`.
   Move the pure answer-policy functions: `tool_request_user_input_approval_answers/1`
   (1343–1362), `tool_request_user_input_unavailable_answers/1` (1391–1410),
   `tool_request_user_input_question_id/1` (1412–1415),
   `tool_request_user_input_approval_answer/1` (1417–1425),
   `tool_request_user_input_approval_option_label/1` (1427–1437),
   `tool_request_user_input_option_label/1` (1439–1440),
   `approval_option_label?/1` (1442–1449). Move the module attribute
   `@non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."`
   (line 21) into this module. Expose `approval_answers/1` and
   `unavailable_answers/1` as the public entry points (rename the two
   `tool_request_user_input_*_answers/1` heads to those public names, or add
   thin public wrappers — pick the rename to keep it flat). Preserve the option
   selection order **exactly**: `"Approve this Session"` > `"Approve Once"` >
   first `approval_option_label?/1` match (FI-CDX-029). The `"Approve this Session"`
   decision string returned by `approval_answers/1` moves byte-for-byte.

4. **`Aiur.Codex.Approvals`** → `src/lib/aiur/codex/approvals.ex`.
   Move all seven `maybe_handle_approval_request/8` clauses (1087–1240),
   `normalize_tool_result/1` (1242–1249), `approve_or_require/8` (1251–1284),
   `maybe_auto_answer_tool_request_user_input/8` (1286–1341),
   `reply_with_non_interactive_tool_input_answer/7` (1364–1389),
   `tool_call_name/1` (1769–1782), `tool_call_arguments/1` (1784–1788). Make
   `maybe_handle_approval_request/8` public — it is what `TurnLoop.handle_turn_method`
   (T-038) calls; retarget that call-site to `Aiur.Codex.Approvals.maybe_handle_approval_request/8`.
   The `requestUserInput` clause now calls `Aiur.Codex.UserInputAnswers.approval_answers/1`
   and `.unavailable_answers/1` (module 3). Frame sends go through
   `Aiur.Codex.Rpc.send_message/2` (T-037); emits go through
   `Aiur.Codex.TurnEvents.emit_message/4` (module 1). Preserve the decision
   strings **byte-for-byte**: `"acceptForSession"` for
   `item/commandExecution/requestApproval` and `item/fileChange/requestApproval`,
   `"approved_for_session"` for legacy `execCommandApproval` / `applyPatchApproval`
   (FI-CDX-028 — two coexisting decision vocabularies, both preserved). Keep the
   clause **order** unchanged and keep the fail-closed behavior: under any policy
   other than auto-approve, the request is left unanswered and the turn ends
   `{:error, {:approval_required, payload}}`. `normalize_tool_result/1` lifts
   `contentItems[0].text` into `"output"` only when `"output"` is absent
   (FI-CDX-048) — preserve.

5. **`Aiur.Codex.NotificationPolicy`** → `src/lib/aiur/codex/notification_policy.ex`.
   Move the pure predicates: `codex_error_method?/1` (1809–1811),
   `needs_input?/2` (1795–1800), `input_required_method?/2` (1813–…),
   `request_payload_requires_input?/1` and `needs_input_field?/1` (through 1839),
   `unretryable_codex_error?/1` and `will_retry_false?/1` (1905–1913),
   `codex_quota_exhausted?/2` (1915–1926), `usage_limit_exceeded?/1` (1928–1941),
   `usage_limit_pause/2` (1943–1952), `usage_limit_reset_hint/1` (1954–1962),
   `codex_error_reason/2`, `codex_error_detail/1`, `ensure_map/1` (1964–1996),
   `thread_idle_status?/2` and `turn_started_method?/1` (890–895),
   `turn_completion_status/1` (1069–1073), `no_active_turn_error?/1` (1057–1067),
   `checkpoint_for_method/1` (840–841), and `protocol_message_candidate?/1`
   (within 675–698). Make public every predicate that `TurnLoop` /
   `Interrupts` / `OperatorDelivery` (T-038) call: at minimum
   `codex_quota_exhausted?/2`, `unretryable_codex_error?/1`,
   `turn_started_method?/1`, `thread_idle_status?/2`, `turn_completion_status/1`,
   `no_active_turn_error?/1`, `needs_input?/2`, `checkpoint_for_method/1`,
   `protocol_message_candidate?/1`, `codex_error_reason/2`,
   `usage_limit_exceeded?/1`, `usage_limit_reset_hint/1`, `usage_limit_pause/2`.
   Retarget those call-sites in the facade and in the T-038 modules. Preserve
   **verbatim**: the `codex_quota_exhausted?/2` conjunction (error-method AND
   `willRetry:false` AND usage-limit text — a retryable quota error must NOT
   pause; risk 7 / FI-CDX-036); the total `inspect`-scan `usage_limit_exceeded?`
   / `reset_hint` (no `is_map` guard); the `-32600` / "no active turn"
   tolerance in `no_active_turn_error?/1` (risk 2 / FI-CDX-035); the fixed
   needs-input method list (FI-CDX-040); and the load-bearing comments above
   `codex_error_method?/1` and the quota predicates. The
   `handle_notification_outcome/4` **cond ordering** lives in `TurnLoop`
   (extracted in T-038) — do not move it; only its predicate calls retarget to
   `NotificationPolicy`.

6. **Slim the facade** (`src/lib/aiur/codex/coding_agent.ex`). After moves 1–5,
   the module retains only: `run/4` (36–49), `start_session/2`, `run_turn/4`,
   `stop_session/1`, `send_operator_message/2` (delegating to
   `Aiur.Codex.OperatorDelivery` from T-038), `normalize_event/1` (delegating to
   `Aiur.Codex.EventNormalizer`), `session_policies/2` (357–363),
   `issue_context/1` / `issue_identifier/1` (1515–1521), the `@type session`,
   `@version`, and the fixed-id/byte-cap module attributes still referenced.
   Delete the now-dead `@doc false` `*_for_test` seams that this wave makes
   redundant: `unretryable_codex_error_for_test`, `codex_error_reason_for_test`,
   `usage_limit_exceeded_for_test`, `usage_limit_reset_hint_for_test`,
   `notification_outcome_for_test`, `codex_quota_exhausted_for_test` (1841–1900).
   Delete any module attribute or `alias` left unused by the moves (e.g. the
   `@non_interactive_tool_input_answer` attr moved in step 3). The slimmed
   `coding_agent.ex` must be **≤ 180 lines** (name-map target ~170).

7. **Retarget the pinning tests** (these are NOT under `src/test/aiur/regression/`,
   so they may be edited to point at the new public functions — see Out of scope
   for what may not change): in `src/test/aiur/coding_agent_test.exs` retarget the
   unretryable / quota / reason / reset-hint / notification-outcome assertions
   (currently calling the deleted `*_for_test` seams) to
   `Aiur.Codex.NotificationPolicy` publics; in
   `src/test/aiur/orchestrator_status_test.exs` retarget its `normalize/1`-style
   helper to `Aiur.Codex.EventNormalizer.normalize_event/1` (or keep it calling
   the facade `Aiur.Codex.CodingAgent.normalize_event/1`, which still delegates).
   Do not weaken any assertion — retarget the receiver only.

8. **Write a test file per new module** (see Files → Test). Each new module is a
   pure-policy module; test it directly against its public functions with the
   same expectations the pinning suites encode. These modules are NOT added to
   `mix.exs` `ignore_modules`, so the 85% coverage threshold
   (`src/mix.exs` line 18) enforces that these tests exist and exercise the code.

## Files
- Create:
  - `src/lib/aiur/codex/turn_events.ex`
  - `src/lib/aiur/codex/event_normalizer.ex`
  - `src/lib/aiur/codex/user_input_answers.ex`
  - `src/lib/aiur/codex/approvals.ex`
  - `src/lib/aiur/codex/notification_policy.ex`
- Modify:
  - `src/lib/aiur/codex/coding_agent.ex` (slim to delegator, ≤ 180 lines)
  - `src/lib/aiur/codex/turn_loop.ex` (retarget calls to the new modules — from T-038)
  - `src/lib/aiur/codex/interrupts.ex` (retarget calls to the new modules — from T-038)
  - `src/lib/aiur/codex/operator_delivery.ex` (retarget calls to the new modules — from T-038)
  - `src/test/aiur/coding_agent_test.exs` (retarget deleted `*_for_test` seam call-sites)
  - `src/test/aiur/orchestrator_status_test.exs` (retarget `normalize_event` helper)
- Test:
  - `src/test/aiur/codex/turn_events_test.exs`
  - `src/test/aiur/codex/event_normalizer_test.exs`
  - `src/test/aiur/codex/user_input_answers_test.exs`
  - `src/test/aiur/codex/approvals_test.exs`
  - `src/test/aiur/codex/notification_policy_test.exs`

> If, after T-037/T-038 landed, any listed private helper turns out to already
> reside in `turn_loop.ex` / `interrupts.ex` / `operator_delivery.ex` rather than
> in `coding_agent.ex`, move it from wherever it currently lives into the new
> module named above and retarget — the name map (`giant-coding_agent.md` §2) is
> the binding home, not the current file. If that requires editing a file **not**
> in this list, stop and comment the blocker on the issue (see Executor rules).

## Out of scope
- Do NOT touch `handle_notification_outcome/4`'s cond ordering, the receive
  loop, or any T-038 loop/state logic beyond retargeting predicate/emit calls.
- Do NOT touch `Aiur.Codex.AppServerPort`, `Rpc`, `Frames`, or `Handshake`
  (T-037) except to *call* `AppServerPort.port_metadata/2` and `Rpc.send_message/2`.
- Do NOT alter any approval decision string, the auto-answer option order, the
  needs-input method list, the quota-detection conjunction, or the token/
  rate-limit normalization paths — these move byte-for-byte.
- Do NOT convert any pure function into a GenServer, add caching, or "simplify"
  the multi-path normalization (each path serves a distinct codex version).
- Do NOT edit any test under `src/test/aiur/regression/`.
- Do NOT add the new modules to `mix.exs` `ignore_modules`, and do NOT change the
  85 coverage threshold.
- Do NOT refactor `Aiur.Codex.DynamicTool`, `EventHumanizer`, `Transcript`, or
  `Config` (adjacent siblings, out of this ticket's decomposition).

## Inventory-IDs
Files in this ticket implement/touch, from `docs/refactor/feature-inventory/cdx.md`:
- **Approvals** (`approvals.ex`): FI-CDX-028 (auto-approval decision strings,
  fail-closed), FI-CDX-030 (dynamic tool-call servicing `item/tool/call`),
  FI-CDX-048 (dynamic tool response envelope / `normalize_tool_result` output lift).
- **UserInputAnswers** (`user_input_answers.ex`): FI-CDX-029 (`requestUserInput`
  auto-answer option selection + non-interactive fallback).
- **NotificationPolicy** (`notification_policy.ex`): FI-CDX-035 ("no active turn"
  tolerated as interrupt success), FI-CDX-036 (quota exhaustion pause predicate),
  FI-CDX-037 (unretryable codex errors), FI-CDX-038 (error-class surfacing /
  `codex_error_method?`), FI-CDX-039 (idle-status-as-completion gating —
  `thread_idle_status?` / `turn_started_method?`), FI-CDX-040 (turn_input_required
  detection), and partially FI-CDX-027 (`turn_completion_status`).
- **EventNormalizer** (`event_normalizer.ex`): FI-CDX-041 (usage + rate-limit
  canonicalization).
- **TurnEvents** (`turn_events.ex`): FI-CDX-043 (on_message envelope), and
  partially FI-CDX-026 / FI-CDX-059 (per-message port metadata, no `worker_host`).

## Characterization-tests
No Phase-1 characterization ticket (T-006..T-013) produces a codex-adapter file
under `src/test/aiur/regression/`; the phase-independent regression guard that
must stay green for this area is `src/test/aiur/regression/event_flow_e2e_test.exs`.
The direct behavioral protection for this ticket's concerns is the long-standing
Codex pinning suite (these are NOT under `regression/`, so step 7 may retarget
their `*_for_test` call-sites — but no assertion may be weakened):
- `src/test/aiur/app_server_test.exs` (approval-required vs auto-approve, MCP
  tool-approval prompts, freeform/option `requestUserInput` auto-answers,
  supported/unsupported/failed dynamic tool calls — all via `run/4`)
- `src/test/aiur/coding_agent_test.exs` (unretryable / quota / reason / reset-hint
  pure-helper assertions)
- `src/test/aiur/orchestrator_status_test.exs` (`normalize_event` usage/rate-limit
  extraction)
- `src/test/aiur/coding_agent_checkpoint_test.exs` (idle-as-completion gating,
  checkpoint delivery)

## Acceptance criteria
Mechanically checkable from `src/`:
- All five module files exist at the exact paths and declare the exact modules:
  - `grep -q 'defmodule Aiur.Codex.TurnEvents' lib/aiur/codex/turn_events.ex`
  - `grep -q 'defmodule Aiur.Codex.EventNormalizer' lib/aiur/codex/event_normalizer.ex`
  - `grep -q 'defmodule Aiur.Codex.UserInputAnswers' lib/aiur/codex/user_input_answers.ex`
  - `grep -q 'defmodule Aiur.Codex.Approvals' lib/aiur/codex/approvals.ex`
  - `grep -q 'defmodule Aiur.Codex.NotificationPolicy' lib/aiur/codex/notification_policy.ex`
- Facade slimmed: `test "$(wc -l < lib/aiur/codex/coding_agent.ex)" -le 180`.
- The moved concerns no longer appear in the facade:
  - `grep -c 'acceptForSession\|approved_for_session' lib/aiur/codex/coding_agent.ex` → `0`
  - `grep -c 'normalize_usage\|canonicalize_usage\|find_rate_limits' lib/aiur/codex/coding_agent.ex` → `0`
  - `grep -c 'codex_quota_exhausted\|usage_limit_exceeded\|unretryable_codex_error' lib/aiur/codex/coding_agent.ex` → `0`
  - `grep -c 'Approve this Session\|Approve Once' lib/aiur/codex/coding_agent.ex` → `0`
  - `grep -c '_for_test' lib/aiur/codex/coding_agent.ex` → `0`
- The facade still delegates the behaviour callback:
  `grep -q 'def normalize_event.*EventNormalizer.normalize_event' lib/aiur/codex/coding_agent.ex`
  (or an equivalent one-line delegate to `Aiur.Codex.EventNormalizer.normalize_event/1`).
- The decision strings survive byte-for-byte in Approvals:
  `grep -q 'acceptForSession' lib/aiur/codex/approvals.ex` and
  `grep -q 'approved_for_session' lib/aiur/codex/approvals.ex`.
- Every new module has `@moduledoc` and a `@spec` on each public `def`
  (`mix specs.check` enforces the specs).
- Each new file is ≤ 200 lines; per `giant-coding_agent.md` house-style,
  `event_normalizer.ex`, `approvals.ex`, and `notification_policy.ex` may sit at
  ~200 as single concerns — do not fragment a concern to hit the number. Public
  functions ≤ 20 logic lines where the moved body already permits (verbatim
  moves that already exceed this are preserved as-is, not re-split).
- A test file exists for each new module (`ls src/test/aiur/codex/{turn_events,event_normalizer,user_input_answers,approvals,notification_policy}_test.exs`);
  none of the five modules appears in `mix.exs` `ignore_modules`
  (`grep -c 'Aiur.Codex.\(TurnEvents\|EventNormalizer\|UserInputAnswers\|Approvals\|NotificationPolicy\)' mix.exs` → `0`).
- The full suite passes and the coverage summary stays ≥ 85%.

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
- **FI-CDX-028 Check:** run a codex agent with `approval_policy "never"` on a
  prompt that executes a shell command; grep the session log for
  `approval_auto_approved` and confirm no stalled `:approval_required`.
- **FI-CDX-029 Check:** replay an `item/tool/requestUserInput` frame through the
  fake app-server harness (`coding_agent_checkpoint_test` setup) and confirm the
  `%{id => %{"answers" => [label]}}` reply frame, with `"Approve this Session"`
  chosen when offered.
- **FI-CDX-036 Check:** confirm a `willRetry:false` usage-limit error still yields
  `{:paused, %{kind: :usage_limit_exhausted, ...}}` and a retryable quota error
  does NOT pause (`coding_agent_test.exs` quota assertions, now via
  `NotificationPolicy`).
- **FI-CDX-041 Check:** `orchestrator_status_test.exs` still extracts
  `%{input_tokens, output_tokens, total_tokens}` and `:rate_limits` across the
  multi-version payload fixtures.
- Confirm the diff is a pure move + delegate: no approval decision string,
  auto-answer order, needs-input list, quota conjunction, or normalization path
  changed byte-for-byte (`git diff` the moved blocks against the pre-refactor
  bodies); the facade is a thin delegator ≤ 180 lines; and `git grep -n
  'Aiur.Codex.CodingAgent\.\(handle_turn_method\|emit_message\|codex_quota_exhausted\)'`
  shows no module still reaching up into the facade for moved functions.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
