# Capability baseline — Bucket 2 (platform improvements, E1–E6)

Part of the [capability baseline](capability-baseline.md) (Phase A), split out to keep each file under 500 lines. Verified against `origin/main` @ `45a290e3`; the status legend (EXISTS, PARTIAL, NEW), method and summary table are in the [index](capability-baseline.md). Other parts: [bucket 1](capability-baseline-bucket-1.md), [bucket 2](capability-baseline-bucket-2.md), [bucket 3](capability-baseline-bucket-3.md).

---

## 2. Bucket 2 — Platform improvements

### E1 — Build queue — PARTIAL

**Build orders:**
- A root is a GitHub issue labelled **`build-order`**.
  - Members are its GitHub **sub-issues**. Edges are native GitHub **`blockedBy`** issue dependencies.
  - Lanes and phases come from `build-lane:*` and `phase:*` labels.
  - GraphQL lives in `src/lib/aiur/build_order/github_graph/queries.ex`.
- Modules in `src/lib/aiur/build_order/`: `GitHubGraph` (`fetch_catalog/1`, `fetch_selected_root/2`), `GraphProjection*`, `Catalog`, `CatalogStore`, `RootSummary`, `Member`, `Dependency`, `DependencyChain`, `GraphAnalysis`, `EdgeState`, `ProgressRenderer`, `PackStatus`, `AdHocSource`.
  - `EdgeState.classify/2` returns `:cleared | :blocking | :terminal_unsatisfied | :unknown | :cyclic`.
