---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E2
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: DESIGN-E2
owned_contracts: [contracts/command-request-and-resolution.md]
consumed_contracts: [identity, capabilities, events-and-replay (MP-R2), harness-adapter (MP-R7), notification destination and payload (MP-N4)]
---

# MP-E2 — Native command capture, Executor awareness and human escalation

Decomposition and tickets: [chunks.md](chunks.md). Contract:
[../../contracts/command-request-and-resolution.md](../../contracts/command-request-and-resolution.md).
Owner gate: [../../owner-design-tasks/DESIGN-E2.md](../../owner-design-tasks/DESIGN-E2.md).

## Goal capsule

- **Outcome:** every request for human or Executor input reaches the responder its
  authority names, and never disappears because the Executor did not act. Native
  ask-the-user questions from Claude and Codex become Commands. The Executor can raise
  Commands too.
- **Settled:** D9 (route by authority), D10 (native ask-the-user tools only), D11 (first
  answer wins; a human supersedes an Executor answer until delivery), D12
  (Executor-originated Commands go straight to the human).
- **Readiness:** `planned-with-blockers`. The blockers are DESIGN-E2 approval; Phase C
  spikes on native capture for both harnesses (R-Q1, R-Q2); the MP-R7 adapter contract
  shape; and the escalation timeout defaults (owner).

## 0. Phase C update (2026-10-06)

Tickets: [tickets/README.md](tickets/README.md) (36: spikes C4-T00 and C5-T00 `ready`,
34 implementation tickets `blocked` on DESIGN-E2 plus named predecessors). The contract
was revised (its "Phase C changes" paragraph). Decisions made with evidence in Phase C:

- **R-Q4 answered.** An older binary decodes an unknown named event type to
  `Aiur.DecisionEvent.Unrecognized` and skips it (`decision_event.ex:167-193`,
  `decision_projection.ex:158`), but it re-validates `requested` snapshots and recomputes
  their hash (`decision_projection.ex:47-86`) and requires a `ticket` map (`:48`). So v2
  attributes travel in a new `request_attributed` event, and Executor Commands keep the
  reserved ticket `"executor"` instead of `nil` (C1-T01). This replaces "make `ticket`
  nullable" below.
- **R-Q3 answered.** Executor acknowledgement = `aiur executor-ack` + Executor
  answer/escalate/moot/supersede (C2-T04); reads and wake delivery do not count.
- **Config namespace** is the existing `decisions.*` section (`config/schema.ex:57`), not
  `commands.*` (C2-T05).
- **In-band delivery** reuses the correlated operator-message queue; the runner that holds
  the request answers it (C4-T03). The store dispatcher contract is unchanged.
- **Executor delivery:** today `executor.*` events never reach the wake inbox
  (`executor_listener.ex:183-193`, `executor_wake_projection.ex:12`), so C6-T02 allowlists
  `executor.decision.answered` there.
- **No supervisor supersede route** (C3-T02): D11 grants supersede to humans; the device
  route is MP-N6's, on `Aiur.Commands.Answering`.
- **Citation fix:** `decision_id` derivation is `decision_validation.ex:466-479`, not
  `decision.ex` (280 lines).
- **RC-08** applied in C2-T02; **RC-18** in C2-T03 (#2819, no edit to
  `decision_attention.ex`).
- **New:** RQ-E2-1 (`claude-repl` native capture, deferred to MP-E3/MP-E7). Contract
  requests: [tickets/CONTRACT-REQUESTS.md](tickets/CONTRACT-REQUESTS.md).

## 1. Repository findings (extend the baseline, `45a290e3`)

The baseline (`../../baseline/capability-baseline-bucket-2.md` § E2) is correct in outline. These
findings add to it or correct it. Paths are under `src/lib/aiur/` unless they say
otherwise.

### 1.1 Model and store

- **Transitions live in `decision_projection.ex`**, not in `decision.ex`.
  - `answer_recorded` requires the current version and no prior answer, but not `:open`
    (`:275-288`).
  - `executor_escalated` changes no status (`:315-318`).
  - `revision_recorded` has no delivered check (`:354-377`).
  - A dismissed Command reopens on a re-file with a different `content_hash` (`:191-198`).
- **Option limits** (`decision_validation.ex:40-54,265-268`): at most 20 options and no
  minimum. `blocking` is required (`:98`). The default authority is `supervisor_allowed`
  and reversible (`:56-58`). There is no 2–3 rule today.
