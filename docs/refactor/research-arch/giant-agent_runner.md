# Decomposition: `src/lib/aiur/agent_runner.ex` (2215 lines)

Behavior-preserving split of `Aiur.AgentRunner` for the production-readiness refactor.
House style: one source of truth per fact, pure policy functions over call chains, no
M-x-N fan-out, thin concrete modules with one dependency direction. Targets (functions
<=20 logic lines, files <=200 lines, <=2 nesting) applied with judgment.

Key context: the residual backend branching (claude vs claude-repl, ~lines 638–1052) is
deliberately concentrated into ONE new module (`SessionLifecycle`) so the downstream
backend-behaviour ticket becomes a single-file migration.

`AgentRunner.run/3` is the only production entry point (called from
`src/lib/aiur/orchestrator.ex:3828`); every other public function is `@doc false`
test-support surface, which moves with its concern (test call sites updated in the same
wave).

---

## 1. Function / responsibility census

All line numbers refer to the current file. Nine concerns plus small shared helpers.

### A. Run entry & worker-attempt lifecycle (~180 lines)
| Function | Lines | ~Size |
|---|---|---|
| `run/3` (public entry) | 33–57 | 25 |
| `transient_run_error?/1` (@doc false, tested) | 74–76 | 3 (+15 comment) |
| `run_on_worker_host/4` | 78–90 | 13 |
| `run_worker_attempt/5` (before_run-pause retry loop) | 92–100 | 9 |
| `run_worker_attempt_once/5` (hooks try/after) | 102–128 | 27 |
| `pause_for_before_run_failure/7` | 130–136 | 7 |
| `wait_for_before_run_resume/3` (receive loop) | 1256–1268 | 13 |
| `selected_worker_host/2` | 1943–1957 | 15 |
| `worker_host_for_log/1` | 1959–1960 | 2 |
| `maybe_attach_issue_log/1` | 1962–1968 | 7 |
| `write_pause_log/2,3` | 1976–1986 | 11 |
| `trim_hook_output/1` | 1988–1994 | 7 |
| `issue_context/1` (log-context helper, used everywhere) | 2212–2214 | 3 |

### B. Bootstrap digest (first-turn missed-event replay) (~130 lines)
| Function | Lines | ~Size |
|---|---|---|
| `maybe_enqueue_bootstrap_digest/1` | 150–172 | 23 (+13 comment) |
| `maybe_attach_universal_subscriptions/1` | 182–186 | 5 (+8 comment) |
| `bootstrap_events/2` (publisher-log replay) | 188–199 | 12 |
| `bootstrap_event_key/1` | 433–439 | 7 |
| `comment_event_id_or_nil/1` | 441–448 | 8 |
| `bootstrap_cursor_for_log/1` | 450–451 | 2 |
| `publisher_ids_for_patterns/1` / `_for_pattern/1` | 460–473 | 14 |
| `matches_any_pattern?/2` | 475–483 | 9 |
| `enqueue_bootstrap_if_any/3` | 485–503 | 19 |
| `enqueue_bootstrap_batch/2` (single batched GenServer.call, 5s, catch :exit) | 505–509 | 5 |

### C. GitHub comment context (startup digest input) (~230 lines)
| Function | Lines | ~Size |
|---|---|---|
| `current_comment_context_events_for_test/2` (@doc false, tested) | 201–205 | 5 |
| `current_comment_context_events/2` | 207–223 | 17 |
| `issue_comment_context/2` | 225–234 | 10 |
| `pr_comment_context_events/3` / `_for_pr/4` | 236–262 | 27 |
| `log_comment_context_open_pr_failed/2` | 264–267 | 4 |
| `comment_context_fetchers/0` (Tracker fetchers, injectable) | 269–276 | 8 |
| `fetch_comment_events/3` | 278–289 | 12 |
| `fetch_unaddressed_review_thread_events/3` | 291–303 | 13 |
| `comments_to_events/2` | 305–307 | 3 |
| `comments_after_workpad/2` (workpad cutoff filter) | 309–317 | 9 |
| `latest_workpad_comment_datetime/1`, `latest_datetime/1` | 319–333 | 15 |
| `workpad_comment?/1`, `comment_after_cutoff?/2` | 335–349 | 15 |
| `comment_datetime/1`, `parse_comment_datetime/1` | 351–376 | 26 |
| `comment_context_event/2` (Sanitizer.scrub + trust flag) | 378–399 | 22 |
| `comment_author/1`, `comment_body/1`, `comment_event_id/1` | 401–423 | 23 |
| `pr_number/1` | 425–431 | 7 |

