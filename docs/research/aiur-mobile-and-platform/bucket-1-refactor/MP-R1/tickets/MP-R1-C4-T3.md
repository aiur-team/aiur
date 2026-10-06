---
ticket_id: MP-R1-C4-T3
feature_id: MP-R1
chunk_id: MP-R1-C4
bucket: 1-refactor
title: Move feature accessors out of Aiur.Config and pure helpers down into config (build-order options, max turns, poll widening, allow-list parsing, Codex approval policy, project identity source)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2]
prior_units: [U8]
prior_boundaries: ["CFG #2", "BO #30", "ING #9", "GHD #8", "CDX #21", "TRK #3", "RUN #18"]
prior_features: [MP-R7]
prior_findings: []
size_owner: "src/lib/aiur/config.ex: U8 CONFIG (1,462 lines) — must shrink; src/lib/aiur/poll_cadence.ex 483 lines — must stay < 500"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C4-T3 — Accessors out, pure helpers down

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C4. Step S9.
- **User value:** none visible. Removes six config-layer upward edges without any
  behaviour change.
- **Deliverable (one commit per edge, one PR):**

  | # | Edge at base (walker, `45a290e3`) | Change |
  |---|---|---|
  | E1 | `Aiur.Config → Aiur.BuildOrder.Cadence` (`config.ex:604-660`: `build_order_ticket_detail_coordinator_options/0`, `build_order_ticket_history_options/0`, `build_order_graph_projection_options/0`) | Move the three functions to PROPOSED `Aiur.BuildOrder.Settings` (build-orders); update their three callers (`build_order/graph_projection_options.ex:113,214`, `ticket_detail_coordinator_options.ex:60`, `ticket_history_provider_options.ex:48`). They read `Aiur.Config.settings!().build_order` and `Aiur.Config.poll_interval_seconds/0` (down-edges). |
  | E2 | `Aiur.Config → Aiur.Issue` and `→ Aiur.CodingAgent.complexity_level/1` (`config.ex:493-499`, `agent_max_turns_for/1`) | Move to PROPOSED `Aiur.AgentRunner.TurnBudget.max_turns_for/1`; sole caller `agent_runner/session_lifecycle.ex:144`. `Aiur.Config` keeps `agent_max_turns/0`-style raw readers it already has. |
  | E3 | `Aiur.PollCadence → Aiur.Webhooks.IntervalPolicy` (`poll_cadence.ex:307-308,465,471`) | Move `widen/2` and `widen_factor/1` bodies (`interval_policy.ex:39-60`) into `Aiur.PollCadence`; `IntervalPolicy.widen/2`, `widen_factor/1` become `defdelegate` to keep `orchestrator/tracker_health.ex:136,198,326` unchanged. |
  | E4 | `Aiur.Config.Schema.Github → Aiur.AllowedContributors.AllowList` (`config/schema/tracker.ex:157-167`) | Move the pure parser `from_config/1` (`allow_list.ex:67-80` and its private helpers) to PROPOSED `Aiur.Config.Schema.AllowedContributorsParser`; `AllowList.from_config/1` delegates (caller `allowed_contributors/source.ex:54` unchanged). |
  | E5 | `Aiur.Config → Aiur.Codex.Config` (`config.ex:1304-1309`, approval-policy check inside `codex_runtime_settings/2` at `:1215`) | It runs on the Codex runtime path, not in `validate!/0`, so it is not a C4-T1 check. Move `validate_approval_policy/1` (pure string check) into `Aiur.Config.Schema.Codex` (config component, where the `agent.codex` section lives); `Aiur.Codex.Config.validate_approval_policy/1` delegates. |
  | E6 | `Aiur.Config.Paths → Aiur.Tracker` (`paths.ex:312`, `safe_project_identity/0`) | Read the identity through `Application.get_env(:aiur, :project_identity_source, Aiur.Tracker)` set in `src/config/config.exs` (composition root); `Paths` calls `source.project_identity()` inside the existing rescue. |