- The catalog is event-sourced from `sub_issues` and `issue_dependencies` webhooks (#2336).
- **Progress %** (`github_graph/normalizer.ex`): `round(closed_completed / resolved_members * 100)`. It is stored in `RootSummary.progress` and rendered by `ProgressRenderer.terminal/1` and `json/1`. `not_planned` counts as resolved but not completed.
- **`Aiur.BuildOrder.Readiness.from_edges/1`** is display-only. It is used by `aiur_web/build_order_presenter.ex`, `build_order_view_model.ex` and `build_order/ticket_context_adapter.ex`. No orchestrator module references `Aiur.BuildOrder`.
- **`AdHocSource`** is a runtime overlay for `build-lane:adhoc` tickets created during a run.
- **CLI:** `aiur build-orders [<root>] [--json]` (`Aiur.BuildOrdersCLI`), read-only.
- **Dashboard:** `/build-orders` and `/build-orders/:root_number` (`AiurWeb.BuildOrderLive`).
- **Config:** `build_order.*` (cadences, caps).
- **Tests:** `test/aiur/build_order/*`, `test/aiur/build_orders_cli*_test.exs`, `test/aiur_web/build_order/*`, `test/aiur_web/live/build_order_live_test.exs`.

**Readiness labels and dispatch:**
- **State labels** (`src/lib/aiur/github/labels.ex`), with the `agent:` prefix: `todo in-progress ci-wait human-review rework merging done error cancelled canceled`.
- **Marker labels:** `watch`, `paused`, `parked`, `rate-limit-fallback`.
- **There is no `agent:backlog` label** (searched for it).
- `agent:todo` triggers dispatch. Its authorization depends on who applied the label (`github/dispatch_authorization.ex`).
- **Dispatch eligibility** (`src/lib/aiur/orchestrator/dispatch_policy.ex`, `dispatch_state_decision/4`) checks, in order:
  1. `blocked_on_decision?` → `{:skip, :blocked_on_decision}`
  2. `todo_issue_blocked_by_non_terminal?/2` (line ~1001) → `{:skip, :dependency}`. This applies only to `todo`.
  3. `:already_running`
  4. `:state_capacity`
  5. `:worker_capacity`
- Blocker edges come from `Aiur.GitHub.BoundedBlockedBy`, cached up to 15 min.
- **Ordering among ready tickets** **[re-verified]:** `dispatch_policy.ex` sorts by `{priority_rank(issue.priority), created_at, identifier}`, where priority is 1–4 (tracker priority) and anything else ranks 5.
- **Capacity:**
  - `agent.max_concurrent_agents`, changeable at runtime with `aiur set max-agents <n>`
  - `agent.max_concurrent_agents_by_state`, `agent.max_concurrent_builds` (4)
  - Load governor: `agent.max_load_average`, `target_load_average`, `load_ramp_step`, `load_cooldown_seconds`
  - Overflow alert: `system.dispatch.todo_capacity_exceeded`
- **Operator queueing:**
  - `aiur --todo <ids> [--only]` queues tickets. `--only` removes `agent:todo` from other pending tickets, bounded to 50.
  - The idle backoff (`polling.idle_widen_factor` 5.0) is collapsed by `--todo`.
- **Planning convention** (skills `aiur-build` / `aiur-run`): every executable member gets `agent:todo` **when it is created**, blocked or not. Parked work uses `needs-triage` or `human:todo`.

**On merge** (`MergedTicketReconciler`, `PushRouting`):
- The blocker becomes `done` only if the PR body says `Closes|Fixes|Resolves #N`.
- `PushRouting.maybe_resume_blockees_on_merged_ticket/2` resumes only **running, paused** blockees (`paused_reason: :blocker_dependency`).
- `ticket.<blocker>.pr.merged` is in the mid-turn drain set (#2566, `b80971f89`).
- A **dependent still in `todo` is not relabelled**. On the next poll, made faster by the `issues.closed` webhook → `request_refresh`, it is simply no longer skipped and dispatches if capacity allows.
- Tests: `orchestrator/blocker_merge_wake_test.exs`, `push_routing_test.exs`, `merged_ticket_reconciler_test.exs`, `merged_ticket_dispatch_test.exs`, `dispatch_policy_test.exs`, `dispatcher_blocked_by_cost_test.exs`.

**Gaps for E1:**
- No queue entity: no membership, order or controls beyond labels and `--todo`.
- No relabel-on-unblock. Promotion only works because dependents are labelled `agent:todo` ahead of time.
- No executor-created queue without build-order data. The closest thing is `--todo --only`.
- **Semantic mismatch:** dispatch treats a `not_planned`-closed blocker as cleared (any GitHub-closed blocker counts), while the Build Order view classifies it `:terminal_unsatisfied`.
- Merge-to-ticket association relies on closing keywords in the PR body.

### E2 — Native command capture, executor awareness, human escalation — PARTIAL

**Terminology:**
- The code says **Decision** (`Aiur.Decision`, `Aiur.DecisionStore`).
- The UI, CLI and docs say **Command** (`src/lib/aiur/decision_command_type.ex`: "Data-driven classification of Command types").
- Exact UI strings **[re-verified]**:
  - `"1 unit awaiting commands"` / `"#{open} units awaiting commands"` (`components/operator_control_center/overview.ex`)
  - aria `"#{@open} Commands awaiting you, #{@blocking} blocking"`
  - CTA `Issue commands`
  - Nav `Commands` (`route_registry.ex`, path `/commands`)
  - Fleet table column `Commands` (`fleet_table.ex`, value `row.open_decision_count`)
  - `Commands inbox`, `No Commands match this filter.` (`decision_inbox.ex`)
  - `Command history`, `Executor answer`, `Deferred to Executor`, `Handed to the Executor` (`history.ex`)
  - `Defer to Executor` / `Notify Executor again`, `Retry delivery` (`decision_action.ex`)
- Not found: "commands requested", "commands needed".

**Model:** `Aiur.Decision` (`src/lib/aiur/decision.ex`).
- Identity and content fields: `decision_id`, `ticket`, `source{agent_id, session_id, event_id}`, `kind`, `authority`, `urgency`, `blocking`, `reversibility`, `question`, `context{short_summary, long_context_markdown}`.
- Options and advice: `options[{id, label, description, benefits, drawbacks, risk}]`, `recommendation{option_id, reason}`, `consequence_of_delay`, `artifacts`.
- Lifecycle fields: `decision_status`, `delivery_status`, `answer`, `revisions`, `dispatch_attempts`, `acknowledgement(s)`, `resolution(s)`, `content_hash`.
- **authority:** `:human_required | :supervisor_allowed | :supervisor_preferred`.
- **decision_status:** `:open | :deferred | :expired | :dismissed | :moot | :decided | :acknowledged | :resolved`.
- **delivery_status:** `:not_dispatched | :pending | :queued | :delivered | :consumed | :failed`.

**Authority policy** (`Aiur.DecisionAuthority`):
- `human_required` is absolute. The Executor may answer only `:reversible` items.
- Config `decisions.supervisor_allowed_kinds` (default `[]`) and `decisions.supervisor_allow_non_reversible` (default false).
- Kind defaults (`DecisionCommandType`):
  - `rework_review` → `supervisor_preferred`
  - `sequencing` → `supervisor_allowed`
  - `legacy_attention` → `human_required`
  - Anything else → `supervisor_allowed` + reversible

**Raising a Command:**
- There is no dedicated tool. The agent calls `emit_event` (`codex/dynamic_tool/emit_event.ex`) with:
  - `decision.requested` (structured payload), or
  - `attention.<slug>` (legacy, human-required), or
  - `blocked` / `pause.request` with `{reason: "operator_decision", question}`.
- Wiring in `agent_runner/tool_executor.ex`: `DecisionStore.request/2`, `DecisionAttention.open_with_decision/6`.
- `Aiur.DecisionAttention` re-asks every 15 min. The alert prefix is `"Executor decision required: "`.

**Store:** `Aiur.DecisionStore` (single-writer GenServer).
- **Persist before notify:** append and fsync to `decisions.ndjson`, update the `decisions.json` projection, then publish on the Exchange and on PubSub.
- Directory: `Config.Paths.decision_state_dir/0`.
- **Functions:** `request`, `answer/5`, `escalate_executor_command/4`, `dismiss`, `defer`, `expire`, `moot`, `supersede`, `revise`, `retry_dispatch`, `deliver_pending_answers/2`, `agent_lifecycle`, plus retained reads.
- **Event types:** `requested`, `enriched`, `decision_{expired,dismissed,deferred,mooted}`, `executor_escalated`, `answer_recorded`, `revision_recorded`, `dispatch_queued`, `delivered`, `restored`, `consumed`, `failed`, `acknowledged`, `resolved`, and others.

**Delivery to the worker:**
- `Aiur.DecisionDispatch.dispatch/2` → `OperatorMessages.send_correlated_operator_message/3`. The answer is addressed to the **ticket**, not the asking session. Maximum 7,800 characters.
- Redelivery to a newly spawned worker: `deliver_pending_answers/2` (#2713).
- An answer resumes a self-paused worker (`orchestrator/operator_messages.ex`, `PauseResume.input_pause_reason?/1` = `[:agent_pause_request, :input_required]`; #2738).

**Who answers, and from where:**
- **Dashboard:** `/commands`, `/commands/:decision_id`. Events `answer-decision`, `defer-decision`, `dismiss-decision`, `retry-decision`, `revise-decision` (`operator_control_center/decision_events.ex`).
- **Stream Deck:** `answer_command`.
- **CLI:**
  - `aiur commands [id] [--filter …] [--json]`
  - `aiur executor-answer ID --expected-version --rationale --idempotency-key (--option|--custom-response)`
  - `aiur executor-escalate ID --expected-version --reason`
  - `aiur executor-moot ID …`
- **Supervisor API** (bearer `AIUR_SUPERVISOR_TOKEN`): `GET /api/v1/decisions[/:id]`, `POST /api/v1/decisions/:id/{enrich,decide,revise}`.
- Answers carry optimistic concurrency (`expected_version`, `idempotency_key`). This is the existing mechanism for conflicting responders.

**Executor → human requests (separate store):**
- `aiur ask "Title" [--body|--body-file] [--urgency] [--blocking]` and `aiur ask --done ID` (`Aiur.Asks`, `asks_store.ex`). IDs start with `ask_` and the store is append-only.
- **Not shown in the dashboard:** `src/lib/aiur_web` has no references to `Aiur.Asks`.

**Native question capture:** none **[re-verified]**.
- **Codex** (`src/lib/aiur/codex/approvals.ex`, `user_input_answers.ex`):
  - Approval requests are auto-approved (`acceptForSession`) or declined while paused.
  - `item/tool/requestUserInput` is auto-answered `"Approve this Session"` or `"This is a non-interactive session. Executor input is unavailable."`. Anything else ends the turn as `:input_required`.
- **Claude:**
  - `permission_mode` defaults to `bypassPermissions` (`src/lib/aiur/claude/config.ex`).
  - Hooks: `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure` (`hook_settings.ex`).
  - No `AskUserQuestion` or `PermissionRequest` handling.
- **Muse** maps `userInput/request` to `:native_user_input_required` (`muse/turn_loop.ex`).

**Tests:** about 35 `src/test/aiur/decision_*_test.exs` files, `decision_store/`, `executor_command_cli_test.exs`, `executor_command_attention_test.exs`, `codex/approvals_test.exs`, `user_input_answers_test.exs`, `aiur_web/supervisor_auth_test.exs`.

**Gaps for E2:**
- Native questions are not captured.
- No executor-first versus simultaneous routing policy. Today authority decides who *may* answer; routing order does not exist. The Executor is always made aware through `DecisionAttention` alerts and wakes.
- The Executor cannot raise a Command for itself; it uses `aiur ask`, a separate store with no UI.
- No suggested-response count rule (options are free-form).
- Answers are addressed to the ticket, not the session.

### E3 — First-class executor communication — NEW (only coordination primitives exist)

**What exists:**
- The wake inbox and CLI (R2).
- `Aiur.Executor.Principal`: started only by `aiur --executor`, with a 10-minute lease.
- `Aiur.Executor.Claims.resolve_consumer_id/1`: `--as`, then `AIUR_EXECUTOR_ID`, then `<hostname>-<instance>`.
- `Aiur.Executor.Roster`: states `active | idle | stalled | expired | unknown`; `aiur executor-roster`. Its moduledoc says "Multiple executors are a supported configuration".
- `Aiur.Executor.TakeoverAlert`, `Aiur.Executor.Handoff`.
- `Aiur.ExecutorCommandAttention`.

**Claude Remote Control is for worker agents only:**
- Config `agent.remote_control` (default false; `config/schema/agent.ex`) and the routing suffix `+remote` (`config/routing_value.ex`).
- `Aiur.Claude.ReplAgent` runs `claude --remote-control` in a hidden tmux pane.
- `Aiur.Claude.RemoteControl.parse_session_url/1` (`https://claude.ai/code/session_…`).
- The TUI `r` key; `Aiur.Orchestrator.RemoteControlMode`.
- Lifecycle hook endpoint `POST /api/v1/:issue_identifier/claude-hook` (this is why `--no-dashboard` is refused when RC is on).
- Dashboard units table: an RC deep link (`title="Remote control"`) and `"Under Remote Control"` disabled controls.
- The owner's current Executor RC usage is their own Claude Code session, outside Aiur.

**Not found:**
- An Executor harness type (Claude/Codex) in principal or claims.
- Executor transcript capture or ingestion.
- A dashboard Executor page or panel.
- An Executor input channel. Searched `src/lib/aiur_web` for executor + conversation/chat.

**Current terminology:** "Executor", "wake", "claim", "roster", "principal", "takeover".

**Gaps:** essentially the whole feature, including session identity, conversation history and normalized input across Claude and Codex.

### E4 — Dashboard conversations, logs, event navigation — PARTIAL

**Routes:**
- `/` (`DashboardLive :index`), `/chat/:owner/:repository/:identifier` (the same LiveView with the drawer open), `/commands[/:id]`, `/build-orders[/:root]`, `/analytics`, `/streamdeck`.
- JSON:
  - `GET /api/v1/state`
  - `GET /api/v1/:issue_identifier`
  - `GET /api/v1/:issue_identifier/events` (`AgentEventFeed.list/2`, limit 1–50, integer cursor)
- Writes:
  - `POST /api/v1/:issue_identifier/{messages,pause,resume}` and `POST /api/v1/refresh` (writable-gated)
  - `POST /api/v1/pane/{interrupt,hide}`

**Transcript sources:**
- `Aiur.AgentLog`: workspace `logs/agent.ndjson`, falling back to `logs/agent.md`, in an 80-message window.
- `Aiur.AgentEventLog` writes both files.
- `Aiur.IssueLog`: a per-issue transcript plus event history under `<logs-root>/log`.
- `Aiur.LiveConversation` (`live_conversation.ex` + `normalizer`, `compactor`, `retention`, `source`):
  - An in-memory projection isolated per generation (80 messages / 64 KB).
  - Snapshot `state`: `:live | :ended | :known_empty | :stale | :unavailable | :restart_unknown`.
  - PubSub `live-conversation:changed`.
  - It is not voice-related, despite its name.

**UI:**
- **Conversation drawer** (`components/operator_control_center/conversation_drawer.ex`):
  - Labels `Conversation`, `Agent log`, `Last observation`, `Messages`.
  - Placeholder `Message agent…`, buttons `Pause` / `Send`, dictation and voice controls.
  - Read-only text: `Read-only dashboard — use the TUI to message or pause this agent.`
- **Agent log modal** (`agent_log_modal.ex`).

**Milestone model:**
- **`emit_alert`** (`codex/dynamic_tool/emit_alert.ex`): `name`, `message`, `reason`, `needs_attention`, optional `severity`. Topics `ticket.<id>.agent.<name>`.
- **Phase events:** `phase.{brainstorm,plan,work,review}.{start,end}` (`.claude/skills/aiur-agent/turn-workflow.md`; stages validated in `ticket_observation.ex`).
- **Alerts:** `Aiur.Alerts` (categories) and `Aiur.AlertLedger` (`*.alerts.ndjson`, 8 MiB). `Aiur.AlertFeed.list/1` reads them.
- **Ticket activity:** `Aiur.TicketActivity` (PubSub `ticket-activity:changed`).
- **Workpad:** an `## Agent Workpad` GitHub comment. It is not rendered in `aiur_web`.
- **Progress updates every few minutes** **[re-verified]:** `Aiur.ProgressCheckin.Worker` publishes `ticket.<id>.operator.progress_request` to **worker** agents every 5 min (`@default_interval_ms 5 * 60 * 1_000`). Agents reply with `progress` / `progress.checkin`, which drive the "Executor bar". These are worker progress reports that the Executor sees. No Executor-authored progress stream was found.

**Jump points:**
- **Bus labels** (`Aiur.AgentEventFeed @topic_labels`): `Progress`, `Progress check-in`, `Phase change`, `Blocked`, `Unblocked`, `Paused`, `Resumed`, `Pause requested`, `Remote control`, `Tokens exhausted`, `Comment`, `PR opened`, `PR merged`, `Review comment`, `CI passed`, `CI failed`, `Decision requested`, `Decision seen`, `Decision resolved`.
- **Build Order ticket context** (`build_order/ticket_context_presenter.ex`):
  - Phase labels and "Pull request updated", "Branch updated", and similar.
  - Capability links `Issue`, `Pull request`, `Chat`, `Commands`, `Planning doc`.
  - #2891 opens Build Order worker chats.

**Event→conversation anchor:** only `AiurWeb.StreamdeckLogs`, using the timestamp-based "last event at or before" rule (R6). There are no byte offsets or line numbers.

**Tests:** `src/test/aiur/{agent_log,alert_feed,alerts,live_conversation,live_conversation_restart}_test.exs`, `aiur_web/streamdeck_logs_test.exs`, `aiur_web/dashboard_live_test.exs`, `aiur_web/operator_control_center/*`.

**Gaps for E4:**
- No commit jump point (`ticket.*.branch.push` exists on the bus but has no label in the feed).
- No Command→transcript link.
- No dashboard chronology view keyed by event (the Stream Deck has one).
- `LiveConversation` is bounded and in-memory. Full history must come from `IssueLog` and workspace logs.
- No Executor stream.

### E5 — First-party dashboard voice input — EXISTS for worker chat; PARTIAL against the brief

**Evidence:**
- Drawer controls: `data-voice-mic`, `data-voice-conversation`, `data-voice-device` (labelled "Browser microphone" / "Default microphone"), `data-voice-waveform` ("Microphone waveform"), `data-voice-status`, `data-voice-send`.
- Help text **[re-verified]**: `"Press the microphone to dictate. Review the text, then press Send."`
- Dictation is a toggle, not hold-to-talk. **The transcript is reviewed before sending in dictation mode** (the existing behaviour).
- JS: `src/priv/static/conversation-voice-controller.js` and `voice-capture-worklet.js`, loaded in `components/layouts.ex`.
- Channel `voice:dictation`. Browser test `src/test/browser/tests/units.browser.spec.mjs`.

**Gaps:**
- No mic on dashboard Command answers. The Stream Deck has dictated Command answers; the dashboard does not.
- No Executor target.
- No explicit cancel or delivery-state UX beyond the composer.

### E6 — Independent conversational voice component — PARTIAL (embedded, not independent)

**Evidence:**
- Channel `voice:conversation` (`AiurWeb.VoiceChannel`) is half-duplex.
  - The user presses, speaks and presses again.
  - On `stopped` the form auto-submits (`submitConversationTurn` → `form.requestSubmit`).
  - The client watches for the worker's next completed reply (`.conversation-message-agent[data-message-complete='true']`) and sends `speak`. The server streams TTS PCM back (`audio`, `audio_done`, `audio_error`).
- Config `elevenlabs.voice_id`.
- **Note:** this mode sends the spoken turn straight to the worker agent with no review step. That is a different contract from dictation mode.

**Not found:**
- ElevenLabs Conversational AI or Agents API (`convai`).
- An assistant persona or role pre-context.
- A transcript store for voice conversations separate from the agent conversation.
- A raw-audio retention policy. Audio is streamed and not stored.

**Gaps:** E6's "communication-oriented assistant that consults the agent" does not exist. Today the voice conversation *is* the worker conversation.

---