### D. Per-message handling & recipient updates (~150 lines)
| Function | Lines | ~Size |
|---|---|---|
| `codex_message_handler/6` (builds on_message closure: normalize → AgentEventLog → broadcasts → recipient) | 511–519 | 9 |
| `maybe_broadcast_transcript/4` | 521–529 | 9 |
| `maybe_broadcast_turn_event/3` | 531–543 | 13 |
| `transcript_event_from/3` (backend transcript-module dispatch) | 548–553 | 6 |
| `legacy_transcript_event/2`, `role_for_event/1` | 555–578 | 24 |
| `event_kind/1`, `body_for_event/1`, `get/2` (atom/binary key tolerance), `timestamp_for/1` | 580–608 | 29 |
| `send_codex_update/3` | 610–616 | 7 |
| `send_worker_runtime_info/4` | 618–632 | 15 |
| `send_control_state/3` | 1687–1693 | 7 |

### E. Session lifecycle — residual backend branching (~330 lines gross, the 638–1052 band)
| Function | Lines | ~Size |
|---|---|---|
| `report_repl_session/3` ("claude-repl" and "claude" clauses; abort-path runtime reporting) | 638–667 | 30 |
| `headless_os_pid/1` | 669–676 | 8 |
| `run_codex_turns/5` (session setup: backend/model/effort/RC resolution, trust, resume, start, tailer, try/after stop) | 678–750 | 73 |
| `maybe_start_display_tailer/3` | 760–791 | 32 |
| `should_display_tail?/3` (@doc false, tested) | 798–800 | 3 |
| `stop_display_tailer/1` | 802–809 | 8 |
| `maybe_put_rc_name/3` | 816–817 | 2 |
| `remote_session_backend/2` (@doc false, tested) | 824–825 | 2 |
| `rc_session_name/2` (@doc false, tested) + `rc_session_prefix/1` + `repo_short_name/1` | 998–1026 | 29 |
| `maybe_trust_remote_control_workspace/4` (@doc false, tested) | 975–989 | 15 |
| `start_agent_session/3` (@doc false, tested; claude-repl → headless-claude fallback) | 1037–1059 | 23 |
| `session_workspace/1`, `session_worker_host/1`, `session_backend/1` | 1996–2003 | 8 |

### F. Session resume handles (~140 lines gross, interleaved in the E band)
| Function | Lines | ~Size |
|---|---|---|
| `load_resume_thread_id/3` | 832–838 | 7 |
| `resume_thread_id/3` (@doc false, tested) | 847–851 | 5 |
| `maybe_put_resume_thread_id/2` | 853–856 | 4 |
| `session_resumed?/1` (@doc false, tested) | 863–864 | 2 |
| `log_resume_outcome/3` | 871–881 | 11 |
| `maybe_persist_turn_handle/4` | 889–894 | 6 |
| `turn_handle_attrs/2` (@doc false, tested) | 906–914 | 9 |
| `persist_session_handle/3` | 919–924 | 6 |
| `persist_handle_best_effort/3` (@doc false, tested; rescue-swallow) | 934–941 | 8 |
| `session_handle_to_save/2` (@doc false, tested) | 949–959 | 11 |

### G. Turn loop (prompt turns, continue/done policy) (~230 lines)
| Function | Lines | ~Size |
|---|---|---|
| `do_run_codex_turns/10` (one prompt turn: handlers, streams, quotas, run_turn, result triage) | 1062–1142 | 81 |
| `turn_done_reason/1` | 1144–1147 | 4 |
| `finalize_turn_completion/3` (continue/max-turns/done) | 1149–1185 | 37 |
| `wait_for_resume/3` | 1187–1228 | 42 |
| `continue_issue_turn/2` | 1230–1243 | 14 |
| `continue_with_issue?/2` (issue-state refresh policy) | 1915–1932 | 18 |
| `active_issue_state?/1`, `normalize_issue_state/1` | 1934–1941, 1970–1974 | 13 |
| `max_turns_display/1`, `turn_of/1` | 1864–1868 | 4 |

### H. Turn prompts (pure text policy) (~55 lines)
| Function | Lines | ~Size |
|---|---|---|
| `build_turn_prompt/4` (first vs continuation vs resumed) | 1870–1889 | 20 |
| `resumed_turn_prompt/0` | 1897–1907 | 11 |
| `build_turn_prompt_for_test/4` (@doc false, tested) | 1909–1913 | 5 |