- **Explicitly not in scope (stay allowlisted, owner MP-R7):** `Aiur.Config →
  Aiur.CodingAgent` at `config.ex:319,396,1405-1413` (backend catalog: default,
  fallback targets, configurable backends, known backends) and
  `Config.Schema.AgentValidation`/`Schema.Codex → Aiur.CodingAgent`
  (`agent_validation.ex:78,132`, `agent.ex:120`). The catalog is
  `Aiur.CodingAgent.Registry.entries/0` (`coding_agent.ex:80`), which MP-R7 turns into
  registered adapter data; inverting it here would pre-empt that design.
- **Non-goals:** renaming any public function other than the moved ones; key changes.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T2. Same-file serialization with C4-T1/T2/T4.
- **Concurrent:** MP-R1-C8-T* (build-orders component) — if C8 moves `build_order/**`
  first, E1 targets the moved path.
- **Dependents:** C4-T5.

## Verified starting point (`45a290e3`)

All line references in the table were read at `45a290e3`. Additional facts:
- `Aiur.Webhooks.IntervalPolicy` (60 lines) aliases `Aiur.Config` (`interval_policy.ex:18`):
  today config and ingestion reference each other.
- `allow_list.ex` is 166 lines; `poll_cadence.ex` is 483 lines (E3 adds ~25 lines → must
  stay under 500; if not, put the math in PROPOSED `Aiur.PollCadence.Widen`).
- Callers verified with `git grep` at base (listed in the table).

## Chosen design

Pure moves with delegates where the old public function has callers outside the moving
component; no delegate where every caller is updated in the PR (E1, E2). Each move keeps
`@doc`/`@spec`. E6 uses a module (not a capture) in config so the value is inspectable.

## Implementation steps

1. Per edge: move, delegate or update callers, run the focused tests, commit.
2. Delete the stale allowlist lines reported by the checker (six keys; E2 removes
   `Config → Aiur.Issue` only — `Config → CodingAgent` remains for other lines).
3. Manifest: new files to their components.

## Non-happy paths

- E6: `:project_identity_source` missing (test env without config) → default
  `Aiur.Tracker` (same behaviour as today).
- E3: float rounding must be byte-identical; tests compare exact integers.

## Compatibility and rollout

No behaviour change. Rollback: revert (single PR).

## Verification

Existing tests that must stay green (regression guards): `test/aiur/workspace_and_config_test.exs`,
`test/aiur/poll_cadence_test.exs` (if present at the implementation head; else the
`tracker_health` tests), `test/aiur/allowed_contributors/*_test.exs`,
`test/aiur/build_order/*options*_test.exs`, `test/aiur/agent_runner/session_lifecycle_test.exs`.
New tests:

| Test | Expected |
|---|---|
| `PollCadence.widen equals the old IntervalPolicy.widen for a table of inputs` | identical integers (copy the old implementation into the test as the oracle) |
| `AllowList.from_config delegates to the config parser` | same results for valid, empty, malformed inputs |
| `Paths uses the configured project identity source` | stub source module → `repo_name/0` uses it |
| `TurnBudget.max_turns_for uses complexity level when present` | same values as old `Config.agent_max_turns_for/1` |

Command: `$TESTCMD test/aiur/config test/aiur/poll_cadence_test.exs test/aiur/allowed_contributors test/aiur/agent_runner/session_lifecycle_test.exs` (also the sibling-file rule in CONTRIBUTING: grep the full test tree for each moved function name).

Mutation check: `Paths uses the configured project identity source` fails if `Paths`
still calls `Aiur.Tracker` directly. The equivalence tests are regression guards
(named so) because the change is a move.

Checker: stale allowlist lines for E1, E3, E4, E5, E6 and `Config → Aiur.Issue` deleted.

## Completion and handoff

- [ ] Six edges handled; deferred CodingAgent edges carry reason `MP-R7`.
- [ ] `config.ex` shorter; `poll_cadence.ex` < 500.
- [ ] Docs: none.
- **Dependents:** C4-T5.
