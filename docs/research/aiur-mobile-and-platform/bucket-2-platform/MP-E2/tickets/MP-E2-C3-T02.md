---
ticket_id: MP-E2-C3-T02
feature_id: MP-E2
chunk_id: MP-E2-C3
bucket: 2-platform
title: Answering facade for human surfaces (answer, supersede, normalized outcomes)
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C3-T01]
prior_units: [U6]
prior_boundaries: [DEC #27, WEB #34]
prior_features: [MP-N6 (reuses the facade), MP-E4 (answering from the conversation drawer, D15)]
prior_findings: [D11, RC-41, security B2/M4/m8, contract §6, §9; #3005/#3006 operator_relayed]
size_owner: "n/a — new module; WEB untouched here (C3-T03 wires the dashboard)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C3-T02 — Answering facade for human surfaces

## Identity and outcome

- Bucket 2, MP-E2, chunk C3.
- **User value:** every human surface (dashboard, Stream Deck, later phone, watch and the
  conversation drawer) answers and replaces answers through one path with one set of
  outcomes, so "already answered by…", "too late" and "answer queued" read the same
  everywhere.
- **Deliverable:** PROPOSED `Aiur.Commands.Answering` with `answer/3`, `supersede/3`,
  `outcome/2`; v2 `question_answers` encoding for multi-question Commands.
- **Phase C choice (resolves chunks.md "choose one"):** no new HTTP route in MP-E2. The
  supervisor API actor is `:supervisor`, which is not human, so D11's human supersede does
  not apply to it. The device route belongs to MP-N6 (pairing auth, MP-N2) and calls this
  facade.
- **Non-goals:** UI (C3-T03/T04); supervisor supersede; revise (unchanged "Send
  correction" path, contract §6 rule 7).

## Dependencies and blockers

- Blocked by **DESIGN-E2** (§4.4 outcome copy lives in the surfaces, not here; the
  outcome atoms below are what DESIGN-E2's rows map to).
- Predecessor: C3-T01 (`human_attributed?/1`, `precedence/1`, `ConflictSummary`,
  `actor_source` in the store).
- **#3005/#3006** (open): add `operator_relayed`. This facade does **not** accept
  `operator_relayed`: the only relay entry point is `aiur operator-relay-answer`
  (`actor_source: :relay_cli`), which calls the store, not this facade. A relayed
  actor passed to the facade is `:not_allowed, :invalid_actor`.
- May run concurrently with C2, C4.

## Verified starting point (`45a290e3`)

- `DecisionStore.answer/5` `decision_store.ex:190-193`; `supersede/5` `:287-291`
  (refusals documented `:268-285`).
- Dashboard today calls the store directly: `aiur_web/operator_control_center/decision_commands.ex:82-99,174`.
- Stream Deck calls the store directly: `aiur_web/streamdeck_channel.ex:567-578`.
- Answer payload validation: `Aiur.DecisionAnswer.normalize/2` (`decision_answer.ex`),
  actor kinds `:17-19`.

## Chosen design

```elixir
@type surface :: :dashboard | :streamdeck | :cli | :api | :phone | :watch | :conversation
@spec answer(String.t(), map(), keyword()) :: outcome()
@spec supersede(String.t(), map(), keyword()) :: outcome()
# opts: actor: %{kind, id}, client: %{surface, device_id}, actor_source: atom (REQUIRED), store: server
@type outcome ::
  %{status: :accepted | :duplicate, decision: Decision.t(), delivery: :pending | :delivered | :queued_for_restart}
  | %{status: :already_answered, winner: ConflictSummary.t()}
  | %{status: :too_late, reason: :answer_delivered | :answer_in_flight, winner: ConflictSummary.t()}
  | %{status: :withdrawn, reason: :expired | :moot | :resolved | :dismissed}
  | %{status: :stale, current_version: pos_integer()}
  | %{status: :not_allowed, reason: :human_answer | :direct_operator_answer | :executor_scope | :invalid_actor}
  | %{status: :error, reason: term()}
```

- `answer/3`: requires `direct_human?/1` (`:operator`) for every surface except
  `:cli`; passes `opts[:actor_source]` to the store unchanged. The caller (a controller,
  LiveView, channel) sets it from its own entry point: dashboard LiveView
  `:dashboard_session`, Basic-Auth JSON `:basic_auth`, device bearer `:device` (from
  `conn.assigns.auth_actor`, MP-N2-C6-T01), Stream Deck `:streamdeck`. A missing
  `actor_source` raises `ArgumentError` in the facade (a surface must name itself;
  only raw store calls default to `:rpc`). Maps store results:
  `{:conflict, {:already_decided, _}}` → `:already_answered` + `ConflictSummary`;
  `{:conflict, {:stale_version, _, cur}}` → `:stale`; `{:conflict, s}` with
  `s in [:expired, :moot, :resolved]` → `:withdrawn`.
- `supersede/3`: direct operator only; store refusals `answer_delivered`/`answer_in_flight`
  → `:too_late`; `{:direct_operator_answer, _}` and `{:human_answer, _}` →
  `:not_allowed` with that reason (unreachable for a direct operator today; kept so a
  future relay caller cannot be mis-mapped); `{:not_decided, _}` → falls back to
  `answer/3` (nothing to replace). `ConflictSummary.for/2` gets the caller actor so
  `replaceable` uses the precedence rank (contract §6 rule 3a), never "caller is human".
- `delivery`: `:queued_for_restart` when the ticket has no running agent
  (`DecisionStore` reply plus `Aiur.Orchestrator` running check is **not** called here —
  the facade reports `delivery_status` from the returned Decision; "agent not running"
  is a presentation concern resolved in C7-T02 with the units read model).
- Multi-question (v2): `question_answers: %{qid => [label | custom]}` is validated against
  `decision.questions` (every question answered; option labels exist unless
  `allow_other`); encoded into the existing answer as `custom_response` =
  JSON `{"question_answers": …}` with a `kind` marker so `DecisionDispatch` (and C4-T03)
  can decode it. Rationale: no `DecisionAnswer` schema change (rollback-safe); the v1
  render shows readable text built by `Aiur.Commands.Answering.render_question_answers/2`.
- `client` is attributed via `actor.id` (`"dashboard"`, `"streamdeck"`,
  `"device:<device_id>"`, the single spelling in contract §6, security m8) — no new
  answer field. `phone:` is never written.

## Implementation steps

1. `commands/answering.ex` grows to ≈180 lines (split `answering/outcome.ex` if larger).
2. PROPOSED `src/test/aiur/commands/answering_test.exs`.
3. No surface rewiring here (C3-T03/T04 do it), so this PR is inert by itself.

## Non-happy paths

- Store unavailable (`:exit`): `%{status: :error, reason: :store_unavailable}`.
- Partial multi-question answer: `{:error, {:question_answers, :incomplete}}` before any
  store call (native tool needs every answer, DESIGN-E2 §4.2).
- Two devices, same key: `:duplicate` (safe retry). Different keys: loser gets
  `:already_answered` with the winner.
- Over-long custom text: existing `DecisionAnswer` bounds; dispatch caps at 7 800 chars
  (`decision_dispatch.ex:22`).

## Compatibility and rollout

- New module; inert until wired. Encoded multi-question answers render as readable text to
  any older reader.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/commands/answering_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "operator answer accepted" | `%{status: :accepted}` | answer path |
| "second operator answer on another device is already_answered with winner" | winner.actor_id == first device | conflict mapping |
| "operator supersedes undelivered executor answer" | `:accepted`, new active answer actor operator | supersede path |
| "supersede after delivery is too_late answer_delivered" | as stated | mapping |
| "supersede while in flight is too_late answer_in_flight" | as stated | mapping |
| "executor actor through the facade is not_allowed" | `:not_allowed, :invalid_actor` | direct-human check |
| "operator_relayed actor through the facade is not_allowed" | `:not_allowed, :invalid_actor` (fixture kind until #3006 merges) | `direct_human?/1` (swap it for `human_attributed?/1` and the row fails) |
| "facade records the entry point's actor_source" | `answer/3` with `actor_source: :device` → stored `actor.source == :device`, `actor.id == "device:<id>"` | pass-through of `actor_source` |
| "facade without actor_source raises" | `ArgumentError`; store double not called | required-opt check |
| "an answer with no surface context is recorded actor_source: :rpc" (M4; store-level row lives in C3-T01, repeated here through `DecisionStore.answer/5` called directly, which is what an RPC caller does) | `actor.source == :rpc` | C3-T01 default |
| "already_answered winner carries actor_source and rank-based replaceable" | `winner.actor_source == :dashboard_session`; `replaceable` true for an operator caller against an undelivered Executor winner | `ConflictSummary.for/2` caller arg |
| "multi-question incomplete answer rejected before store call" | error; store double not called | validation |
| "multi-question answer encodes and renders" | `render_question_answers/2` text lists every question | encoder |

Mutation check per row: revert the hunk in a worktree, confirm the row fails, restore;
report the commands in the PR.

## Completion and handoff

- [ ] Facade + tests; surfaces untouched.
- Docs: none user-facing here.
- Dependents: C3-T03, C3-T04, C4-T03 (decodes `question_answers`), C7-T02, MP-N6, MP-E4.
