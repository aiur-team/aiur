---
contract_id: MP-CT-command-request-and-resolution
owner_feature: MP-E2
status: draft (Phase B) — reconcile in Phase D
base_main_sha: 45a290e3
date: 2026-10-06
consumers: MP-E3, MP-E4, MP-E5, MP-E6, MP-E7, MP-N3, MP-N4, MP-N5, MP-N6, MP-N7, MP-R6 (Stream Deck)
consumes: MP-CT-identity, MP-CT-events-and-replay (MP-R2), MP-CT-harness-adapter (MP-R7), MP-CT-capabilities
---

# Contract: Command request and resolution

A **Command** is aiur's durable request for input from the Executor or the human. In the
code it is `Aiur.Decision`, and this contract keeps that model. It **extends** the model
and does not replace it: every field and transition named here as *existing* is on `main`
at `45a290e3`. Fields marked **NEW** are proposals that MP-E2 implements.

Settled decisions this contract encodes: D9 (routing by authority), D10 (only native
ask-the-user tools), D11 (first answer wins, human supersede until delivery), D12
(Executor-originated Commands). See `../context-and-decisions.md`.

## 1. Ownership

| Concern | Owner | Notes |
| --- | --- | --- |
| Command record, lifecycle, persistence | `Aiur.DecisionStore` (single writer) | `decisions.ndjson` is authoritative, `decisions.json` is a projection (KTD10). |
| Routing and escalation (who must act, and when the human is pulled in) | **NEW** `Aiur.Commands.Routing` (MP-E2-C2) | A separate module. `decision_store.ex` is already 4,826 lines, so it must not grow (KTD1). |
| Native question capture | Harness adapter (MP-R7) → **NEW** `Aiur.Commands.NativeCapture` (MP-E2-C4) | The adapter normalizes; aiur core decides. |
| Delivery to the requester | `Aiur.DecisionDispatch` (worker) and **NEW** an Executor delivery target (MP-E2-C6) | |
| Notifications | MP-N4/N5. They subscribe to §8 events. | This contract decides *whether* a Command needs the human. N5 decides *how* to notify. |
| Presentation | DESIGN-E2 §4 | Shared by dashboard, deck, phone and watch. |

## 2. Identity

| Field | Status | Meaning |
| --- | --- | --- |
| `decision_id` | existing | 16 hex chars, sha256 of `"<ticket>::<source_id>"` (`src/lib/aiur/decision.ex:471-479`). Stable across restarts. It is the deep-link key (`/commands/:decision_id`, `router.ex:143`). |
| `version` | existing | Optimistic-concurrency counter. Every write carries `expected_version`. |
| `ticket` | existing; **NEW** nullable | The worker ticket. **NEW:** `nil` for an Executor-originated Command with no ticket (it then carries `scope: :repo`). This is a change: `ticket` is in `@enforce_keys` (`decision.ex:152-167`). |
| `source` | existing | `%{agent_id, session_id, event_id}`, set from trusted options only (`tool_executor.ex:845-851`). `agent_id` is the backend label, **not** a unique agent. `session_id` is the thread id. |
| `requester` | **NEW** | `%{kind: :worker \| :executor, ticket?, session_ref?, executor_id?, harness?}`. `session_ref` follows MP-CT-identity's worker/session identity. For `:executor`, `executor_id` is the claim consumer id (`Aiur.Executor.Claims.resolve_consumer_id/1`). |
| `origin` | **NEW** | How the Command was raised: `:emit_event` (agent `decision.requested`), `:attention` (legacy `attention.*`), `:native_question` (D10), `:executor_cli` (D12), `:supervisor_api`. |
| `native` | **NEW**, only when `origin == :native_question` | `%{harness: :codex \| :claude, native_ref, call_id, turn_id, question_ids: [..], hold: :in_band \| :deferred \| :released}`. `native_ref` is opaque, issued by the adapter (§10). |

**Instance and machine scope:** a Command belongs to exactly one aiur instance (one repo and
one Executor). Remote clients address it as `{machine_id, instance_id, decision_id}` under
MP-CT-identity. aiur never merges Commands across instances (brief §3: no combined inbox).

## 3. Request content

Existing (`decision.ex:7-49`, validated in `decision_validation.ex`): `kind`, `authority`,
`urgency`, `blocking` (required boolean), `reversibility`, `question` (≤2000 chars),
`context{short_summary, long_context_markdown}`, `options[{id, label, description,
benefits, drawbacks, risk}]` (≤20 today, ids unique), `recommendation{option_id, reason}`,
`consequence_of_delay`, `artifacts`.