- **`source.agent_id` is the backend label, not a unique agent.** `session_id` is the
  thread id (`agent_runner/tool_executor.ex:845-851`). The answer is addressed to the
  ticket (`decision_dispatch.ex:65`).
- **First answer wins, already.** A second answer with a different key gets
  `{:conflict, {:already_decided, id}}` (`decision_store.ex:1539-1559`). Writes are
  serialized by the GenServer.
- **Supersede exists in the store** (`decision_store.ex:285,1206-1250`) and is guarded
  against delivered and in-flight answers (`:1965-1971`). It has no actor restriction.
  Only the Executor CLI calls it (`executor_command_cli.ex:148-159`), and its errors name
  `answer_delivered` and `answer_in_flight` (`:253-281`). **The dashboard has no
  supersede.** The only human correction path is `/revise`, which has no undelivered guard
  (`decision_api.ex:281`).
- **Answerable statuses:** only `expired`, `moot` and `resolved` refuse answers
  (`decision_store.ex:1440-1443`). A dismissed or deferred Command can still be answered.
- **The Executor policy gate** requires delegable authority and reversible
  (`decision_store.ex:1513-1524`). Operator, agent and system actors pass with no check
  (`:1526`). `decisions.supervisor_allowed_kinds` applies to the **supervisor** actor
  only (`config.ex:1137-1144`).
- **Size:** `decision_store.ex` is **4,826 lines**, `decision_projection.ex` 1,039,
  `pause_resume.ex` 2,471, `operator_messages.ex` 1,167. All are over the 500-line gate
  (KTD1). New MP-E2 logic goes in new modules, and edits to these files must stay minimal
  and coordinated with their U8 size owner (`DECISIONS`, `LIFECYCLE_*`).

### 1.2 Executor awareness and time-based behaviour

- A structured `decision.requested` produces **one** `executor.decision.requested` journal
  event (`executor_events.ex:57-60`). It is retried only if the publish fails, and
  re-published at store boot for open or deferred Commands (`decision_store.ex:598-612`).
  **No re-ask.**
- Only legacy `attention.*` re-asks, every 15 min (`decision_attention.ex:17`), and it
  does so **unbounded**, although the moduledoc says "bounded" (`:7,217-226`).
- `decision_expiry.ex` runs every 60 s (`:21`). It expires `:open` Commands older than
  300 s whose ticket is not active (`:22,112-117`), exempting blocking `human_required`
  (`:124`). It raises "stale blocking" after 24 h (`:23,137-140`).
- **There is no Executor-to-human timeout or automatic escalation.** A Command the Executor
  ignores stays open. It is visible in the inbox, but nothing marks it as the human's
  turn. This is the "vanish" risk in the brief.
- Executor liveness exists: `Aiur.Executor.Roster` classifies
  `expired | active | stalled | idle` (`executor/roster.ex:118-122`, stall after 300 s,
  `:39`).
- Escalation exists: `escalate_executor_command` (`decision_store.ex:766-831`) opens
  `ExecutorCommandAttention`, which is idempotent per version
  (`executor_command_attention.ex:133-136`) and has no re-ask.

### 1.3 Delivery and resume

- Delivery is a correlated operator message: `:interrupt`, falling back to `:queue_next`
  (`decision_dispatch.ex:42-63`), capped at 7 800 characters (`:22`).
