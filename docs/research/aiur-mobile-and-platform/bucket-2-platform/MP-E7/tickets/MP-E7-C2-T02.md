---
ticket_id: MP-E7-C2-T02
feature_id: MP-E7
chunk_id: MP-E7-C2
bucket: 2-platform
title: "Aiur.Listener.Effective.compute/2: requested to effective mode with a named reason"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-R7-C2-T01, MP-R7-C2-T03]
prior_units: [U4]
prior_boundaries: [MSG (16), CA (20)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (new file < 200 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C2-T02 — Effective listener mode

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C2.
- **User value:** an unsupported mode is never silently downgraded: the
  system always knows the requested mode, the mode that will actually apply,
  and why they differ (contract §4; acceptance criterion 4).
- **Deliverable:** `Aiur.Listener.Effective` (PROPOSED
  `src/lib/aiur/listener/effective.ex`), a pure module:

```elixir
@spec compute(mode_record :: map(), harness :: nil | map(), opts :: keyword()) :: view()
@spec compute(mode_record :: map(), harness :: nil | map()) :: view()
@type view :: %{
  requested: :steer | :sync | :async,
  effective: :steer | :sync | :async | nil,
  effective_reason: atom() | nil,
  version: non_neg_integer(),
  actor: atom(),
  support: %{steer: support(), sync: support(), async: support()}
}
@type support :: %{status: :proven | :experimental | :blocked_without_wrapper | :unsupported | :unknown,
                   carrier: :native | :emulated_interrupt | nil, reason: atom() | nil}
```

  `harness` is the value of `Aiur.Orchestrator.OperatorMessages.Capabilities.harness_delivery/3` (MP-R7-C2-T03):
  `nil` (no running entry), or `%{harness_id, source, primitives, callbacks}`
  where `primitives` may be `:unknown`.
- **Non-goals:** no persistence, no API, no delivery.

## Dependencies and blockers

- DESIGN-E7; **MP-R7-C2-T01** (`delivery_primitives/1`; module name as fixed by that ticket — MP-R7 keeps existing `Aiur.CodingAgent.*` naming rather than an `Aiur.Harness.*` rename),
  **MP-R7-C2-T03** (`harness_delivery/3`, the running transport fact).
- It does **not** wait for MP-E7-C1-T04: aiur's support derivation is Elixir;
  MP-E7-C3-T05 later proves it against the vendored spec.
- Owner inputs read as options, defaulting to the conservative value, never
  chosen by the implementer: `emulated_interrupt_accepted?` (E7-D2, default
  `false`), `pull_tool_installed?` (true only after MP-E7-C5-T01, default
  `false`), `native_steer_callbacks` (after MP-E7-C4).
- Concurrent with MP-E7-C2-T01, MP-E7-C3-T01.

## Verified starting point (aiur `45a290e3` + MP-R7 tickets)

- Contract §4 rules and §9 table (`contracts/listener-mode.md`).
- MP-R7-C2-T01 descriptor values: `mid_turn_inject: :native` for
  `claude-repl` and the OpenAI-compatible backends, `:none` otherwise;
  `hard_interrupt` `:in_band` (codex, claude, muse), `:out_of_band`
  (claude-repl), `:none` (openai-compat); `pull_tool: false` only for
  `claude-repl`.
- `turn/steer` is not called by aiur today (`git grep -n "turn/steer" 45a290e3 -- src/lib`
  returns nothing), so no harness has a *wired* native steer in wave 3 even
  where the primitive says `:native`.
- The running backend can differ from the dispatched one after a
  `claude-repl → claude` fallback (`agent_runner/session_lifecycle.ex:953-985`),
  while `running_entry.control` is still built from the dispatched backend
  (`orchestrator/dispatcher.ex:2659-2671`) and is never refreshed
  (`git grep -n "put_in(.*:control" 45a290e3 -- src/lib` shows only status
  writes). Effective mode must therefore use `harness_delivery/3`, not
  `:control`.

## Chosen design

Support derivation (per mode, from primitives and options):

| Mode | Rule | Status / carrier / reason |
| --- | --- | --- |
| sync | `primitives.turn_boundary_start` and harness ≠ claude-repl | `proven` |
| sync | claude-repl | `experimental` (hold until Stop, contract §9) |
| sync | `turn_boundary_start` false | `unsupported`, reason `:no_turn_boundary` |
| steer | a `steer/3` callback is wired (`callbacks.steer == :native`, MP-E7-C4) | `experimental`, carrier `:native` |
| steer | no native, `hard_interrupt != :none`, `emulated_interrupt_accepted?` | `experimental`, carrier `:emulated_interrupt` |
| steer | otherwise | `unsupported`, reason `:steer_not_wired` or `:no_interrupt` |
| async | `primitives.pull_tool` and `pull_tool_installed?` | `proven` |
| async | otherwise | `unsupported`, reason `:pull_tool_unavailable` |

Effective rule (contract §4): requested if its status is `proven` or
`experimental`; else `:sync` if sync is proven/experimental; else `:async` if
async is; else `nil`. `effective_reason` names the requested mode's reason
when they differ.

Unknown / absent inputs — **never a plausible default** (AGENTS.md "A collapsed
cause names the collapse at the source"):
- `harness == nil` → `effective: nil`, `effective_reason: :not_running`.
- `primitives == :unknown` → every status `:unknown`, `effective: nil`,
  `effective_reason: :harness_unknown`.
- `source: :dispatch` → computed normally, plus `effective_reason:
  :pending_session_start` **only** when it would otherwise be `nil`; the
  `source` is carried into the view as `harness_source` so a surface can say
  "until the session starts".

The `carrier` field maps to the shared spec's `steer_carrier`
(MP-E7-C1-T05).

## Implementation steps

1. Add `effective.ex` (~140 lines) with the table above as private functions.
2. Add `src/test/aiur/listener/effective_test.exs` with a table test over the seven harness profiles in MP-R7-C2-T01 × three requested modes × option combinations.

## Non-happy paths

- Transport change (fallback/RC): the same function recomputes from the new
  `harness_delivery/3`; MP-E7-C2-T04 triggers it.
- Paused agent: mode effectiveness is independent of pause; pause gating is
  delivery's job (MP-E7-C3-T02).

## Compatibility and rollout

- Pure module; no flag needed. Rollback: delete.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/effective_test.exs
env -C src mise exec -- make lint
```

Tests (`Aiur.Listener.EffectiveTest`):

- "codex sync is proven and effective sync".
- "codex steer without owner acceptance is unsupported and falls back to sync with reason steer_not_wired".
- "codex steer with emulated_interrupt_accepted is experimental with carrier emulated_interrupt".
- "openai-compat steer is unsupported because hard_interrupt is none and no native callback is wired".
- "claude-repl async is unsupported (pull_tool false) and falls back to sync".
- "codex async without the installed pull tool falls back to sync with reason pull_tool_unavailable".
- "no running entry yields effective nil with reason not_running".
- "unknown primitives yield unknown statuses and effective nil, never sync".

Mutation checks (AGENTS.md unknown-path rule): replace the `:unknown`
primitives branch with the codex profile → the last test fails; replace the
`nil` harness branch with `effective: :sync` → the "no running entry" test
fails; drop the `emulated_interrupt_accepted?` check → the "without owner
acceptance" test fails.

## Completion and handoff

- [ ] Pure module and table tests merged.
- Dependents: MP-E7-C2-T03, MP-E7-C2-T04, MP-E7-C3-T02, MP-E7-C3-T05, MP-E7-C4 (sets the native steer callback flag), MP-E7-C5-T01 (sets `pull_tool_installed?`), MP-E3-C5-T01 (composer disabled when `effective: nil`).
- Docs: none in wave 3 (no rendered surface).
