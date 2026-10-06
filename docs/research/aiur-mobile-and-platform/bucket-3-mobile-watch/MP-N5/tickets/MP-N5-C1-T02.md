---
ticket_id: MP-N5-C1-T02
feature_id: MP-N5
chunk_id: MP-N5-C1
bucket: 3-mobile-watch
title: Effective preference resolution per (device, instance) with capability masking
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C1-T01, MP-N4-C3-T04]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-R1 (capabilities), MP-E1 (build_queue)]
prior_findings: [capability-matrix rule 1 (never a working toggle for an unavailable option)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C1-T02 — Effective preferences

## Identity and outcome

Bucket 3, MP-N5, chunk C1. Pure function
`Aiur.Push.Preferences.effective(record, instance_id, capabilities) :: %Effective{}` that
merges defaults with that instance's overrides and then masks every option the instance
cannot deliver, returning per option `{value, availability}` where availability is
`:available | {:unavailable, reason}`. Used by the policy (C2) and the options API (C1-T03).

## Dependencies and blockers

- C1-T01; MP-N4-C3-T04 (the `push` capability and the registry read path).
- DESIGN-N5 no-UI release; reason **copy** is DESIGN-N5 (API returns codes only).

## Verified starting point

- Capability report shape (identity-and-capabilities contract §2.2); ids `build_orders`,
  `build_queue`, `commands.answer` (MP-R1 capability matrix; N5 plan §6).
- Opt-in sources exist as topics at `45a290e3`: `ticket.*.pr.merged`,
  `ticket.*.agent.retry_exhausted`, `ticket.*.ci.failed`
  (`src/lib/aiur/executor_bindings.ex:25,29,32`).

## Chosen design

| Option | Requires | Unavailable reason codes |
| --- | --- | --- |
| `commands_needs_you`, `commands_non_blocking` | `push` | from `push` (never masked by build state) |
| `progress_step_pct`, `progress_completion` | `build_queue` available (RC-10 read API lives there) and `build_orders` for roots | `build_orders_not_installed`, `build_queue_not_installed`, `not_configured`, `unknown` |
| `pr_merged`, `optin.ci_failed` | GitHub tracker (event source) | `unsupported_tracker` |
| `optin.agent_retry_exhausted` | orchestration | `not_running` |

- Masked options keep their stored value (N5 plan §6: "stored values are kept but not
  applied") and report the reason; the policy treats masked = off.
- Unknown capability state → `{:unavailable, :unknown}`, never `available`
  (AGENTS.md collapsed-cause rule).

## Implementation steps

`preferences/effective.ex` (PROPOSED) + table-driven tests.

## Non-happy paths

Capability report stale → still evaluated, but `observed_at` passed through so the API
can show staleness (C1-T03).

## Compatibility and rollout

Pure function; no config.

## Verification

`src/test/aiur/push/preferences_effective_test.exs` (PROPOSED), availability matrix
fixtures (build orders absent / partial / present):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"override wins over default for that instance only"` | instance A 50, B 25 | apply overrides globally |
| `"build orders absent → progress unavailable with reason"` (AC-N5-7) | `{:unavailable, :build_orders_not_installed}` | replace with `{false, :available}` (unknown-path mutation: plausible default `off`) |
| `"unknown capability state is unavailable unknown"` | `:unknown` | map to available |
| `"commands never masked by build state"` | available | mask all on missing build_orders |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/preferences_effective_test.exs`.

## Completion and handoff

- [ ] Matrix covers every option × capability state.
- Dependents: C1-T03, C2-T02..T04.
