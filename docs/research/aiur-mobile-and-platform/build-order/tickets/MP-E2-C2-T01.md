---
ticket_id: MP-E2-C2-T01
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: Pure routing and escalation policy
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01]
prior_units: [U6]
prior_boundaries: [DEC #27, EXE #26]
prior_features: []
prior_findings: [D9, D12, contract §4–§5, MP-E2 plan §1.2 ("no Executor-to-human timeout")]
size_owner: "n/a — new module (≤ 200 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C2-T01 — Pure routing and escalation policy

## Identity and outcome

- Bucket 2, MP-E2, chunk C2 (routing and escalation).
- **User value:** the rule "who is asked, and when the human is pulled in" is one pure,
  table-tested function, so no Command can sit with an absent Executor.
- **Deliverable:** PROPOSED `Aiur.Commands.Routing.Policy` with `route/2` and
  `escalation_due/3`, plus a roster summarizer `liveness/1`.
- **Non-goals:** processes, persistence, config reading (callers pass a config map).

## Dependencies and blockers

- Blocked by **DESIGN-E2** (§6.1 timeout defaults are passed in, not hard-coded).
- Predecessor: C1-T01 (`Requester.kind/1`).
- May run concurrently with C2-T02, C3-T01.

## Verified starting point (`45a290e3`)

- Roster: `src/lib/aiur/executor/roster.ex:52-69` `build/1` returns
  `%{cursor, pending_count, executors: [entry]}`; entry `:state` ∈
  `:active | :idle | :stalled | :expired | :unknown` (`:7-21`, `:110-123`).
- Executor answerability: `src/lib/aiur/decision_authority.ex:82-95`
  `executor_answerable?/1`, `executor_authority_answerable?/1`,
  `executor_reversibility_answerable?/1` (used by the store at `decision_store.ex:1503-1526`).
- `Decision` fields `authority`, `urgency`, `blocking`, `reversibility` (`decision.ex:107-148`).

## Chosen design

```elixir
@type liveness :: :live | :stalled | :offline
@spec liveness(roster :: map()) :: liveness
# any entry :active|:idle -> :live; else any entry not :expired -> :stalled; else :offline

@type route :: %{policy: :executor_first | :simultaneous | :human_only,
                 state: :with_executor | :with_both | :with_human,
                 cause: nil | cause()}
@spec route(Decision.t(), liveness) :: route
```

| Requester | authority | Executor may answer (`DecisionAuthority.executor_answerable?/1`) | liveness | route |
| --- | --- | --- | --- | --- |
| executor | any | any | any | human_only / with_human / `executor_originated` |
| worker | any | any | `:offline` | human_only / with_human / `executor_offline` |
| worker | any | any | `:stalled` | human_only / with_human / `executor_stalled` |
| worker | human_required | — | `:live` | simultaneous / with_both / `authority_human_required` |
| worker | supervisor_* | false | `:live` | human_only / with_human / `executor_not_answerable` |
| worker | supervisor_* | true | `:live` | executor_first / with_executor / nil |

```elixir
@spec escalation_due(Decision.t(), DateTime.t(), config :: %{ack_ms, answer_ms, urgent_factor})
      :: :none | {:due, cause(), DateTime.t()} | {:next, DateTime.t()}
```

- Only for `route_state == :with_executor` and `decision_status in [:open, :deferred]`
  with no answer.
- `factor = if blocking and urgency in [:high, :critical], do: urgent_factor, else: 1.0`.
- `ack_deadline = routed_at + ack_ms*factor` (skipped when `executor_acknowledged_at`
  is set); `answer_deadline = routed_at + answer_ms*factor`.
- Returns the earliest overdue cause (`executor_ack_timeout` before
  `executor_answer_timeout` when both are overdue), else `{:next, earliest_deadline}`.
- Invariant N1 helper: `armed?(decision, config)` is true iff `with_executor` implies a
  finite next deadline. Used as a property in tests.

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/routing/policy.ex` (≈150 lines), no side effects, no
   `Application.get_env`.
2. PROPOSED `src/test/aiur/commands/routing/policy_test.exs` (table + property tests).

## Non-happy paths

- Unknown authority value (corrupt/legacy): treated as not executor-answerable →
  `human_only`/`executor_not_answerable` (fail toward the human).
- Empty roster list: `:offline`. `:unknown` entries: not live (roster moduledoc: never
  upgraded from absence of failure).
- `routed_at` missing (pre-C2 Command): `escalation_due/3` returns `:none`; C2-T03 routes
  such Commands first.
- Clock skew: callers pass `now`; no `DateTime.utc_now/0` inside.

## Compatibility and rollout

n/a — pure module, no caller until C2-T03.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/commands/routing/policy_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "route table" — all 6 rows above × urgency × blocking | exact route maps | the corresponding `route/2` clause |
| "liveness" — `[active]`, `[idle, stalled]`, `[stalled]`, `[unknown]`, `[expired]`, `[]` | live, live, stalled, stalled, offline, offline | `liveness/1` |
| "ack timeout first" — routed 6 min ago, no ack, config 5/15 min | `{:due, :executor_ack_timeout, _}` | ack branch |
| "ack stops only the ack timer" — acked, routed 16 min ago | `{:due, :executor_answer_timeout, _}` | ack skip |
| "urgent halves deadlines" — blocking+high, routed 3 min ago | `{:due, :executor_ack_timeout, _}` | factor |
| "next deadline" — routed 1 min ago | `{:next, routed_at + 5 min}` | `:next` branch |
| property "N1: every with_executor open Command has a finite next deadline or is due" | holds for generated Commands | `armed?/2` / branches |

Mutation check: replace the `:stalled` liveness result with `:live` → "liveness" fails;
drop the factor → "urgent" fails; etc. (worktree, porcelain shows only the revert).

## Completion and handoff

- [ ] Module + tests; no side effects.
- Docs: none (C8-T01 documents routing).
- Dependents: C2-T03, C2-T05.