- **Resume on answer (#2738)** is in `orchestrator/operator_messages.ex:718-743` and
  `orchestrator/pause_resume.ex:36-40` (`input_pause_reason?`). It is **not** in
  `auto_resume.ex`, which is transient-failure backoff.
- Redelivery to a respawned worker uses `deliver_pending_answers`
  (`decision_store.ex:1154-1156,4562-4601`), called from
  `orchestrator/dispatcher.ex:2558,2594-2596`.

### 1.4 Native questions per harness (D10)

**Codex (app-server JSON-RPC).**
- `item/tool/requestUserInput` is matched at `codex/approvals.ex:148-169`.
  - With `auto_approve_requests` on, `UserInputAnswers.approval_answers/1` picks an
    "Approve this Session", "Approve Once", or any "approve…" or "allow…" label
    (`codex/user_input_answers.ex:60-92`).
  - Otherwise every question gets "This is a non-interactive session. Executor input is
    unavailable." (`:6,30-48`).
  - Only a malformed question returns `:input_required` (`approvals.ex:264-281`).
  - So today every native question is answered within milliseconds and lost.
- Upstream (openai/codex `main` @ `551bd409`, read 2026-10-06; installed `codex-cli
  0.160.0`):
  - The tool is `request_user_input`. Its args are `questions[{id, header, question,
    isOther, isSecret, options[{label, description}]}]` and `isBlocking`. The response is
    `{answers: {<question id>: {answers: [String]}}}`
    (`codex-rs/protocol/src/request_user_input.rs`).
  - Its spec asks for 1–3 questions with 2–3 options and a recommended option first, and
    the client adds "Other" (`codex-rs/core/src/tools/handlers/request_user_input_spec.rs`).
  - **It is offered only in Plan collaboration mode**, unless the feature
    `default_mode_request_user_input` is on. That feature is at stage `UnderDevelopment`
    with `default_enabled: false` (`codex-rs/tools/src/tool_config.rs:17-26`,
    `codex-rs/features/src/lib.rs`).
  - The tool is also unavailable to non-root (sub)agents.
  - aiur sets no collaboration mode or feature flag (no hits for `collaboration` or
    `features` in `src/lib/aiur/codex`), so today the model normally **cannot call it**.
  - Source: https://github.com/openai/codex (raw files at `main`).
- The handler `await`s the client's response with no timeout of its own
  (`request_user_input.rs` handler). So the request can be **held in-band** while the
  app-server process lives, bounded by aiur's own `agent.turn_timeout_ms` and
  `stall_timeout_ms` (both 3 600 000, `config/schema/agent.ex:215-216`).

**Claude (through `aiur-claude`).**
- aiur drives Claude through the external `aiur-claude` app-server
  (`claude/config.ex:8`, `coding_agent/providers/claude.ex:19-34`). It uses the same
  JSON-RPC protocol and sends `permissionMode` (default `bypassPermissions`,
  `claude/config.ex:9,33-37`) on `thread/start` (`claude/coding_agent.ex:227-236`).
- `Aiur.Claude.CodingAgent` handles `turn/completed`, `turn/failed`, `item/tool/call`
  and `rate_limit/update`. **Everything else is logged as a notification**
  (`claude/coding_agent.ex:302-399`). There is no requestUserInput handling.
- `aiur-claude` 1.1.0 (installed npm package, repository its-everdred/claude-app-server)
  spawns `claude --print --output-format stream-json … --permission-mode <mode>` for each
  turn (`dist/server.js:6,629-652`). It has **no** `--permission-prompt-tool` and no
  AskUserQuestion handling. It only forwards `permission_denials` as
  `turn/permission_denied` (`:831-837`).
- **Claude Code docs** (https://code.claude.com/docs/en/hooks, read 2026-10-06; local CLI
  2.1.291):
  - In `-p` mode, AskUserQuestion is offered **only when the run has a permission host**
    (`--permission-prompt-tool` or an SDK `canUseTool`). So aiur's Claude workers cannot
    ask native questions today.
  - A `PreToolUse` hook can answer the tool with `permissionDecision: "allow"` plus
    `updatedInput.answers` (keyed by question **text**).
  - A hook can also return `"defer"`. In that case the process exits with
    `stop_reason: "tool_deferred"` and a `deferred_tool_use` payload, and
    `claude -p --resume <id>` re-fires the hook. Defer has no timeout and the session
    persists on disk (subject to the 30-day `cleanupPeriodDays` sweep).
  - Defer only works when Claude makes a **single** tool call in the turn.
  - AskUserQuestion is 1–4 questions with 2–4 options each, and it is unavailable in
    subagents. Source: https://code.claude.com/docs/en/agent-sdk/user-input (read
    2026-10-06).
- **Muse** maps `userInput/request` to `:native_user_input_required`
  (`muse/turn_loop.ex:119`, `muse/transcript.ex:67-69`). It is out of D10's named scope,
  but the same adapter capability can cover it later.

### 1.5 Executor as requester

- `aiur ask` (`asks.ex:1-35`, `asks_store.ex:13-39`) has `title`, `body`, `urgency`,
  `blocking`, and `ask_`-prefixed ids. It has no options, no ticket and no delivery, and
  nothing in `src/lib/aiur_web` references it.