### I. Queued-message drain (selective receive + queue-item turns) (~270 lines)
| Function | Lines | ~Size |
|---|---|---|
| `drain_operator_messages/5` (`after 0` non-blocking drain) | 1245–1254 | 10 |
| `wait_for_operator_message/5` (paused-state receive loop; no eager claim — documented foot-gun) | 1278–1314 | 37 |
| `try_claim_after_queue_update/6` | 1316–1329 | 14 |
| `claim_after_queue_update_for_test/3` (@doc false, tested) + `claim_after_queue_update/3` | 1331–1343 | 13 |
| `claim_and_run_or_continue/5` | 1345–1353 | 9 |
| `drain_queued_operator_messages/5` | 1355–1364 | 10 |
| `claim_next_queue_item/2`, `claim_next_wake_queue_item/2`, `claim_next_operator_item/2` | 1366–1384 | 19 |
| `run_operator_turn/6`, `run_queue_item_turn/6` (queue-item turn incl. completion-race requeue) | 1386–1464 | 79 |
| `queue_item_turn_id/1`, `record_operator_delivery/2`, `queue_item_text/1` | 1466–1501 | 36 |

### J. Events digest rendering (agent-visible `<aiur:events>`) (~185 lines)
| Function | Lines | ~Size |
|---|---|---|
| `render_events_digest/2` (+ DebugLog `:read` broadcast) | 1503–1521 | 19 |
| `render_events_digest_for_test/2` (@doc false, tested) | 1523–1527 | 5 |
| `author_trusted_for_digest?/1` (default-untrusted CODEOWNERS gate) | 1538–1546 | 9 (+9 comment) |
| `debounce_block_state_events/1` + `block_state_group_key/1` + `debounce_group/2` + `debounce_keep_or_drop/4` + `within_debounce_window?/3` + `block_state_debounce_seconds/0` | 1553–1629 | 77 |
| `render_event_line/1`, `event_field/2`, `event_summary/1` | 1631–1648 | 18 |
| `maybe_wrap_external_content/2`, `wrap_external/2`, `html_attr_escape/1` (prompt-injection defense) | 1655–1685 | 31 |

### K. Opencode bridge turn streams (~55 lines)
| Function | Lines | ~Size |
|---|---|---|
| `open_aiur_turn_streams/1` (ActiveTurns.put BEFORE marker post) | 1704–1718 | 15 (+9 comment) |
| `post_aiur_turn_markers/4` (public, tested; delegates to `Opencode.TurnMarkers.post_all/4`) | 1720–1733 | 14 |
| `close_aiur_turn_streams/3` (matched-close broadcast + mark_closed) | 1740–1750 | 11 |

### L. Mid-turn checkpoint delivery (~110 lines)
| Function | Lines | ~Size |
|---|---|---|
| `operator_immediate_handler/2` + `immediate_operator_delivery/3` (REPL mid-turn paste path) | 1759–1775 | 17 |
| `safe_checkpoint_handler/2` + `fallback_checkpoint_claim/3` | 1777–1797 | 21 |
| `urgent_checkpoint_delivery/4` + `render_urgent_events_digest/1` | 1799–1815 | 17 |
| `claim_blocker_critical_events_digest/2`, `claim_next_checkpoint_queue_item/2` | 1817–1831 | 15 |
| `safe_checkpoint_delivery/4` | 1833–1842 | 10 |
| `handle_checkpoint_delivery_failure/4` (4 clauses: requeue vs mark-failed policy) | 1844–1860 | 17 |

### M. Dynamic-tool executor bindings (~150 lines)
| Function | Lines | ~Size |
|---|---|---|
| `tool_executor/3` (binds DynamicTool.execute to issue context) | 2005–2041 | 37 |
| `prefix_with_ticket_namespace/2` | 2043–2059 | 17 |
| `declare_blocker_for_issue/2` (declare + immediate subscribe, bypasses poll lag) | 2061–2086 | 26 |
| `unblock_for_issue/2`, `issue_number_of/1` | 2088–2101 | 14 |
| `subscribe_for_issue/2`, `unsubscribe_for_issue/2`, `issue_identifier/1` | 2103–2127 | 25 |
| `emit_agent_event/4` | 2129–2149 | 21 |

### N. Run alerts (~60 lines)
| Function | Lines | ~Size |
|---|---|---|
| `maybe_emit_usage_limit_alert/4` (quota-exhausted pause alert) | 2156–2180 | 25 |
| `maybe_emit_more_tokens_alert/4` + `more_tokens_reason?/1` | 2182–2210 | 29 |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

Namespace convention follows in-repo precedent (`Aiur.Orchestrator.TrackedSet` at
`src/lib/aiur/orchestrator/tracked_set.ex`): submodules of `Aiur.AgentRunner` live under
`src/lib/aiur/agent_runner/`.