**NEW, payload version 2:**

- `questions[]`, used when one native call carries several questions:
  `[{question_id, header (≤12), question, options[{id,label,description}], multi_select,
  allow_other}]`. A v2 Command with `questions[]` still fills the top-level `question` (the
  first question, or a joined summary) and `context.short_summary` (from the first
  `header`), so v1 readers keep working.
- **Suggested responses rule:**
  - An agent-authored `decision.requested` must carry **2–3 options**, with the
    recommended option first.
  - Rollout: v2 validation first **warns** (logs an alert and accepts). The rule becomes a
    rejection only behind `commands.require_suggested_responses` (default `false` until
    MP-E2-C8 flips it).
  - A native question passes its options through unchanged. That is 2–3 for Codex and
    2–4 for Claude (§10).
  - A free-text answer (`custom_response`) is always allowed.
- `short_label`: a 2–3 word summary for notification titles (N6). Derived as
  `context.short_summary` → native `header` → `kind`. Never the full question.
- **Secret questions are not Commands.** If a native question is marked `isSecret`
  (Codex), aiur does not store its answer in a durable file it cannot redact. MP-E2
  releases it (§7.3) with "aiur cannot collect secrets through Commands" and raises a
  needs-attention alert that carries no answer content.

## 4. Routing (D9, D12)

**NEW** fields: `route_policy`, `route_state`, `routed_at`, `human_visible_at`,
`escalations[]`.

| Requester / authority | Live Executor? | `route_policy` | Initial `route_state` |
| --- | --- | --- | --- |
| worker, `supervisor_allowed` or `supervisor_preferred` | yes | `executor_first` | `with_executor` |
| worker, `human_required` | yes | `simultaneous` | `with_both` |
| worker, any authority | **no** | `human_only` | `with_human` |
| executor (D12) | n/a | `human_only` | `with_human` |

- **Live Executor:** at least one roster entry in `:active` or `:idle`
  (`Aiur.Executor.Roster`, `src/lib/aiur/executor/roster.ex:118-122`). `:stalled`
  (no consumption for `executor_stall_after_ms`, default 300 000 ms, `roster.ex:39`) and
  `:expired` count as **not live**.
- **The Executor is always made aware of worker Commands**, including `with_human` ones.
  This uses the existing `executor.decision.requested` journal event
  (`executor_events.ex:57-60`).
- `route_state` values: `with_executor` | `with_both` | `with_human` | `closed`.
  `human_visible_at` is set the first time `route_state` becomes `with_both` or
  `with_human`, and never cleared.
- The existing human `defer` (`decision_store.ex:221`, UI "Defer to Executor") moves a
  `supervisor_*` Command back to `with_executor`. It is refused for `human_required` and
  Executor-originated Commands.

**Authority is unchanged.** Routing decides who is *asked*. It never widens who *may
answer*. The Executor may still answer only delegable, reversible Commands
(`decision_store.ex:1513-1524`; `decision_authority.ex:11-12`).

## 5. Escalation and the no-vanish invariant

**Invariant N1:** every Command that is not terminal (`expired`, `dismissed`, `moot`,
`resolved`, or answered and delivered) is either `with_human`/`with_both`, or has an armed
escalation deadline that moves it there. No Command can sit `with_executor` without a
deadline.

Escalation to the human happens on the first of these. Each one records an
`escalations[]` entry `{cause, at, detail}`:

| Cause | Trigger |
| --- | --- |
| `executor_escalated` | The Executor ran `aiur executor-escalate` (existing, `decision_store.ex:766-831`). |
| `executor_ack_timeout` | No Executor acknowledgement within `commands.escalation.executor_ack_ms` (proposed default 300 000) of `routed_at`. |
| `executor_answer_timeout` | No Executor answer or escalation within `commands.escalation.executor_answer_ms` (proposed default 900 000). |
| `executor_offline` | The roster has no live Executor (on the roster's own observation, not a guess). |
| `executor_not_answerable` | The Executor cannot answer by policy, e.g. the Command is not reversible. Escalates immediately at routing. |
| `urgent_blocking` | `blocking: true` and `urgency: high` halve both timeouts. |

- **Executor acknowledgement** (NEW, cheap): the Executor reading the Command through
  `aiur commands <id>`, `executor-wait` delivery of its wake, or an explicit
  `aiur executor-ack <id>`. Phase C must pick the minimum set. Acknowledging only stops
  the ack timer; the answer timer still runs.
- **Restart:** deadlines are derived from durable `routed_at` plus config, never from
  in-memory timers alone. On boot, `Aiur.Commands.Routing` recomputes every open Command's
  deadline. An overdue one escalates at once, once. Escalation is idempotent per
  `{decision_id, version, cause}`, in the same pattern as `ExecutorCommandAttention.open/4`
  (`executor_command_attention.ex:133-136`).
- **Re-ask:** today only legacy `attention.*` re-asks, every 15 min and unbounded
  (`decision_attention.ex:17,217-226`). Structured Commands get one Executor event only.
  MP-E2 does **not** add an Executor re-ask. Escalation to the human replaces it.
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

1. **First recorded answer wins.** The GenServer serializes writes. A second answer with a
   different `idempotency_key` gets `{:conflict, {:already_decided, action_id}}`
   (`decision_store.ex:1539-1559`). **NEW:** the conflict response includes the winning
   answer summary, actor kind, `accepted_at` and `delivery_status`, so a client can show
   "already answered by …".
2. **Same key, same content** returns `:duplicate` (a safe retry from any device). Same key
   with different content returns `{:conflict, {:idempotency_conflict, _}}`.
3. **Human supersede (D11).** A human actor (`operator`, or `operator_relayed` from #3005)
   may replace an **Executor** answer while it is not delivered and not in flight. The
   store already supports this through `supersede` (`decision_store.ex:285,1206-1250`)
   with the `require_withdrawable` guard (`:1965-1971`). MP-E2 adds the dashboard and API
   path, which today exists only for the Executor CLI. After delivery it returns
   `{:conflict, :answer_delivered}`. While in flight it returns
   `{:conflict, :answer_in_flight}`.
4. **The Executor never supersedes a human answer.** **NEW** guard: supersede with actor
   kind `:executor` is refused when the active answer's actor kind is human. Today the
   store does not restrict the actor (Phase A finding).
5. **Human vs. human** (two devices): first wins. The loser sees the conflict from rule 1
   and may supersede (rule 3 applies to any undelivered answer when the actor is human).
6. **Answerable statuses.** Today `dismissed` and `deferred` Commands still accept answers;
   only `expired`, `moot` and `resolved` refuse them (`decision_store.ex:1440-1443`). This
   contract keeps that.
7. **`revise`** (`/api/v1/decisions/:id/revise`) has no undelivered guard today. It remains
   a correction path that sends a follow-up revision message. It is **not** D11 supersede.
   Clients must label it "Send correction", not "Replace".

Terminal states and what a client shows are in DESIGN-E2 §4.4.

## 7. Delivery

### 7.1 Worker requester

- **In-band (NEW):** if `native.hold == :in_band` and the adapter still holds the native
  request, the answer goes back as the native tool result (§10 `reply_native_question`).
  The answer is then `delivered` when the adapter acknowledges the reply.
- **Message (existing):** otherwise `Aiur.DecisionDispatch` sends a correlated operator
  message to the **ticket** (`decision_dispatch.ex:65`). It is capped at 7 800 chars
  (`:22`), resumes a self-paused worker (#2738; `operator_messages.ex:726-743`), and is
  redelivered to a newly spawned worker (`deliver_pending_answers`, #2713).

### 7.2 Executor requester (D12)

- The answer is appended to the Executor journal as `executor.decision.answered` (NEW
  topic under the existing durable `executor.*` journal, `executor_events.ex`). It is
  returned by `aiur executor-wait`, so it survives Executor restarts.
- When MP-E3 provides an Executor input channel, the same answer is also injected into the
  Executor session. Until then, journal plus wake is the delivery, and `delivery_status`
  becomes `delivered` when the Executor's wake cursor passes it (`acknowledge_as/3`).

### 7.3 Release (native request cannot be held)

If the native request must be answered before a human answers (turn or stall timeout
`agent.turn_timeout_ms`/`stall_timeout_ms`, both default 3 600 000 ms, from
`config/schema/agent.ex:215-216`; adapter shutdown; daemon stop), the adapter answers it
with a **release text**. For example: "Your question is recorded as Command <id>. Stop and
end your turn; the answer will arrive as a message." The Command stays open and
`native.hold` becomes `:released`. The later answer uses §7.1 message delivery. **A
release never closes the Command** (invariant N1).

## 8. Events

Existing: `ticket.<id>.agent.decision.<slug>` (`decision_store.ex:2555,2633-2653`) and
`executor.decision.requested|deferred` (`executor_events.ex:59-60`). NEW slugs on the same
topic scheme:

| Event | Topic | Consumers |
| --- | --- | --- |
| `routed` | `ticket.<id>.agent.decision.routed` | dashboard, Executor |
| `human_needed` | `ticket.<id>.agent.decision.human-needed` (or `executor.decision.human-needed` with no ticket) | **N4/N5 notifications**, meta-dashboard counts (N3) |
| `native_released` | `ticket.<id>.agent.decision.native-released` | dashboard, transcript anchors (E4) |
| `superseded` | existing revision events plus `actor_kind` | dashboard, notification retraction (N4) |
| `answered` | `executor.decision.answered` (Executor requester only) | Executor wake |

- `human_needed` is emitted **once per Command** when `human_visible_at` is first set. It
  carries `{decision_id, version, short_label, requester, blocking, urgency, cause}` and
  **no question text**, so the push relay can carry only identifiers and fetch content
  after authentication (MP-N4 decides encryption).
- Every terminal transition emits the existing slug (answered, mooted, …). Clients use it to
  clear notifications and stale views.
- Replay: Command state is replayable from the store (`GET /api/v1/decisions`, `aiur
  commands --json`). Clients reconcile by `{decision_id, version}` rather than relying on
  bus replay. System topics are not replayable today (baseline R2 gap 2).

## 9. Client surfaces (read and answer)

| Surface | Read | Answer | Actor |
| --- | --- | --- | --- |
| Dashboard `/commands[/:id]` | LiveView and PubSub | `answer-decision` and the others (`decision_events.ex`) | `%{kind: :operator, id: <dashboard user>}` (`decision_commands.ex:82-83`) |
| Stream Deck | `streamdeck:fleet` | `answer_command` (`streamdeck_channel.ex:152,567-573`) | `%{kind: :operator, id: "streamdeck"}` |
| CLI | `aiur commands [id] --json` | `aiur executor-answer/-escalate/-moot` | `:executor` |
| Supervisor API | `GET /api/v1/decisions[/:id]` | `POST …/decide|revise|enrich` (`router.ex:84-95`) | `%{kind: :supervisor}` (`supervisor_auth.ex:18`) |
| Phone and watch (N6/N7) | via N2 pairing auth | same answer shape, `client.surface` set | `:operator` with `device_id` (N2 owns the credential) |

All surfaces map conflicts the same way: HTTP 409 `decision_conflict`
(`decision_api_controller.ex:114-127`), extended with the winning-answer summary (§6.1).

## 10. What MP-E2 needs from the harness-adapter contract (MP-R7)

Assumptions to reconcile with the MP-R7 owner:

1. **Capability** `native_question: :in_band_hold | :defer_resume | :none` per harness and
   session. `:none` must be reported, not silently assumed (brief §7).
2. **Classification at the adapter boundary (D10):** an approval-shaped request stays with
   the existing policy (`Aiur.Codex.Approvals`, `UserInputAnswers.approval_answers/1`
   picks "Approve…" or "Allow…" labels, `user_input_answers.ex:60-92`). Only a genuine
   ask-the-user question becomes a `{:native_question, …}` event. The adapter exposes the
   classification result so it can be tested.
3. **Normalized event** `{:native_question, %{native_ref, call_id, turn_id, questions:
   [%{question_id, header, question, options, multi_select, allow_other, secret}]}}`.
   Codex keys answers by question `id`. Claude keys them by question **text**, so the
   adapter must provide stable `question_id`s and map them back.
4. **`reply_native_question(session, native_ref, %{question_id => [answer]})`** returns
   `:ok | {:error, :not_pending | :session_gone}`.
5. **`release_native_question(session, native_ref, text)`** with the same returns.
6. **Hold-state signal:** while a native question is held, the turn is "waiting on
   Command", and the stall detector must not count it as a stall (until §7.3 release).

## 11. Versioning and compatibility

- New fields are additive. Decision events carry a `payload_version`, and v2 events are
  only written after MP-E2-C1 lands.
- **Rollback hazard:** an older binary replaying `decisions.ndjson` with unknown v2 event
  types must not corrupt the projection. Today an unknown or invalid replay makes the store
  read-only (`decision_store.ex:15-17`). MP-E2-C1 must prove the old reducer ignores the new
  event types, or ship a release note that rollback needs a log snapshot.
- `aiur ask` (`Aiur.Asks`, a separate JSONL store with no UI) is migrated to Executor
  Commands (MP-E2-C6). `aiur ask` stays as an alias that writes a Command, and existing
  `ask_` records are read-only history.