- **Open ticket #3005** (labels `enhancement`, `complexity:3`, `priority:1`,
  `agent:ci-wait`, so likely in flight). It adds `aiur operator-relay-answer` with a new
  actor kind `operator_relayed`, so the Executor can record an answer the operator gave in
  conversation, including for `human_required`. It is off by default
  (`executor.relay_operator_answers`), revocable by supersede or moot, and alerts on every
  use. **MP-E2 treats `operator_relayed` as human-attributed but below a direct operator**
  (RC-41, contract §6 rule 3a): `direct operator > operator_relayed > executor`. A relay
  never supersedes or revises a direct operator answer and never answers an
  Executor-originated Command; #3006's own guard for the first case is kept (C3-T01).
  `human_required` holds against the Executor's CLI and API surfaces only, not against
  a same-user process with the cookie; `actor_source` records the real entry point
  (security M4, contract §4 and §6).

### 1.6 Surfaces

- **Dashboard:** `/commands` and `/commands/:decision_id` (`aiur_web/router.ex:142-143`).
  The actor is `%{kind: :operator, id: dashboard user}`
  (`aiur_web/operator_control_center/decision_commands.ex:82-83`), with record, defer,
  dismiss and retry.
- **Stream Deck:** `answer_command` (`aiur_web/streamdeck_channel.ex:152,567-573`) as
  operator `streamdeck` (`streamdeck_commands.ex:19,73`).
- **Supervisor API:**
  - `GET /api/v1/decisions[/:id]` and `POST …/enrich|decide|revise`
    (`router.ex:82-108`), authenticated by `AIUR_SUPERVISOR_TOKEN`
    (`aiur_web/supervisor_auth.ex:17-18`).
  - Conflicts return 409 `decision_conflict`
    (`aiur_web/controllers/decision_api_controller.ex:114-127`).
- **Docs:** `website/docs-app/concepts/commands.md`, `concepts/executor.md`.
- **Skills:** `.claude/skills/aiur-run/SKILL.md:566-617` and
  `references/executor.md:167-186` cover Executor triage. `.claude/skills/aiur-agent`
  covers how agents raise Commands (`attention-and-resolve.md`, `emit-and-subscribe.md`).

## 2. Proposed boundaries

| Component | Kind | Public interface | Deps (required / optional) | Prior |
| --- | --- | --- | --- | --- |
| `Aiur.DecisionStore` (existing) | core store | unchanged plus v2 fields; new lifecycle events `routed`, `human_needed`, `native_released` | kernel, events / — | U6, boundary 27 `DEC` |
| **NEW** `Aiur.Commands.Routing` | GenServer plus pure policy | `route(decision, roster_snapshot) :: route`, `tick/1`, `recompute_on_boot/0` | DecisionStore, Executor.Roster / — | `DEC`, `EXE` (26) |
| **NEW** `Aiur.Commands.NativeCapture` | pure plus callbacks | `capture(adapter_event, ctx) :: {:command, attrs} \| {:release, text} \| {:policy, :approval}` | DecisionStore, harness adapter / — | `RUN` (18), `CDX` (21), `CLD` (22) |
| **NEW** `Aiur.Commands.ExecutorDelivery` | module | `deliver(decision) :: :ok \| {:error, _}` | ExecutorEvents / E3 input channel (optional) | `EXE` |
| Harness adapters (Codex, Claude) | per-harness | the §10 contract callbacks | MP-R7 package | U4, `CDX`, `CLD`, MP-R7 |
| `aiur-claude` (external repo) | sibling | emits `item/tool/requestUserInput` and accepts the reply (C5) | Claude Code ≥ the version with `defer` | sibling |
| Dashboard and CLI | surfaces | per DESIGN-E2 | contract §9 | U6, `WEB` (34), `CLI` (31) |

- The routing policy is a **pure function** of `{requester, authority, reversibility,
  roster snapshot, now, config}`, so it can be tested without processes.
- Notifications (N4/N5) depend only on the `human_needed` event and the read API, never on
  routing internals.

## 3. Alternatives and recommendation

**A. Native capture: how to hold the agent while a human answers.**

1. *In-band hold.* Keep the native request pending until the answer arrives. It gives the
   best fidelity (the model receives a real tool result). But it dies with the process and
   hits the 1 h turn and stall timeouts.
2. *Release immediately.* Answer at once with "recorded as Command X; end your turn", then
   deliver the answer later as a message. This is robust and uses existing delivery, but
   it loses structure, and the model may carry on guessing.
3. *Defer and resume (Claude only).* The session persists with the pending tool. aiur
   resumes it with the answer. It has fidelity and survives restarts, but needs
   `aiur-claude` changes and works only for single-tool-call turns.