| # | Module | File | Responsibility | ~LOC | Key functions moving there |
|---|---|---|---|---:|---|
| 1 | `Aiur.AgentRunner` (retained facade) | `src/lib/aiur/agent_runner.ex` | Run entry and worker-attempt lifecycle: worker-host selection, workspace creation, before/after_run hooks, before_run pause/resume, transient-error policy. | 180 | `run/3`, `transient_run_error?/1`, `run_on_worker_host/4`, `run_worker_attempt/5`, `run_worker_attempt_once/5`, `pause_for_before_run_failure/7`, `wait_for_before_run_resume/3`, `selected_worker_host/2`, `maybe_attach_issue_log/1`, `write_pause_log/2,3` (shared, public `@doc false`), `issue_context/1` (shared, public `@doc false`) |
| 2 | `Aiur.AgentRunner.SessionLifecycle` | `src/lib/aiur/agent_runner/session_lifecycle.ex` | Start/stop one agent session: backend/model/effort/RC resolution, claude-repl→headless-claude fallback, RC workspace trust and chat naming, display tailer, repl-runtime reporting — ALL residual backend branching lives here. | 240 | `run_codex_turns/5` (renamed `run_session/5`), `start_agent_session/3`, `remote_session_backend/2`, `maybe_put_rc_name/3`, `rc_session_name/2`, `rc_session_prefix/1`, `repo_short_name/1`, `maybe_trust_remote_control_workspace/4`, `maybe_start_display_tailer/3`, `should_display_tail?/3`, `stop_display_tailer/1`, `report_repl_session/3`, `headless_os_pid/1`, `session_workspace/1`, `session_worker_host/1`, `session_backend/1` (last three public `@doc false`, shared) |
| 3 | `Aiur.AgentRunner.SessionResume` | `src/lib/aiur/agent_runner/session_resume.ex` | Session-resume handle lifecycle: load prior thread id (local+resumable gate), persist at start and on per-turn id drift, best-effort sidecar writes. | 150 | `load_resume_thread_id/3`, `resume_thread_id/3`, `maybe_put_resume_thread_id/2`, `session_resumed?/1`, `log_resume_outcome/3`, `maybe_persist_turn_handle/4`, `turn_handle_attrs/2`, `persist_session_handle/3`, `persist_handle_best_effort/3`, `session_handle_to_save/2` |
| 4 | `Aiur.AgentRunner.TurnLoop` | `src/lib/aiur/agent_runner/turn_loop.ex` | The autonomous multi-turn loop: run one prompt turn, triage ok/paused/error, refresh issue state, continue/max-turns/done, pause→resume re-entry. | 230 | `do_run_codex_turns/10` (renamed `run_turns/…` on a turn_context struct), `turn_done_reason/1`, `finalize_turn_completion/3`, `wait_for_resume/3`, `continue_issue_turn/2`, `continue_with_issue?/2`, `active_issue_state?/1`, `normalize_issue_state/1`, `max_turns_display/1` |
| 5 | `Aiur.AgentRunner.TurnPrompt` | `src/lib/aiur/agent_runner/turn_prompt.ex` | Pure prompt policy: cold-start vs continuation vs resumed-session first-turn text. | 70 | `build_turn_prompt/4` (public, replaces `build_turn_prompt_for_test/4`), `resumed_turn_prompt/0`, `turn_of/1` |
| 6 | `Aiur.AgentRunner.QueueDrain` | `src/lib/aiur/agent_runner/queue_drain.ex` | Queued-message drain: the paused/waiting selective-receive protocol (`:agent_queue_updated` / `:pause_agent` / `:resume_agent`), queue-item claiming via orchestrator, queue-item turns incl. completion-race requeue, item→text rendering. | 270 | `drain_operator_messages/5`, `wait_for_operator_message/5`, `try_claim_after_queue_update/6`, `claim_after_queue_update/3` (public, replaces `_for_test`), `claim_and_run_or_continue/5`, `drain_queued_operator_messages/5`, `claim_next_queue_item/2`, `claim_next_wake_queue_item/2`, `claim_next_operator_item/2`, `run_operator_turn/6`, `run_queue_item_turn/6`, `queue_item_turn_id/1`, `record_operator_delivery/2`, `queue_item_text/1` |
| 7 | `Aiur.AgentRunner.CheckpointDelivery` | `src/lib/aiur/agent_runner/checkpoint_delivery.ex` | Mid-turn delivery handlers: safe-checkpoint queue claim, urgent blocker-critical digests, REPL immediate operator paste, delivery-failure requeue-vs-fail policy. | 120 | `operator_immediate_handler/2`, `immediate_operator_delivery/3`, `safe_checkpoint_handler/2`, `fallback_checkpoint_claim/3`, `urgent_checkpoint_delivery/4`, `render_urgent_events_digest/1`, `claim_blocker_critical_events_digest/2`, `claim_next_checkpoint_queue_item/2`, `safe_checkpoint_delivery/4`, `handle_checkpoint_delivery_failure/4` |
| 8 | `Aiur.AgentRunner.EventsDigest` | `src/lib/aiur/agent_runner/events_digest.ex` | Render agent-visible `<aiur:events>` digests: CODEOWNERS trust filter (default-untrusted for github source), block/unblock debounce, external-content wrapping + HTML-attr escaping. | 190 | `render_events_digest/2` (public `render/2`, replaces `_for_test`), `author_trusted_for_digest?/1`, `debounce_block_state_events/1`, `block_state_group_key/1`, `debounce_group/2`, `debounce_keep_or_drop/4`, `within_debounce_window?/3`, `block_state_debounce_seconds/0`, `render_event_line/1`, `event_field/2` (public `@doc false` — shared with BootstrapDigest/QueueDrain), `event_summary/1`, `maybe_wrap_external_content/2`, `wrap_external/2`, `html_attr_escape/1` |
| 9 | `Aiur.AgentRunner.BootstrapDigest` | `src/lib/aiur/agent_runner/bootstrap_digest.ex` | First-turn bootstrap: attach universal subscriptions, replay missed events from publisher logs since the subscriber cursor, merge comment context, single batched enqueue to the orchestrator. | 140 | `maybe_enqueue_bootstrap_digest/1`, `maybe_attach_universal_subscriptions/1`, `bootstrap_events/2`, `bootstrap_event_key/1`, `comment_event_id_or_nil/1`, `bootstrap_cursor_for_log/1`, `publisher_ids_for_patterns/1`, `publisher_ids_for_pattern/1`, `matches_any_pattern?/2`, `enqueue_bootstrap_if_any/3`, `enqueue_bootstrap_batch/2` |
| 10 | `Aiur.AgentRunner.CommentContext` | `src/lib/aiur/agent_runner/comment_context.ex` | Fetch and filter GitHub issue/PR comment context into bootstrap events: workpad cutoff, unaddressed review threads, sanitization, trust flags. | 240 | `current_comment_context_events/2` (public `events/2`, replaces `_for_test`), `issue_comment_context/2`, `pr_comment_context_events/3`, `pr_comment_context_events_for_pr/4`, `comment_context_fetchers/0`, `fetch_comment_events/3`, `fetch_unaddressed_review_thread_events/3`, `comments_to_events/2`, `comments_after_workpad/2`, `latest_workpad_comment_datetime/1`, `latest_datetime/1`, `workpad_comment?/1`, `comment_after_cutoff?/2`, `comment_datetime/1`, `parse_comment_datetime/1`, `comment_context_event/2`, `comment_author/1`, `comment_body/1`, `comment_event_id/1`, `pr_number/1`, `log_comment_context_open_pr_failed/2` |
| 11 | `Aiur.AgentRunner.MessageHandler` | `src/lib/aiur/agent_runner/message_handler.ex` | Per-message fan-in for a turn: normalize backend events, write the agent event log, broadcast transcript/turn events, notify the recipient (codex updates, control state, worker runtime info). | 150 | `codex_message_handler/6` (public `build/6`), `maybe_broadcast_transcript/4`, `maybe_broadcast_turn_event/3`, `transcript_event_from/3`, `legacy_transcript_event/2`, `role_for_event/1`, `event_kind/1`, `body_for_event/1`, `get/2`, `timestamp_for/1`, `send_codex_update/3`, `send_control_state/3` (public `@doc false` — used by facade/TurnLoop/QueueDrain), `send_worker_runtime_info/4` |
| 12 | `Aiur.AgentRunner.TurnStreams` | `src/lib/aiur/agent_runner/turn_streams.ex` | Opencode bridge turn markers: register in ActiveTurns before fan-out, post `__aiur_turn__:<id>` to attached SessionWriters, matched close broadcast + mark_closed. | 60 | `open_aiur_turn_streams/1` (public `open/1`), `post_aiur_turn_markers/4`, `close_aiur_turn_streams/3` (public `close/3`) |
| 13 | `Aiur.AgentRunner.ToolExecutor` | `src/lib/aiur/agent_runner/tool_executor.ex` | Bind DynamicTool execution to issue context: ticket-namespaced alert/event emission, subscribe/unsubscribe, blocker declare (with immediate subscription) and unblock. | 160 | `tool_executor/3` (public `build/3`), `prefix_with_ticket_namespace/2`, `declare_blocker_for_issue/2`, `unblock_for_issue/2`, `issue_number_of/1`, `subscribe_for_issue/2`, `unsubscribe_for_issue/2`, `issue_identifier/1`, `emit_agent_event/4` |
| 14 | `Aiur.AgentRunner.TurnAlerts` | `src/lib/aiur/agent_runner/turn_alerts.ex` | Operator alerts for turn outcomes: quota-exhausted pause alert, token/context-exhaustion failure alert. | 60 | `maybe_emit_usage_limit_alert/4`, `maybe_emit_more_tokens_alert/4`, `more_tokens_reason?/1` |

