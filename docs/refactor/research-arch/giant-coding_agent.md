# Decomposition: `src/lib/aiur/codex/coding_agent.ex` (1997 lines)

Codex app-server adapter (`Aiur.Codex.CodingAgent`, `@behaviour Aiur.CodingAgent`): JSON-RPC 2.0
over a stdio port — handshake, thread start/resume, turn protocol, approvals/tool calls, operator
message delivery at safe checkpoints, pause/interrupt, quota classification, event normalization.

House style applied: pure policy functions extracted as leaves; one source of truth per protocol
fact (all wire frames in one module); one dependency direction (facade → loop → handlers → policy
→ wire/process); the `Aiur.CodingAgent` behaviour stays the only cross-backend contract; concrete
modules stay thin. Norm targets (<=200-line files, <=20-line functions) are guiding, not
mechanical — two modules land at ~200 because splitting them further would fragment a single
concern.

---

## 1. Function / responsibility census

Line ranges from the current file (branch `refactor-planning-prompt`).

### A. Behaviour facade & session lifecycle (~230 lines)
| Function | Lines | Size |
|---|---|---|
| `run/4` | 36–49 | 14 |
| `start_session/2` | 51–90 | 40 |
| `run_turn/4` | 92–176 | 85 |
| `stop_session/1` | 178–181 | 4 |
| `send_operator_message/2` (2 clauses) | 183–210 | 28 |
| `session_policies/2` | 357–363 | 7 |
| `issue_context/1`, `issue_identifier/1` | 1515–1521 | 7 |
| module attrs, `@type session`, moduledoc | 1–34 | 34 |

### B. Workspace validation (pure guard, ~41 lines)
| `validate_workspace_cwd/2` (local: canonicalize + root containment + symlink escape; remote: newline/empty injection guard) | 212–252 | 41 |

### C. OS process / port lifecycle & launch command (~105 lines)
| Function | Lines |
|---|---|
| `start_port/4` (local bash spawn; remote SSH spawn) | 254–279 |
| `remote_launch_command/3` | 282–290 |
| `codex_command/2` + `append_config/3` (model/effort `--config` appends) | 292–309 |
| `port_metadata/2` | 311–325 |
| `stop_port/1` (reap tree BEFORE `Port.close` — sqlite-lock poisoning) | 1523–1551 |
| `shell_escape/1` | 1553–1555 |

### D. JSON-RPC wire: framing + synchronous response waits (~70 lines)
| Function | Lines |
|---|---|
| `send_message/2` (Jason encode + `Port.command`) | 1790–1793 |
| `await_startup_response/2`, `startup_response_timeout_ms/1` (30s cold-start floor) | 1451–1457 |
| `with_timeout_response/4` (selective receive, noeol reassembly) | 1459–1474 |
| `handle_response/4` (id-matched result/error; skip others) | 1476–1497 |
| `log_non_json_stream_line/2` (error-keyword triage to warn/debug) | 1499–1513 |

