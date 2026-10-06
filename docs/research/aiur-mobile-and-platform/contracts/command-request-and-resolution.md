---
contract_id: MP-CT-command-request-and-resolution
owner_feature: MP-E2
status: Phase C reconciled (2026-10-06) — final reconcile in Phase D
base_main_sha: 45a290e3
date: 2026-10-06
consumers: MP-E3, MP-E4, MP-E5, MP-E6, MP-E7, MP-N3, MP-N4, MP-N5, MP-N6, MP-N7, MP-R6 (Stream Deck)
consumes: MP-CT-identity, MP-CT-events-and-replay (MP-R2), MP-CT-harness-adapter (MP-R7), MP-CT-capabilities
tickets: ../bucket-2-platform/MP-E2/tickets/README.md
---

# Contract: Command request and resolution

A **Command** is aiur's durable request for input from the Executor or the human. In the
code it is `Aiur.Decision`, and this contract keeps that model. It **extends** the model
and does not replace it: every field and transition named here as *existing* is on `main`
at `45a290e3`. Fields marked **NEW** are proposals that MP-E2 implements; the ticket that
implements each one is named in brackets.

Settled decisions this contract encodes: D9 (routing by authority), D10 (only native
ask-the-user tools), D11 (first answer wins, human supersede until delivery), D12
(Executor-originated Commands). See `../context-and-decisions.md`.

**Phase C changes** (recorded so consumers can re-check): the wire `ticket` stays required
(§2); v2 attributes travel in a new lifecycle event, not in the request snapshot (§3, §11);
config keys moved to the existing `decisions.*` namespace (§5); escalation causes are a
closed list (§5); the Executor acknowledgement is defined (§5); the conflict tuple is not
changed and the winning-answer summary is read separately (§6); in-band delivery reuses
the operator-message queue (§7.1); Executor delivery goes through the wake inbox (§7.2).

## 1. Ownership

| Concern | Owner | Notes |
| --- | --- | --- |
| Command record, lifecycle, persistence | `Aiur.DecisionStore` (single writer) | `decisions.ndjson` is authoritative, `decisions.json` is a projection (KTD10). |
| Routing and escalation | **NEW** `Aiur.Commands.Routing` [C2-T01, C2-T03] | A separate module. `decision_store.ex` is 4,826 lines, so it must not grow beyond one entry point (KTD1). |
| New fact types | **NEW** `Aiur.Commands.EventData` / `Aiur.Commands.Projection` [C1-T01, C2-T02] | The store and the projection each gain one delegating clause. |
| Native question capture | Harness adapter (MP-R7) → **NEW** `Aiur.Commands.NativeCapture` [C4-T01] | The adapter normalizes; aiur core decides. |
| Delivery to the requester | `Aiur.DecisionDispatch` (worker) and **NEW** `Aiur.Commands.ExecutorDelivery` [C6-T02] | |
| Notifications | MP-N4/N5. They subscribe to §8 events. | This contract decides *whether* a Command needs the human. N5 decides *how* to notify. |
| Presentation | DESIGN-E2 §4 | Shared by dashboard, deck, phone and watch. |

## 2. Identity

| Field | Status | Meaning |
| --- | --- | --- |
| `decision_id` | existing | 16 hex chars, sha256 of `"<ticket>::<source_id>"` (`src/lib/aiur/decision_validation.ex:466-479`). Stable across restarts. The deep-link key (`/commands/:decision_id`, `router.ex:143`). |
| `version` | existing | Optimistic-concurrency counter. Every write carries `expected_version`. |
| `ticket` | existing, **required on the wire** | The worker ticket. An Executor-originated Command carries the **reserved identifier `"executor"`** (title and url `nil`) [C1-T01]. A `nil` ticket is rejected: an older binary requires the map on replay (`decision_projection.ex:48`) and would latch read-only. Clients use `requester.kind`, never the identifier, to tell the two apart. A worker request with ticket `"executor"` is rejected. |
| `source` | existing | `%{agent_id, session_id, event_id}`, set from trusted options only (`agent_runner/tool_executor.ex:845-851`). `agent_id` is the backend label, **not** a unique agent. `session_id` is the thread id. |
| `requester` | **NEW** [C1-T01] | `%{kind: :worker \| :executor, ticket?, session_ref?, executor_id?, harness?}`. `session_ref` is MP-CT-identity's `"<instance_id>/<ticket>/<generation>"`. For `:executor`, `executor_id` is `Aiur.Executor.Claims.resolve_consumer_id/1` (`executor/claims.ex:185-195`). Default when absent: `:worker`. |
| `origin` | **NEW** [C1-T01] | `:emit_event` \| `:attention` \| `:native_question` \| `:executor_cli` \| `:supervisor_api`. Default when absent: `:emit_event` (or `:attention` when `legacy_attention` is set). |
| `native` | **NEW**, only when `origin == :native_question` [C4-T01] | `%{harness: :codex \| :claude, native_ref, call_id, turn_id, question_ids: [..], hold: :in_band \| :deferred \| :released}`. `native_ref` is opaque, issued by the adapter (§10). |