**Recommendation:** a hybrid that the adapter declares as a capability.
- Codex holds in-band, with a release fallback (§7.3 of the contract) when the hold
  cannot continue.
- Claude uses defer-and-resume through `aiur-claude`, which emits the same
  `item/tool/requestUserInput` request so that aiur core sees one protocol. A multi-call
  turn, where `defer` is ignored, falls back to release.
- The Command is always durable before the agent is held. Delivery then picks in-band if
  the native request is still pending, otherwise message. This satisfies "never vanish",
  because a release keeps the Command open.

**B. One Command per native call versus one per question.** Per question gives simpler
records but needs grouping, and the native tool needs **all** answers at once.
**Recommendation:** one Command per native call, with v2 `questions[]`.

**C. Where escalation lives.**
- Inside `DecisionStore`: rejected. The file is 4,826 lines (KTD1) and would mix
  timer state into the single writer.
- In `DecisionAttention`: rejected. It is the legacy, unbounded re-ask path.
- **Recommendation:** a new `Aiur.Commands.Routing` that writes through the store's public
  API and recomputes deadlines from durable `routed_at`.

**D. Executor-originated Commands.**
- Extend `Aiur.Asks`: rejected, because it is a second store with no UI.
- **Recommendation:** Decision records with `requester.kind: :executor` and a nullable
  `ticket`. Keep `aiur ask` as an alias.

**E. Executor-first versus simultaneous as a global setting.** Rejected by D9: authority
decides. No global toggle.

## 4. Contracts

- **Owns:** `contracts/command-request-and-resolution.md` (identity extensions, v2
  content, routing, escalation invariant, answer rules, delivery, events, client
  surfaces, adapter requirements).
- **Consumes, with assumptions:**
  - *Identity:* worker `session_ref`, `executor_id`, `instance_id`, `machine_id` exist
    and are stable. Remote addressing is `{machine_id, instance_id, decision_id}`.
  - *Events and replay (MP-R2):* `ticket.<id>.agent.decision.*` and `executor.*` keep
    their topic grammar. If R2 introduces a versioned external subscription, the
    `human_needed` event must be on it. Clients reconcile Command state from the read API,
    not from replay.
  - *Harness adapter (MP-R7):* contract §10, items 1–6. **Reconcile:** R7 is
    "behaviour-preserving". Adding `native_question` is a new capability, so R7 must
    either define the callback slots (no-op by default) or MP-E2-C4 adds them after R7.
  - *Notification (MP-N4):* consumes `human_needed` (no question text) and fetches content
    after authentication.
  - *Capabilities:* `harness.<id>.native_question` with attribute `mode`
    (`in_band_hold | defer_resume | none`) is the published capability fact (CR-E2-6,
    X-17). "Executor live" is **not** a capability: it is the roster rule of contract §4
    (`active | idle`, RC-37).

## 5. Non-happy paths

| Case | Behaviour |
| --- | --- |
| Harness cannot capture (`:none`, or Codex feature off) | Current behaviour stays: the auto-answer text, plus a capability note. Agents still use `decision.requested`. Nothing claims capture works. |
| Approval-shaped requestUserInput | Stays with the approval policy (D10). Never a Command. A test asserts it. |
| Secret question (`isSecret`) | Released without storing. A needs-attention alert with no content. |
| Executor offline or stalled at creation | `human_only` / escalate at once (`executor_offline`). |
| Executor ignores a Command | The ack and answer deadlines escalate it to the human (invariant N1). |
| Daemon restart mid-hold | Codex: the held request dies with the port, the Command stays open, and on worker respawn the answer is delivered as a message (`deliver_pending_answers`). Claude: the deferred session persists. Resume uses the answer if one exists, otherwise defers again. Deadlines are recomputed from `routed_at`. |
| Agent finished or ticket closed while open | The existing expiry (`decision_expiry.ex`) or moot. Clients get the terminal event and disable answering. |
| Duplicate submissions (double tap, two devices) | `idempotency_key` gives `:duplicate`. Different keys: the first wins and the loser gets the conflict with the winning answer. |
| Human answers after the Executor answered | Supersede if undelivered. After delivery, offer a follow-up message instead. |
| Executor tries to override a human answer | Refused (contract §6.4). |
| Answer longer than 7 800 chars | Existing truncation in message delivery. In-band delivery uses the same cap. |
| Corrupt or replayed log with v2 events on an old binary | The rollback hazard in contract §11. Test it. |
| Privacy | `human_needed` carries no question text. Question and context stay local behind dashboard or pairing auth. `isSecret` answers are never stored. |
| Multiple Executors (roster supports it) | Any live Executor makes the route `executor_first`. The first Executor answer wins. Escalation is per Command, not per Executor. |