### E. Handshake & thread start/resume (~175 lines)
| Function | Lines |
|---|---|
| `send_initialize/1` (+ `initialized` notify; `:port_closed` rescue) | 327–355 |
| `do_start_session/4` | 365–370 |
| `start_or_resume_thread/4` (resume→fresh→fallback, issue #378) | 372–407 |
| `resume_outcome/2` (public, pure, unit-tested) | 409–419 |
| `start_thread/3`, `resume_thread/4` | 421–427 |
| `send_thread_init/2` (`:port_closed` rescue) | 429–439 |
| `thread_init_frame/3` (start w/ dynamicTools vs resume without) | 441–471 |
| `parse_thread_response/1` | 473–475 |
| `start_turn/7` (turn/start frame + await turn id) | 477–500 |

### F. Turn receive loop & incoming-message dispatch (~310 lines)
| Function | Lines |
|---|---|
| `await_turn_completion/7` (initial loop-state map, 14 keys) | 502–527 |
| `receive_loop/2` (port data/exit, `:pause_agent`, 5 `:agent_queue_updated` shapes, idle `after` timeout) | 529–575 |
| `handle_incoming/3` (JSON decode branch) | 577–588 |
| `handle_decoded_incoming/6` — 8 ordered clauses: pending-interrupt result; pending-interrupt error (-32600 tolerance); operator-response result/error; `turn/completed` (status routing); `turn/failed`; `turn/cancelled` (paused-vs-error); generic method; fallback other_message | 590–673 |
| `handle_malformed_incoming/4` + `protocol_message_candidate?/1` | 675–698 |
| `emit_turn_event/6` | 700–711 |
| `handle_turn_method/5` (approval-routing outcomes) | 713–753 |
| `handle_unhandled_method/7` | 755–763 |
| `handle_notification_outcome/4` (ordered cond: quota-pause → unretryable → turn_started → idle-as-completion → error-log → debug) | 765–807 |

### G. Turn-state transitions & completion accounting (~120 lines)
| Function | Lines |
|---|---|
| `fail_pending_operator_requests/2` | 868–872 |
| `continue_after_turn_completion/1` (outstanding_turns algebra) | 874–888 |
| `thread_idle_status?/2`, `turn_started_method?/1` | 890–895 |
| `continue_after_turn_interrupted/2` (pause vs operator-message vs error) | 897–923 |
| `maybe_finish_after_pending_response/1` | 983–989 |
| `turn_completion_status/1` | 1069–1073 |
| `safe_invoke_success_callback/2`, `safe_invoke_failure_callback/2` | 1075–1085 |

### H. Operator delivery at safe checkpoints (~135 lines)
| Function | Lines |
|---|---|
| `handle_pending_operator_response/5` | 809–838 |
| `checkpoint_for_method/1` | 840–841 |
| `maybe_process_safe_checkpoint/3` (`:deliver_text` → send + pending registry) | 843–866 |
| `handle_claimed_operator_response/8` (3 clauses: turn started / error / other) | 925–981 |

### I. Pause & interrupt (~65 lines)
| Function | Lines |
|---|---|
| `handle_pause_request/3` (3 clauses; dedupe) | 991–1015 |
| `handle_operator_queue_update/2` (2 clauses; dedupe on in-flight interrupt) | 1017–1035 |
| `interrupt_turn/2` (turn/interrupt frame; `:port_closed` rescue) | 1037–1055 |
| `no_active_turn_error?/1` (-32600 / "no active turn") | 1057–1067 |

### J. Approvals, dynamic tool calls, requestUserInput auto-answers (~365 lines)
| Function | Lines |
|---|---|
| `maybe_handle_approval_request/8` — 7 clauses: `item/commandExecution/requestApproval` (acceptForSession), `item/tool/call` (execute via tool_executor), `execCommandApproval` / `applyPatchApproval` (approved_for_session), `item/fileChange/requestApproval` (acceptForSession), `item/tool/requestUserInput`, fallback `:unhandled` | 1087–1240 |
| `normalize_tool_result/1` | 1242–1249 |
| `approve_or_require/8` (auto-approve true/false) | 1251–1284 |
| `maybe_auto_answer_tool_request_user_input/8` | 1286–1341 |
| `tool_request_user_input_approval_answers/1` | 1343–1362 |
| `reply_with_non_interactive_tool_input_answer/7` | 1364–1389 |
| `tool_request_user_input_unavailable_answers/1` | 1391–1410 |
| `..._question_id/1`, `..._approval_answer/1`, `..._approval_option_label/1`, `..._option_label/1`, `approval_option_label?/1` | 1412–1449 |
| `tool_call_name/1`, `tool_call_arguments/1` | 1769–1788 |
| `needs_input?/2`, `input_required_method?/2`, `request_payload_requires_input?/1`, `needs_input_field?/1` | 1795–1839 |

### K. Notification / error classification (pure predicates, ~120 lines incl. load-bearing comments)
| Function | Lines |
|---|---|
| `codex_error_method?/1` | 1802–1811 |
| `unretryable_codex_error?/1`, `will_retry_false?/1` | 1905–1913 |
| `codex_quota_exhausted?/2` | 1915–1926 |
| `usage_limit_exceeded?/1` (total; `inspect`-scan for field-name drift) | 1928–1941 |
| `usage_limit_pause/2` | 1943–1952 |
| `usage_limit_reset_hint/1` | 1954–1962 |
| `codex_error_reason/2`, `codex_error_detail/1`, `ensure_map/1` | 1964–1996 |

### L. Event normalization: usage & rate limits (~190 lines, zero in-file deps)
| `normalize_event/1` (behaviour callback), `normalize_usage/1`, `normalize_rate_limits/1`, `absolute_token_usage/1`, `turn_completed_usage/1`, `direct_token_map/1`, `canonicalize_usage/1`, `token_value/2`, `parse_token_value/1`, `has_token_field?/1`, `token_like_value?/1`, `find_rate_limits/1`, `search_rate_limits/1`, `rate_limits_map?/1`, `dig/2` | 1557–1744 |

### M. on_message emission & per-message metadata (~25 lines)
| `emit_message/4`, `metadata_from_message/2`, `maybe_set_usage/2`, `default_on_message/1` | 1746–1767 |

### N. `@doc false` test seams (~60 lines)
`codex_command_for_test`, `thread_init_frame_for_test`, `send_thread_init_for_test`,
`await_startup_response_for_test`, `startup_response_timeout_ms_for_test`,
`parse_thread_response_for_test`, `unretryable_codex_error_for_test`, `codex_error_reason_for_test`,
`usage_limit_exceeded_for_test`, `usage_limit_reset_hint_for_test`, `notification_outcome_for_test`,
`codex_quota_exhausted_for_test` | 1841–1900. These exist only because everything is private in one
module; the split makes most of them redundant (tests call the new modules' public functions).

---

## 2. Proposed module split — NAME MAP (contract for downstream tickets)

All under the existing `Aiur.Codex` namespace, files under `src/lib/aiur/codex/`. Existing
siblings for naming feel: `Aiur.Codex.Config`, `Aiur.Codex.DynamicTool`, `Aiur.Codex.Transcript`,
`Aiur.Codex.EventHumanizer`; policy-module precedent: `Aiur.Opencode.SlotPolicy`.

| # | Module | File | Responsibility (one sentence) | ~LOC | Key functions moving there |
|---|---|---|---|---:|---|
| 1 | `Aiur.Codex.CodingAgent` | `src/lib/aiur/codex/coding_agent.ex` (existing, shrinks) | Thin `@behaviour Aiur.CodingAgent` facade owning the session map: `run/4`, `start_session/2`, `run_turn/4`, `stop_session/1`, `send_operator_message/2` (delegating), `normalize_event/1` (delegating). | ~170 | run, start_session, run_turn, stop_session, session_policies, issue_context, issue_identifier |
| 2 | `Aiur.Codex.AppServerPort` | `src/lib/aiur/codex/app_server_port.ex` | Owns the codex app-server OS process: workspace-cwd validation, local-bash / remote-SSH spawn with launch-command construction (model/effort config appends), ProcessReaper registration, port metadata, and ordered stop (reap tree before `Port.close`). | ~170 | validate_workspace_cwd/2, start_port/4, remote_launch_command/3, codex_command/2, append_config/3, shell_escape/1, port_metadata/2, stop_port/1 |
| 3 | `Aiur.Codex.Rpc` | `src/lib/aiur/codex/rpc.ex` | JSON-RPC line transport over the port: encode-and-send frames, synchronous id-matched response waits with the cold-start timeout floor, and non-JSON stream-line logging. | ~90 | send_message/2, await_startup_response/2, startup_response_timeout_ms/1, with_timeout_response/4, handle_response/4, log_non_json_stream_line/2 |
| 4 | `Aiur.Codex.Frames` | `src/lib/aiur/codex/frames.ex` | Single source of truth for every codex JSON-RPC frame shape and fixed request id: initialize/initialized, thread start/resume (dynamicTools only on start), turn/start (initial + operator), turn/interrupt, approval-decision and tool-result/answers replies. | ~140 | initialize_frame/0, initialized_frame/0, thread_init_frame/3, turn_start_frame/…, operator_turn_frame/…, turn_interrupt_frame/3, approval_result_frame/2, tool_result_frame/2, answers_frame/2; `@initialize_id`/`@thread_start_id`/`@turn_start_id` |
| 5 | `Aiur.Codex.Handshake` | `src/lib/aiur/codex/handshake.ex` | Session establishment sequencing: initialize handshake, thread start-or-resume with the resumed/fresh/clean-start-fallback classification (issue #378), thread-response parsing, and first `turn/start`. | ~140 | send_initialize/1, establish/4 (née do_start_session), start_or_resume_thread/4, resume_outcome/2, start_thread/3, resume_thread/4, send_thread_init/2, parse_thread_response/1, start_turn/7 |
| 6 | `Aiur.Codex.TurnLoop` | `src/lib/aiur/codex/turn_loop.ex` | The blocking per-turn receive loop in the caller's process: line reassembly, decoded-frame dispatch (ordered clauses), malformed-line gating, method routing to approvals/notifications, and the notification-outcome cond. | ~200 | await_turn_completion/7, receive_loop/2, handle_incoming/3, handle_decoded_incoming/6, handle_malformed_incoming/4, handle_turn_method/5, handle_unhandled_method/7, handle_notification_outcome/4, emit_turn_event/6 |
| 7 | `Aiur.Codex.TurnState` | `src/lib/aiur/codex/turn_state.ex` | Pure loop-state container and transitions: outstanding-turns accounting, pending-operator-request registry, completion algebra, and crash-safe callback invocation. | ~140 | new/…(init map), continue_after_turn_completion/1, maybe_finish_after_pending_response/1, fail_pending_operator_requests/2, safe_invoke_success_callback/2, safe_invoke_failure_callback/2, put/pop pending request helpers |
| 8 | `Aiur.Codex.Interrupts` | `src/lib/aiur/codex/interrupts.ex` | Pause and operator-queue interrupt semantics: dedupe of in-flight interrupts, sending `turn/interrupt`, and classifying the interrupted-turn outcome (paused vs operator-message vs error). | ~110 | handle_pause_request/3, handle_operator_queue_update/2, interrupt_turn/2, continue_after_turn_interrupted/2 |
| 9 | `Aiur.Codex.OperatorDelivery` | `src/lib/aiur/codex/operator_delivery.ex` | Delivering queued operator text at safe checkpoints and tracking each delivery's `turn/start` response through success/failure callbacks; owns the actual operator `turn/start` send the facade delegates to. | ~130 | send_operator_message/2 (impl), maybe_process_safe_checkpoint/3, handle_pending_operator_response/5, handle_claimed_operator_response/8 |
| 10 | `Aiur.Codex.Approvals` | `src/lib/aiur/codex/approvals.ex` | Server-initiated approval and tool-call requests: the method→decision routing table, auto-approve vs approval-required, dynamic-tool execution replies with result normalization, and requestUserInput reply orchestration. | ~190 | maybe_handle_approval_request/8 (all clauses), approve_or_require/8, normalize_tool_result/1, tool_call_name/1, tool_call_arguments/1, maybe_auto_answer_tool_request_user_input/8, reply_with_non_interactive_tool_input_answer/7 |
| 11 | `Aiur.Codex.UserInputAnswers` | `src/lib/aiur/codex/user_input_answers.ex` | Pure answer policy for `item/tool/requestUserInput`: approval-option label selection ("Approve this Session" > "Approve Once" > approve/allow prefix) and the non-interactive fallback answers. | ~120 | approval_answers/1, unavailable_answers/1, question_id/1, approval_answer/1, approval_option_label/1, option_label/1, approval_option_label?/1, non_interactive_answer/0 |
| 12 | `Aiur.Codex.NotificationPolicy` | `src/lib/aiur/codex/notification_policy.ex` | Pure classification of codex methods/payloads: error methods, unretryable (`willRetry:false`) errors, quota exhaustion + reset-hint/pause payload, error reasons, turn-started/idle/completion status, input-required detection, no-active-turn interrupt errors, checkpoint kinds, protocol-line candidacy. | ~180 | codex_error_method?/1, unretryable_codex_error?/1, will_retry_false?/1, codex_quota_exhausted?/2, usage_limit_exceeded?/1, usage_limit_pause/2, usage_limit_reset_hint/1, codex_error_reason/2, codex_error_detail/1, thread_idle_status?/2, turn_started_method?/1, turn_completion_status/1, no_active_turn_error?/1, needs_input?/2 (+3 helpers), checkpoint_for_method/1, protocol_message_candidate?/1 |
| 13 | `Aiur.Codex.EventNormalizer` | `src/lib/aiur/codex/event_normalizer.ex` | Pure normalization of emitted events into canonical `:usage` and `:rate_limits` keys across all codex payload-shape variants. | ~190 | normalize_event/1 and all section-L helpers (normalize_usage, canonicalize_usage, find_rate_limits, dig, …) |
| 14 | `Aiur.Codex.TurnEvents` | `src/lib/aiur/codex/turn_events.ex` | The on_message emission contract: merge per-message port metadata + usage into the event map with timestamp, and the default no-op callback. | ~60 | emit_message/4, metadata_from_message/2, maybe_set_usage/2, default_on_message/0 |

Total ≈ 2,040 LOC across 14 files (moduledocs added; ~60 lines of test seams deleted).

**Dependency direction (strictly one way, top → bottom):**

```
CodingAgent (facade)
  → Handshake, TurnLoop, AppServerPort, OperatorDelivery, EventNormalizer
TurnLoop → Interrupts, OperatorDelivery, Approvals, NotificationPolicy, TurnState, TurnEvents
Interrupts / OperatorDelivery / Approvals → TurnState, NotificationPolicy, UserInputAnswers,
                                            TurnEvents, Frames, Rpc
Handshake → Frames, Rpc
TurnEvents → AppServerPort (port_metadata)         Frames → DynamicTool (tool_specs)
Rpc → (port only)                                  AppServerPort → SSH, AgentEnvironment, Config,
                                                     PathSafety, ProcessReaper, RemoteControl
Pure leaves: NotificationPolicy, UserInputAnswers, EventNormalizer, Frames, TurnState
```

Note the deliberate inversion fix: today `maybe_process_safe_checkpoint` calls the facade's
`send_operator_message`; after the split the real send lives in `OperatorDelivery` and the facade
delegates *down*, so no module depends upward on the facade.

---

## 3. Extraction sequencing (strictly serialized waves; repo compiles + tests green after each)

Every wave is one ticket/PR, ≤400 moved lines, touching this file plus its new module(s) and the
test call-sites that retarget. Waves must land in order — each later wave moves code that calls
what the earlier wave extracted.

- **Wave 1 — pure leaves (~370 moved):** `EventNormalizer` + `NotificationPolicy`. Facade's
  `normalize_event/1` (behaviour callback) delegates to `EventNormalizer`. Retarget
  `coding_agent_test.exs` quota/unretryable/reason/reset-hint assertions and
  `orchestrator_status_test.exs`'s `normalize/1` helper to the new public functions; delete the
  now-redundant `*_for_test` seams for those helpers (`notification_outcome_for_test` stays until
  Wave 6). Verify: `mix test` + full compile, no behavior diff.
- **Wave 2 — protocol layer (~230 moved):** `Frames` + `Rpc`. Monolith's `send_initialize`,
  `send_thread_init`, `start_turn`, `send_operator_message`, `interrupt_turn`, and approval replies
  switch to `Frames.*`/`Rpc.send_message`; the `rescue ArgumentError -> {:error, :port_closed}`
  blocks stay exactly where they are today (raises propagate through `Rpc`). Retarget
  `thread_init_frame_for_test`, `await_startup_response_for_test`,
  `startup_response_timeout_ms_for_test` call-sites; keep frame ids identical (2 for both
  start and resume).
- **Wave 3 — process + handshake (~350 moved):** `AppServerPort` + `Handshake`. `start_session`
  becomes orchestration (validate → spawn+register → policies → `Handshake.establish`);
  `stop_session` delegates to `AppServerPort.stop_port`. `resume_outcome/2`,
  `parse_thread_response`, `send_thread_init` move; retarget
  `src/test/aiur/codex/coding_agent_test.exs` to `Aiur.Codex.Handshake`/`AppServerPort` publics.
  The reap-ordering test and `app_server_test.exs` cwd-guard tests must pass unchanged through the
  facade.
- **Wave 4 — approvals (~310 moved):** `UserInputAnswers` + `Approvals`. `handle_turn_method` in
  the monolith calls `Approvals.maybe_handle_approval_request`; the 4 approve-or-require clauses
  may consolidate into a method→decision-string table (`acceptForSession` vs
  `approved_for_session` values preserved byte-for-byte). All 8 approval/tool e2e tests in
  `app_server_test.exs` stay green via the public `run/4`.
- **Wave 5 — state + delivery (~330 moved):** `TurnEvents` + `TurnState` + `OperatorDelivery`.
  Loop-state map may become a struct with identical field semantics/defaults; facade
  `send_operator_message` delegates to `OperatorDelivery`. `coding_agent_checkpoint_test.exs`
  (checkpoint follow-up, deliver-now interrupt) and `coding_agent_test.exs` operator-frame tests
  pin this wave.
- **Wave 6 — loop + interrupts + facade shrink (~330 moved):** `Interrupts` + `TurnLoop`;
  `run_turn` calls `TurnLoop.await_turn_completion`; delete remaining test seams and dead
  attributes. Final `coding_agent.ex` ≈170 lines. Full suite incl. `app_server_test.exs` timing
  tests (partial-line buffering, side-output logging, ssh launch) is the gate.

Recommended before Wave 5/6: land the missing characterization tests listed in §4 (they are
cheap fake-codex-script tests in the existing `app_server_test.exs` pattern), since waves 5–6
move the least-covered concurrency code.

---

## 4. Risks — semantics that must be preserved verbatim

Hotspot context (`docs/refactor/research-history-hotspots.md`): this file sits in hotspot row 8
(*Agent backends, ~14 incidents — quota/cold-start misclassification, EPIPE family, tool-parity
gaps*), and its seams match cross-cutting theme 1 (*timing/submission races — "codex handshake
port-close (PR #389)"; anything that "sends then assumes" needs an explicit ack point*) and theme
10 (*guards/filters clipping legitimate cases on first ship*). The dedupe guards and cond
orderings below are exactly theme-10 material: enumerate what each must NOT skip before touching it.

1. **Same-process selective receive.** `receive_loop/2` and `with_timeout_response/4` run in the
   AgentRunner task process and match `{^port, ...}`, `{:pause_agent, id}`, and five
   `{:agent_queue_updated, ...}` shapes. Extraction must keep them plain functions executed in the
   caller's process — no GenServer-ification in this pass — or pause/queue messages sent to that
   pid are lost. The other-issue catch-all `agent_queue_updated` clauses must survive (they drain
   the mailbox); the current-issue `deliver_now == true` clause must stay ordered before the
   generic current-issue clauses.
2. **Clause order in `handle_decoded_incoming/6`.** The two pending-interrupt-id clauses must
   match before the generic integer-id operator-response clauses, or an interrupt ack would be
   misrouted into `handle_pending_operator_response` as an unknown request. The `-32600` /
   "no active turn" error is treated as interrupt success (U5 reactivation race documented
   in-file); regressing this crashes the AgentRunner task with `{:turn_interrupt_failed, ...}`.
3. **`:port_closed` rescue asymmetry.** `rescue ArgumentError -> {:error, :port_closed}` exists at
   `send_initialize`, `send_thread_init`, `send_operator_message`, `interrupt_turn` — but NOT at
   `start_turn` or approval replies. Keep the asymmetry; do not "helpfully" make `Rpc.send_message`
   return tuples (that would silently change the raising paths). PR #389 is the prior regression
   in exactly this seam.
4. **`stop_port/1` ordering.** ProcessReaper unregister + `RemoteControl.graceful_kill_tree`
   must run BEFORE `Port.close` — closing first orphans the node→rust app-server holding the
   global `~/.codex/state_5.sqlite` lock, poisoning every later codex agent. Pinned by
   `codex/coding_agent_test.exs`. `run/4`'s `try/after stop_session` must survive the facade split.
5. **Timeout semantics.** Turn loop uses an idle `after state.timeout_ms` reset by every message
   (not a total-turn budget). Startup waits use `max(agent_read_timeout_ms, 30_000)` — the
   cold-start floor is pinned by test.
6. **Completion algebra.** `outstanding_turns` starts at 1; each claimed operator `turn/start`
   response increments; `turn/completed` decrements with a 0 floor; `{:ok, :turn_completed}` only
   when `outstanding_turns == 0` AND the pending registry is empty (otherwise remaining pendings
   fail with `:parent_turn_completed`). Interrupted completions route by `pause_request_id` /
   `interrupt_action` (`:pause` → `{:paused, ...}`, `:operator_message` →
   `{:ok, :turn_interrupted_for_operator_message}`, else error). Pause requests dedupe on the
   first `pause_request_id`; queue updates dedupe on an in-flight `pending_interrupt_request_id`.
7. **Quota/notification cond order** (hotspot row 8's "quota misclassification"; memory: codex
   quota → pause + reroute). `handle_notification_outcome/4` must evaluate: quota-pause →
   unretryable-error → `turn/started` → idle-as-completion (only after `turn_started?`) →
   error-log → debug. `codex_quota_exhausted?` deliberately requires error-method AND
   `willRetry:false` AND usage-limit text so transient errors mentioning "usage limit" don't
   strand an agent in a pause that has no auto-resume. `usage_limit_exceeded?`/`reset_hint` are
   intentionally total (`inspect`-scan, no `is_map` guard) to survive codex field-name drift.
8. **Resume (issue #378).** `resume_outcome/2`: same id = resumed, different id = fresh with
   `resumed?: false` (so the cold-start prompt replays), any error = fallback to a clean
   `thread/start` (never strand the issue). The `thread/resume` frame must NOT carry
   `dynamicTools` (server rejects unknown field) while `thread/start` must. Both frames share
   request id 2.
9. **Emit ordering and metadata shape.** `on_message`/`on_safe_checkpoint` run synchronously in
   the loop; keep emit-vs-state-transition order exactly (e.g. tool-call reply is sent to the port
   before `:tool_call_completed` is emitted; `turn/completed` is emitted before completion
   accounting). `metadata_from_message` recomputes `port_metadata(port)` per message WITHOUT
   `worker_host` (only the session-level metadata carries it) — preserve, don't fix in-flight.
   Callback exceptions must stay swallowed (`safe_invoke_*`).
10. **Line handling.** 1MB `line:` port option with `{:noeol, ...}` reassembly in both loops;
    malformed lines emit `:malformed` only when the line looks JSON-like
    (`protocol_message_candidate?`), everything else goes to triaged Logger output. Pinned by the
    partial-JSON-buffering and side-output tests.

**Tests pinning this file today:**
- `src/test/aiur/app_server_test.exs` (1,437 lines, 16 e2e fake-codex tests via `run/4`): cwd
  guards incl. symlink escape, sandbox-policy pass-through, input-required hard failure,
  approval-required vs auto-approve, MCP tool-approval prompts, freeform/option requestUserInput
  auto-answers, unsupported/supported/failed dynamic tool calls, partial-JSON buffering, side
  output logging, malformed-event gating, SSH remote launch.
- `src/test/aiur/coding_agent_checkpoint_test.exs` (568): checkpoint follow-up delivery without
  interrupt; deliver-now queue update triggers `turn/interrupt`.
- `src/test/aiur/coding_agent_test.exs` (485): adapter registry mapping; `send_operator_message`
  frame contents / fresh id / invalid-session / port-closed; `codex_command` `--config` appends +
  shell escaping; unretryable/quota/reason/reset-hint/notification-outcome pure helpers.
- `src/test/aiur/codex/coding_agent_test.exs` (184): stop-session tree reap; thread-init frames;
  `resume_outcome`; `parse_thread_response`; startup-timeout floor; `send_thread_init` port-closed
  degradation.
- `src/test/aiur/orchestrator_status_test.exs`: `normalize_event` usage/rate-limit extraction paths.

**Characterization coverage missing (add before waves 5–6):**
`turn/failed` and `turn/cancelled` routing (esp. `pause_request_id` → `{:paused, ...}` vs error);
`turn/completed` with status `"interrupted"` across the three `interrupt_action` outcomes;
`:pause_agent` handling at the adapter level (dedupe, interrupt issuance, `-32600` tolerance —
currently only exercised via orchestrator-level tests); idle-status-as-completion gated on
`turn_started?`; `fail_pending_operator_requests` fan-out on failed/cancelled/interrupted turns
and on parent completion; receive-loop idle timeout (`{:error, :turn_timeout}`); remote-workspace
validation (empty/newline injection); an e2e `thread/resume`-fallback fake-codex test
(only unit-level today); per-message metadata shape (no `worker_host`).