Total ≈ 2270 LOC (module headers/aliases add ~50 over today's 2215).

Norm-target notes (judgment calls, flagged for reviewers):
- `SessionLifecycle` (~240), `QueueDrain` (~270), `CommentContext` (~240), `TurnLoop`
  (~230) exceed the 200-line file target. Each is one cohesive concern whose further
  split would create artificial seams; `SessionLifecycle` additionally shrinks
  substantially when the backend-behaviour ticket deletes the branching it concentrates.
- `do_run_codex_turns/10` and `run_queue_item_turn/6` share an identical
  execute-one-turn spine (handler wiring, control state, `TurnStreams.open`, quota
  reset, `CodingAgent.run_turn`, `TurnStreams.close`). Deduplicating that spine is a
  follow-up *after* both waves land, behind the characterization tests below — not part
  of the mechanical move.
- Dependency direction (all one-way): facade → {SessionLifecycle, TurnLoop, BootstrapDigest};
  SessionLifecycle → {SessionResume, TurnLoop}; TurnLoop → {TurnPrompt, MessageHandler,
  TurnStreams, ToolExecutor, TurnAlerts, CheckpointDelivery, QueueDrain, SessionResume};
  QueueDrain → {MessageHandler, TurnStreams, ToolExecutor, TurnAlerts, CheckpointDelivery,
  EventsDigest}; CheckpointDelivery → EventsDigest; BootstrapDigest → {CommentContext,
  EventsDigest (event_field)}. No module imports the facade.

Test-support surface policy: `*_for_test` wrappers are dropped; the wrapped private
function becomes the moved module's public (`@doc false` where appropriate) API and test
call sites are updated in the same wave. `AgentRunner.run/3` and
`AgentRunner.transient_run_error?/1` keep their names/arity (orchestrator +
agent_runner_test contract).

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

Every wave: move code verbatim (comments included), add aliases in the shrinking
`agent_runner.ex`, update test call sites in the same commit, then
`mix compile --warnings-as-errors` + full `mix test` green before the next wave starts.
Wave sizes are lines *moved* (source + test-reference churn stays ≤400).

1. **Wave 1 — pure leaves: `EventsDigest` + `TurnPrompt`** (~270 moved).
   No inbound state, no receives, no process identity. `event_field/2` becomes public
   here so later waves can use it. Tests: `render_events_digest_for_test` →
   `EventsDigest.render/2`; `build_turn_prompt_for_test` → `TurnPrompt.build_turn_prompt/4`
   (agent_runner_test.exs, regression/event_flow_e2e_test.exs).
2. **Wave 2 — `CommentContext` + `BootstrapDigest`** (~380 moved).
   CommentContext first inside the wave (BootstrapDigest calls it). Tests:
   `current_comment_context_events_for_test` → `CommentContext.events/2`;
   issue_log_event_history_test doc reference.
3. **Wave 3 — `MessageHandler` + `TurnStreams`** (~215 moved).
   `post_aiur_turn_markers/4` keeps its name on `TurnStreams`; the register-before-post
   ordering in `open/1` moves verbatim. Tests: agent_runner_test `post_aiur_turn_markers`
   describe block; active_turns_test comments.
4. **Wave 4 — `ToolExecutor` + `TurnAlerts`** (~220 moved).
   Pure closures over orchestrator/Publisher/Alerts APIs; no receives.
5. **Wave 5 — `SessionResume`** (~150 moved).
   Pure gates + SessionHandle disk I/O. Tests: `resume_thread_id`, `session_resumed?`,
   `turn_handle_attrs`, `session_handle_to_save`, `persist_handle_best_effort` describes.
6. **Wave 6 — `SessionLifecycle`** (~240 moved).
   Concentrates the claude/claude-repl residual branching (report_repl_session,
   start_agent_session fallback, display tailer, RC trust/naming, remote_session_backend)
   into the single file the backend-behaviour ticket will edit. The `try/after
   stop_display_tailer + stop_session` block moves intact. Tests: `start_agent_session`,
   `maybe_trust_remote_control_workspace`, `rc_session_name`, `should_display_tail?`,
   `remote_session_backend` describes; repl_agent_test reference.
7. **Wave 7 — `CheckpointDelivery` + `QueueDrain`** (~390 moved).
   The timing-sensitive core: selective receives and claim/consume/restore/fail
   accounting move verbatim as plain function calls that keep executing IN the runner
   Task process (no GenServer, no Task.async — see risks). Tests:
   `claim_after_queue_update_for_test` → `QueueDrain.claim_after_queue_update/3`;
   "queue-update wake claiming" describe.
8. **Wave 8 — `TurnLoop` + facade shrink** (~230 moved).
   `do_run_codex_turns` moves last, once every callee already has its final home; the
   facade keeps only concern A. core_test / live_e2e_test `AgentRunner.run/3` scenarios
   are the acceptance gate — they must pass unmodified.

Rationale: leaves→core ordering means each wave's moved code has zero un-moved intra-file
dependents, so every intermediate state compiles without forward stubs; the two
receive-loop waves (7, 8) land when the surrounding code is already thin and pinned.

---

## 4. Risks: semantics that must be preserved verbatim

Hotspot-map anchors (`docs/refactor/research-history-hotspots.md`): row 6 (orchestrator
pause/resume races), row 8 (agent backends: RC prompt-delivery races, quota
misclassification), theme 1 (timing/submission races — #552 queued-operator-message
drain is on this file's seam), theme 2 (stale state on disk — session handles #610/#701),
theme 10 (guards clipping legitimate cases), and characterization item 7 (this file:
"queued-message drain outcomes (never converts success to failure), events-digest
filtering, session-resume handle lifecycle including terminal-state clearing").

### Concurrency / process identity
- **All receive loops run in the runner Task's own process.** The orchestrator sends
  `{:pause_agent, id}`, `{:resume_agent, id}`, `{:agent_queue_updated, identifier,
  item_id[, deliver_now?]}` directly to that pid. Extracted functions must remain plain
  calls on the same process; wrapping any of `wait_for_operator_message/5`,
  `drain_operator_messages/5`, `wait_for_before_run_resume/3` in a new process silently
  loses control messages.
- **No eager claim on paused entry** (comment at lines 1270–1277): `wait_for_operator_message`
  must keep waiting for an explicit wake; eager claiming re-created a pause-defeating
  tight loop (restore → re-claim → re-resume). This exact regression already happened once.
- **`drain_operator_messages`'s `receive ... after 0`** gives a pending `:pause_agent`
  priority over draining; reordering to "claim first, then check mailbox" changes
  pause semantics.
- **Register-before-post** in `open_aiur_turn_streams/1`: `ActiveTurns.put/2` must
  precede `TurnMarkers.post_all/4` or the bridge treats live markers as phantom
  (active_turns_test pins the raced side). Close must reuse the same `aiur_turn_id` and
  call both `broadcast_aiur_turn_done` and `ActiveTurns.mark_closed`.
- **`post_aiur_turn_markers` returns immediately even with slow/blocking posters and
  swallows post errors** (agent_runner_test pins both) — the fan-out contract lives in
  `Opencode.TurnMarkers.post_all/4`; do not add synchronous waiting.

### Queue-item accounting (exactly-once per turn outcome)
- Per turn result branch, exactly one of `consume_delivered_queue_items` (ok),
  `restore_delivered_queue_items` (paused, and the `:turn_start_failed` completion-race),
  `fail_delivered_queue_items` (error) fires. Splitting the result `case` across modules
  must not duplicate or drop a branch.
- **Never convert success to failure**: `run_queue_item_turn`'s
  `{:error, {:turn_start_failed, :response_timeout | :turn_timeout}}` branch restores the
  item and returns `:ok` (requeue-after-parent-turn, lines 1445–1453);
  `handle_checkpoint_delivery_failure` restores on `:parent_turn_completed` /
  `{:turn_interrupted, _}` / `{:turn_cancelled, _}` but marks failed otherwise. These
  distinctions are the hotspot-map item for this file.
- `transient_run_error?` (`:repl_gone`, `:prompt_not_delivered`) turning a raise into a
  clean `:ok` exit is retry-budget-critical (row 6: "retry budget burned by non-failures").

### Cleanup / teardown ordering
- `run_worker_attempt_once`'s `try ... after Workspace.run_after_run_hook` and
  `run_codex_turns`'s `try ... after stop_display_tailer + CodingAgent.stop_session`
  must survive as-is; the brutal-kill path only works because `report_repl_session`
  (pane_id/os_pid/headless bash pid) reached the orchestrator *before* turns started
  (orchestrator_deactivate_test pins this).
- `DynamicTool.reset_turn_quotas/0` fires before every `run_turn` in both turn sites.

### Backend / session semantics (waves 6–7 danger zone)
- `start_agent_session` fallback: only `"claude-repl"` falls back, fallback strips
  `:remote_control`, retags `:backend`, and emits the perf event; the display tailer
  gates on the *post-fallback* backend (`should_display_tail?` — RC + "claude-repl" only).
- Resume gates: local worker + `CodingAgent.resumable?` + binary thread id, per-turn
  handle persist only on id drift, `persist_handle_best_effort` rescue-swallows (a
  sidecar write must never kill a live run). Stale-handle history: #610/#701 (theme 2);
  note `SessionHandle.clear` is wired in the *orchestrator* (orchestrator.ex:4176), not
  here — do not "helpfully" add clearing to this file during the move.
- First-turn prompt choice depends on `opts[:resumed]` set from `session_resumed?/1`
  (issue #378 semantics: resumed threads continue, never replay the cold-start prompt).

### Security-sensitive filters (move byte-for-byte)
- `author_trusted_for_digest?/1` default-untrusted for github-sourced events (CODEOWNERS
  gate; row 1 theme "trust gates silently dead"), `maybe_wrap_external_content/2` +
  `html_attr_escape/1` (prompt-injection defense), `Sanitizer.scrub` in
  `comment_context_event/2`, and the workpad-cutoff + unaddressed-review-thread exception
  in CommentContext (the #634→#642→#682 fix-of-fix chain lives exactly on this filter —
  theme 10: guards clip legitimate cases).
- Digest render side effects: DebugLog `:read` broadcast happens for *all* events while
  the agent-visible render is filtered/debounced — audit trail vs agent view must not merge.
- Bootstrap enqueue stays ONE batched `GenServer.call` (5s timeout, `catch :exit`) — do
  not reintroduce per-event orchestrator calls (comment at lines 490–493).

### Existing test pins (behavior contract)
- `src/test/aiur/agent_runner_test.exs` (671 lines) — the `@doc false` unit surface:
  markers, session start/fallback, RC trust/naming, transient errors, display-tail gate,
  resume/handle lifecycle, wake claiming, digest trust rendering, prompt choice.
- `src/test/aiur/core_test.exs` (~10 `AgentRunner.run/3` end-to-end scenarios with a
  scripted fake codex binary, lines ~1400–2810) — full-lifecycle characterization; the
  strongest guard for waves 7–8.
- `src/test/aiur/live_e2e_test.exs:501` — `run/3` with `max_turns`.
- `src/test/aiur/regression/event_flow_e2e_test.exs` — digest render through the
  runner-visible closure.
- `src/test/aiur/issue_log_event_history_test.exs` — bootstrap replay from publisher logs.
- `src/test/aiur/opencode/active_turns_test.exs` — marker/bridge race semantics.
- `src/test/aiur/orchestrator_deactivate_test.exs` — repl-runtime reporting on abort.
- `src/test/aiur/claude/repl_agent_test.exs` — repl→headless fallback integration.

### Missing characterization coverage (add before waves 7–8)
1. **Paused-state receive protocol**: pause → `:agent_queue_updated deliver_now?=false`
   (must keep waiting) → `deliver_now?=true` (claims) → repeated `:pause_agent` while
   paused (no tight loop) → `:resume_agent` drains restored items in the same turn.
   Nothing unit-pins the no-eager-claim invariant today.
2. **Never-success-to-failure drain outcomes**: the `:turn_start_failed` completion-race
   requeue and each `handle_checkpoint_delivery_failure` clause (restore vs mark-failed)
   have no direct tests.
3. **Exactly-once delivered-queue accounting** per ok/paused/error branch (consume vs
   restore vs fail), incl. `restore_queue_item_pending` on immediate-delivery send failure.
4. **Debounce window semantics**: block/unblock coalescing across the configured window,
   the missing-timestamp always-collapse fallback, and ordering by id after merge.
5. **Alert paths**: `maybe_emit_usage_limit_alert` (only `kind: :usage_limit_exhausted`)
   and `maybe_emit_more_tokens_alert` reason matching.
6. **before_run pause loop**: `pause_for_before_run_failure` →
   `:resume_after_before_run_pause` re-attempt recursion in `run_worker_attempt/5`.
7. **`bootstrap_events` pattern→publisher-log mapping** for wildcard-id patterns and the
   `system.*` skip (documented gap; lock current behavior so the refactor doesn't
   silently "fix" it).