## 6. Acceptance criteria

1. A Codex worker's native `request_user_input` (with capture enabled) creates exactly
   one Command with `origin: native_question` and the agent stays held. Answering it from
   the dashboard returns the native tool result carrying the chosen option's label.
2. The same flow with the Codex port killed before the answer: the Command stays open,
   `native.hold` becomes `released`, and after respawn the answer arrives as a correlated
   message and resumes the worker.
3. An approval-shaped requestUserInput never creates a Command.
4. A `supervisor_allowed` Command with a live Executor is `with_executor`. With no Executor
   action, it becomes `with_human` exactly once after `executor_answer_ms`, and emits one
   `human_needed`. This also holds across a daemon restart in between.
5. A `human_required` Command is `with_both` at creation and emits `human_needed` at once.
6. With the roster empty or stalled, every new Command is `with_human`.
7. An Executor answer that is not yet delivered can be replaced from the dashboard. After
   delivery the dashboard shows the "too late" state, and the API returns 409 with the
   winning-answer summary.
8. An Executor `supersede` of a human answer is refused.
9. `aiur command request "…" --option …` (Executor) creates a `with_human` Command with no
   ticket. Answering it makes `aiur executor-wait` return `executor.decision.answered`.
10. Each test fails with its production hunk reverted (AGENTS.md).
11. A manual `aiurdev --test` run in wrapper tmux shows a native question in the dashboard
    and in the chat pane (AGENTS.md § Manual testing).

## 7. UX gate

DESIGN-E2 owns the inbox, the detail view, routing chips, the escalation timeline,
supersede, multi-question answers, the Executor-originated filter, CLI copy, and the shared
presentation for N6 and E5. Implementation tickets with a visible surface are blocked until
it is approved.

## 8. Open questions

**Owner (Kevin):** escalation timeout defaults (5 min ack, 15 min answer); whether
"With Executor" Commands count in the banner; the native 4-option exception; the
multi-question layout; whether to hand back to the Executor for `supervisor_*`; and, once
the spike succeeds, **whether to enable an `UnderDevelopment` Codex feature flag in
production**. These are in DESIGN-E2 §6.

**Research (Phase C):**
- R-Q1 *(spike ticket C4-T00, not executed)*: does `codex-cli 0.160.0` with `features.default_mode_request_user_input=true`
  offer the tool in aiur's app-server sessions? Does the client really wait with no
  timeout?
- R-Q2 *(spike ticket C5-T00, not executed)*: does `aiur-claude` plus `--permission-prompt-tool` plus a PreToolUse defer
  round-trip with `bypassPermissions`, and does it leave permission prompts untouched
  (D10)?
- R-Q3: *(answered in Phase C, C2-T04)* what is the minimal Executor "acknowledgement" signal?
- R-Q4: *(answered in Phase C, §0 and C1-T01)* does the projection reducer tolerate unknown v2 events on rollback?
- R-Q5: *(answered in Phase D)* #3005/#3006 add `operator_relayed` to the answer actor
  kinds (PR #3006 open on 2026-10-06); MP-E2 ranks it per RC-41 and rebases on #3006.

## 9. Plan refresh after the refactor

- **MP-R7** moves `codex/approvals.ex`, `codex/user_input_answers.ex` and
  `claude/coding_agent.ex` into the harness-adapter package. C4 and C5 then target the
  adapter callbacks instead of these paths. If C4 lands **before** R7, it must keep the
  native-question code in a new module (`Aiur.Commands.NativeCapture`) behind a narrow
  call from `approvals.ex`, so R7 moves one call site.
- **MP-R2** may rename or version topics. The `human_needed` topic must be registered in
  R2's envelope and versioning scheme.
- **U6 / boundary `DEC`** (`aiur_decisions` package) is where `Aiur.Commands.*` lands.
  Keep it free of `aiur_web` dependencies.
- **U3** owns `executor_wake_inbox.ex` and claims. C6's Executor delivery uses the
  journal's public API only.
- **#3005** may merge first. If so, re-point contract §6.3 at its actor kind and
  `executor.relay_operator_answers` key.