**Instance and machine scope:** a Command belongs to exactly one aiur instance (one repo and
one Executor). Remote clients address it as `{machine_id, instance_id, decision_id}` under
MP-CT-identity. aiur never merges Commands across instances (brief §3: no combined inbox).

## 3. Request content

Existing (`decision.ex:7-49`, validated in `decision_validation.ex`): `kind`, `authority`,
`urgency`, `blocking` (required boolean), `reversibility`, `question` (≤2000 chars),
`context{short_summary, long_context_markdown}`, `options[{id, label, description,
benefits, drawbacks, risk}]` (≤20, ids unique), `recommendation{option_id, reason}`,
`consequence_of_delay`, `artifacts`.

**NEW, payload version 2** [C1-T01, C1-T02]. Persisted by a separate
`request_attributed` lifecycle event written immediately after `requested`; the
`requested` snapshot and its `content_hash` are byte-identical to v1 (§11).

- `questions[]`, used when one native call carries several questions:
  `[{question_id, header (≤12), question, options[{id,label,description}], multi_select,
  allow_other}]`, 1–4 questions, 2–4 options each. A v2 Command with `questions[]` still
  fills the top-level `question` (the first question, or a joined summary) and
  `options` (the first question's options), so v1 readers keep working.
- **Suggested responses rule:**
  - An agent-authored `decision.requested` should carry **2–3 options**, with the
    recommended option first.
  - Rollout: validation **warns** (one alert, request accepted). It becomes a rejection
    only behind `decisions.require_suggested_responses` (default `false`; MP-E2-C8-T03
    flips it after a census).
  - A native question passes its options through unchanged (2–3 Codex, 2–4 Claude, §10).
  - A free-text answer (`custom_response`) is always allowed.
- `short_label`: a 2–3 word summary for notification titles (N6). Derived as
  `context.short_summary` (first 40 chars) → native `header` → `kind` → `"Command"`.
  Never the full question.
- **Secret questions are not Commands.** A native question marked `isSecret` is released
  (§7.3) with "aiur cannot collect secrets through Commands", and a needs-attention alert
  with no question or answer text is raised [C4-T01].

## 4. Routing (D9, D12)

**NEW** projected fields [C2-T02]: `route_policy`, `route_state`, `routed_at`,
`human_visible_at`, `escalations[]`, `executor_acknowledged_at`.

| Requester / authority | Live Executor? | `route_policy` | Initial `route_state` | Cause recorded |
| --- | --- | --- | --- | --- |
| worker, `supervisor_*`, Executor may answer | yes | `executor_first` | `with_executor` | — |
| worker, `supervisor_*`, Executor may **not** answer (not reversible) | yes | `human_only` | `with_human` | `executor_not_answerable` |
| worker, `human_required` | yes | `simultaneous` | `with_both` | `authority_human_required` |
| worker, any authority | **no** | `human_only` | `with_human` | `executor_offline` or `executor_stalled` |
| executor (D12) | n/a | `human_only` | `with_human` | `executor_originated` |

- **Live Executor:** at least one roster entry in `:active` or `:idle`
  (`Aiur.Executor.Roster.build(record?: false)`, `executor/roster.ex:52-69,110-123`).
  `:stalled`, `:expired` and `:unknown` count as **not live**.
- **The Executor is always made aware of worker Commands**, including `with_human` ones,
  through the existing `executor.decision.requested` journal event
  (`executor_events.ex:59-60`).
- `route_state`: `with_executor` | `with_both` | `with_human` | `closed`.
  `human_visible_at` is set the first time `route_state` becomes `with_both` or
  `with_human`, and never cleared.
- The existing human `defer` (`decision_store.ex:222,1820-1831`, UI "Defer to Executor")
  moves a `supervisor_*` Command back to `with_executor` and re-arms its deadlines from the
  defer time. It is **refused** for `human_required` and Executor-originated Commands
  [C2-T03]. `human_visible_at` stays set.

**Authority is unchanged.** Routing decides who is *asked*. It never widens who *may
answer*. The Executor may still answer only delegable, reversible Commands
(`decision_store.ex:1503-1526`; `decision_authority.ex`). The Executor may not answer a
Command it raised itself [C6-T01].

## 5. Escalation and the no-vanish invariant

**Invariant N1:** every Command that is not terminal (`expired`, `dismissed`, `moot`,
`resolved`, or answered and delivered) is either `with_human`/`with_both`, or has an armed
escalation deadline that moves it there. No Command can sit `with_executor` without a
deadline.

Escalation causes (closed list; each records `escalations[] {cause, at, detail}`):

| Cause | Trigger |
| --- | --- |
| `executor_escalated` | The Executor ran `aiur executor-escalate` (existing, `decision_store.ex:766-831`). |
| `executor_ack_timeout` | No Executor acknowledgement within `decisions.escalation.executor_ack_ms` (proposed 300 000) of `routed_at`. |
| `executor_answer_timeout` | No Executor answer or escalation within `decisions.escalation.executor_answer_ms` (proposed 900 000) of `routed_at`. |
| `executor_offline` | No non-expired roster entry. |
| `executor_stalled` | Roster entries exist, none live. |
| `executor_not_answerable` | Routed to the human at once because the Executor may not answer by policy. |
| `authority_human_required` | `simultaneous` route at creation. |
| `executor_originated` | Executor-originated Command at creation. |

- `blocking: true` with `urgency: high | critical` multiplies both timeouts by
  `decisions.escalation.urgent_factor` (proposed 0.5). This is a modifier, not a cause.
- **Executor acknowledgement** [C2-T04] is positive evidence only: an explicit
  `aiur executor-ack <decision-id>`, or any Executor answer, escalation, moot or supersede
  of that Command. Reading the Command (`aiur commands <id>`) and `executor-wait` delivery
  are **not** acknowledgements. Acknowledging only stops the ack timer.
- **Restart:** deadlines derive from durable `routed_at` plus config, never from in-memory
  timers. At boot `Aiur.Commands.Routing` recomputes every open Command. An overdue one
  escalates at once, once. Escalation is idempotent per `{decision_id, version, cause}`.
- **Re-ask:** structured Commands get one Executor event only. MP-E2 adds **no** re-ask;
  escalation to the human replaces it. The legacy `attention.*` re-ask
  (`decision_attention.ex:17,216-227`) is unbounded today; live bug **#2819** is that
  variant, and its fix is in flight in that file. MP-E2 does not edit it.
- **Expiry wins:** `decision_expiry.ex` still expires open Commands of an inactive ticket.
  Routing ignores terminal Commands, so a Command may get `human_needed` and then
  `expired`; clients clear on the terminal slug.
- **Owner-tunable:** the timeout defaults are DESIGN-E2 §6.1.

## 6. Answers and resolution (D11)

Answer request (existing shape, `decision_answer.ex`; extended):

```json
{ "decision_id": "…", "expected_version": 4, "idempotency_key": "client-generated",
  "selected_option_id": "opt-a",            // or
  "custom_response": "…",                   // or, for v2 multi-question:
  "question_answers": {"q1": ["opt-a"], "q2": ["custom text"]},
  "actor": {"kind": "operator", "id": "dashboard" },
  "client": {"surface": "dashboard|streamdeck|cli|api|phone|watch", "device_id": "…"} }
```

Rules:

1. **First recorded answer wins.** A second answer with a different `idempotency_key` gets
   `{:conflict, {:already_decided, action_id}}` (`decision_store.ex:1557`); the tuple is
   **not changed**. Surfaces call **NEW** `Aiur.Commands.ConflictSummary.for/1` [C3-T01] to
   show "already answered by …": `{actor_kind, actor_id, summary, accepted_at,
   delivery_status}`.
2. **Same key, same content** returns `:duplicate`. Same key with different content returns
   `{:conflict, {:idempotency_conflict, _}}`.
3. **Human supersede (D11).** A human actor (`operator`, or `operator_relayed` once #3005
   merges) may replace an undelivered, not-in-flight answer through **NEW**
   `Aiur.Commands.Answering.supersede/3` [C3-T02], which calls the existing
   `DecisionStore.supersede/5` (`decision_store.ex:287,1206-1250`, guard `:1965-1971`).
   Refusals: `{:conflict, :answer_delivered}`, `{:conflict, :answer_in_flight}`. MP-E2 adds
   no supervisor supersede route (the supervisor is not a human actor).
4. **The Executor never supersedes a human answer.** **NEW** store guard [C3-T01]:
   `{:conflict, {:human_answer, action_id}}`.
5. **Human vs. human** (two devices): first wins; the loser sees rule 1 and may supersede.
6. **Answerable statuses** are unchanged: only `expired`, `moot` and `resolved` refuse
   answers (`decision_store.ex:1440-1443`).
7. **`revise`** stays a correction path with no undelivered guard. Clients label it
   "Send correction", not "Replace".

## 7. Delivery

### 7.1 Worker requester

- **In-band (NEW)** [C4-T03]: when `native.hold == :in_band`, `DecisionDispatch` adds
  `native_ref` and `question_answers` to the correlated operator message. The runner that
  holds that `native_ref` answers the native request instead of starting a turn, and
  acknowledges the queue item through the existing path, so `delivered` evidence is the
  same as for a message. If no runner holds it, the item is an ordinary message.
- **Message (existing):** `Aiur.DecisionDispatch` sends a correlated operator message to the
  ticket (`decision_dispatch.ex:65`), capped at 7 800 chars (`:22`), resumes a self-paused
  worker (#2738), and is redelivered to a new worker (`deliver_pending_answers`, #2713).

### 7.2 Executor requester (D12) [C6-T02]

- Worker dispatch is skipped. The answer's lifecycle topic is `executor.decision.answered`
  (§8), appended to the durable Executor journal.
- `ExecutorListener` and `ExecutorWakeProjection` allowlist exactly that topic, so
  `aiur executor-wait` returns it with its `decision_id` (today both ignore `executor.*`:
  `executor_listener.ex:183-193`, `executor_wake_projection.ex:12`).
- After the wake record is enqueued, `requester_notified` is recorded and
  `Decision.delivered?/1` treats it as delivered.
- When MP-E3 provides an Executor input channel, the same answer is also injected into the
  Executor session.

### 7.3 Release (native request cannot be held)

If the native request must be answered before a human answers (the receive-loop idle
timeout `agent.turn_timeout_ms`, pause, interrupt, adapter shutdown), the adapter answers
it with the release text "Your question is recorded as Command <id>. Stop and end your
turn; the answer will arrive as a message." The Command stays open and `native.hold`
becomes `:released` (`native_released` event). If the process is already gone, only the
event is recorded. **A release never closes the Command** (invariant N1).

## 8. Events

Lifecycle topics come from **NEW** `Aiur.Commands.Topics.lifecycle/2` [C1-T03]:
`ticket.<id>.agent.decision.<slug>` for a worker requester, and `executor.decision.<slug>`
(through `ExecutorEvents.publish/3`) for an Executor requester. Existing slugs are
unchanged (`decision_store.ex:2633-2653`).

| Event (type → slug) | Persisted | Consumers |
| --- | --- | --- |
| `request_attributed` → `request-attributed` | yes | read API |
| `routed` → `routed` | yes | dashboard, Executor |
| `escalated` → `escalated` | yes | dashboard timeline |
| `human_needed` → `human-needed` | yes, once per Command | **N4/N5 notifications**, N3 counts |
| `executor_acknowledged` → `executor-acknowledged` | yes | dashboard timeline |
| `native_released` → `native-released` | yes | dashboard, E4 anchors |
| `requester_notified` → `requester-notified` | yes (Executor requester) | dashboard |
| `revision_recorded` (existing) | yes | supersede display, N4 retraction |
| `answer_recorded` → `answered` (existing slug) | yes | Executor wake (`executor.decision.answered` for Executor requesters) |

- `human_needed` carries `{decision_id, version, short_label, requester_kind, blocking,
  urgency, cause}` and **no question text**. It is registered in MP-R2-C5's catalog
  (RC-08) as journaled and exported.
- Every terminal transition emits the existing slug. Clients use it to clear notifications.
- Replay: Command state is replayable from the store (`GET /api/v1/decisions`,
  `aiur commands --json`). Clients reconcile by `{decision_id, version}`.

## 9. Client surfaces (read and answer)

| Surface | Read | Answer | Actor |
| --- | --- | --- | --- |
| Dashboard `/commands[/:id]` | LiveView and PubSub | via `Aiur.Commands.Answering` [C3-T02] | `%{kind: :operator, id: <dashboard user>}` (`decision_commands.ex:82-83`) |
| Stream Deck | `streamdeck:fleet` | `answer_command` (`streamdeck_channel.ex:567-573`) | `%{kind: :operator, id: "streamdeck"}` |
| CLI | `aiur commands [id] --json` | `aiur executor-answer/-escalate/-moot/-ack`, `aiur command request` | `:executor` |
| Supervisor API | `GET /api/v1/decisions[/:id]` | `POST …/decide\|revise\|enrich` (`router.ex:82-87`) | `%{kind: :supervisor}` |
| Phone and watch (N6/N7) | via N2 pairing auth | same answer shape through `Aiur.Commands.Answering`, `client.surface` set | `:operator` with `device_id` |

All surfaces map conflicts the same way: HTTP 409 `decision_conflict`
(`decision_api_controller.ex:114-127`) plus the §6.1 summary.

## 10. What MP-E2 needs from the harness-adapter contract (MP-R7)

1. **Capability** `native_question: :in_band_hold | :defer_resume | :none` per harness and
   session; `:none` is reported, not assumed. **Meaning:** `:defer_resume` is Claude's
   defer-and-resume (the session persists with the pending tool and is resumed with the
   answer). It does **not** mean "answer at once and deliver later" — that is a release
   (§7.3). (Reconcile request to MP-R7: harness-adapter §6 item 5.)
2. **Classification at the adapter boundary (D10):** approval-shaped requests stay with the
   existing policy (`user_input_answers.ex:60-92`). Only a genuine question becomes
   `{:native_question, …}`. The classification is exposed for tests.
3. **Normalized event** `{:native_question, %{native_ref, call_id, turn_id, questions:
   [%{question_id, header, question, options, multi_select, allow_other, secret}]}}`.
   Claude keys answers by question text, so the adapter issues stable `question_id`s.
4. **`reply_native_question(session, native_ref, %{question_id => [answer]})`** →
   `:ok | {:error, :not_pending | :session_gone}`.
5. **`release_native_question(session, native_ref, text)`** → same returns.
6. **Hold-state signal:** while held, the running entry carries `:native_hold`, and the
   stall and max-duration watchdogs skip it until release.
7. `claude-repl` (Remote Control transport) reports `:none` in MP-E2 (RQ-E2-1).

## 11. Versioning and compatibility

- New fields are additive and travel only in new event types. **Rollback is safe for new
  event types:** an older binary decodes an unknown named `event_type` to
  `Aiur.DecisionEvent.Unrecognized`, retains it, and skips it
  (`decision_event.ex:167-193`, `decision_projection.ex:158`; existing tests
  `decision_projection_test.exs:937-967`, `decision_store_test.exs:4440-4474`).
- **Not safe, and therefore not done:** adding fields to the `requested` snapshot (the
  replayed content hash would not match, `decision_projection.ex:47-86`) or writing a
  `nil` ticket (`:48`). Either latches the store read-only (`decision_store.ex:13-17`).
- After a rollback, an older binary shows Executor-originated Commands as ticket
  `executor` and may expire them after 300 s (`decision_expiry.ex:112-117`). Release note.
- `aiur ask` (`Aiur.Asks`) becomes an alias that writes an Executor Command [C6-T03];
  existing `ask_` records stay readable history.
