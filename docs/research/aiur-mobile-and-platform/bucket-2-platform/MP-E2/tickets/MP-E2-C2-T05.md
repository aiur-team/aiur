---
ticket_id: MP-E2-C2-T05
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: decisions.escalation config keys with documented defaults
status: blocked
blocked_by: [DESIGN-E2, MP-R1-C11-T03]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: []
prior_findings: [DESIGN-E2 §6.1 (owner defaults), contract §5]
size_owner: "n/a (current edited code <=500; all additions stay <=500; ledger c96025161f1688888de4159d8c31fb117a989b6a)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C2-T05 — `decisions.escalation` config keys with documented defaults

## Identity and outcome

- Bucket 2, MP-E2, chunk C2.
- **User value:** the operator can tune how long the Executor has before a Command
  becomes "needs you", or switch escalation off.
- **Deliverable:** keys `decisions.escalation.enabled` (default `true`),
  `decisions.escalation.executor_ack_ms` (proposed `300000`),
  `decisions.escalation.executor_answer_ms` (proposed `900000`),
  `decisions.escalation.urgent_factor` (proposed `0.5`); accessors; docs; example config.
- **Namespace decision:** the existing `decisions:` section
  (`Aiur.Config.Schema.Decisions`, embedded at `config/schema.ex:57,169`), not a new
  `commands:` section — one place for Command policy, consistent with
  `decisions.supervisor_allowed_kinds`. (Contract §5 updated; DESIGN-E2 §6.1 wording is a
  coordinator request in `CONTRACT-REQUESTS.md`.)
- **Non-goals:** reading the keys (C2-T03 does).

## Dependencies and blockers

- **MP-R1-C11-T03** (final plan refresh after the refactor): enforces "refactor before
  features" (D1, RC-35). Re-read this ticket's paths against the refreshed plan before starting.
- Blocked by **DESIGN-E2 §6.1**: Kevin approves or changes the three defaults. The schema
  and docs can be written now; the default literals are a one-line change after approval.
- No predecessors. May run concurrently with C2-T01, C2-T02.

## Verified starting point (post-refactor code scope)

- `src/lib/aiur/config/schema/decisions.ex:18-33` still declares supervisor_allowed_kinds and supervisor_allow_non_reversible, with an explicit cast list. Escalation is not present.
- The old config.ex:1137-1144 coordinates are invalid after the Config split. The supervisor-policy implementation is now `src/lib/aiur/config/observability_settings.ex:139-143`. Put new policy accessors in the owning settings helper and expose the public Config entry point without recreating the old monolith.
- The root configuration reference is near the size ceiling. Re-resolve the configuration documentation owner and consolidate existing rows if needed; never grow a file beyond 500 lines.
- Annotated defaults remain in `.aiur/examples/config.example` and the workflow YAML templates. Enumerate the templates present at implementation time; do not assume the old count of three.

Refreshed against 4fbe109541ba1e279d3eb315d8455c4d139c92ba on 2026-10-25 (MP-R1-C11-T03). Scope: schema/accessor placement, documentation gate and template inventory. Defaults remain DESIGN-E2-owned; schema and documentation work may proceed under the existing backend exception; default approval remains a product gate.

## Chosen design

- Nested embed PROPOSED `Aiur.Config.Schema.Decisions.Escalation` (new file
  `config/schema/decisions_escalation.ex`, ≈60 lines) with validations:
  `executor_ack_ms` ≥ 10 000; `executor_answer_ms` ≥ `executor_ack_ms`;
  `urgent_factor` in `(0.0, 1.0]`; `enabled` boolean.
- Accessor `Config.decision_escalation/0 :: %{enabled, ack_ms, answer_ms, urgent_factor}`
  — the map C2-T01's `escalation_due/3` takes.
- Defaults are module attributes in the embed, so the post-approval change is one line.

## Implementation steps

1. New embed module; `embeds_one(:escalation, …)` in `Decisions` + `cast_embed`.
2. Add the accessor through Config and its owning settings helper (`config/observability_settings.ex`); old config.ex:1137-1144 no longer exists.
3. `website/docs-app/reference/configuration.md`: four entries with defaults and the
   sentence "A Command routed to the Executor moves to you after …".
4. `.aiur/examples/config.example` and every shipped `src/examples/workflows/*.yaml`: a
   commented `decisions.escalation` block (commented is fine here: defaults apply; no
   saving is claimed).

## Non-happy paths

- Invalid values: config load fails with a field error (existing schema error path).
- `answer_ms < ack_ms`: rejected (otherwise the ack timer is meaningless).
- Hot reload: Routing reads the accessor each tick, so a reloaded config applies at the
  next tick.

## Compatibility and rollout

- Additive keys with defaults; absent section = defaults. Rollback: older binaries ignore
  unknown keys in `decisions` (Ecto `cast/4` with explicit list).

RC-23 at 4fbe109541ba1e279d3eb315d8455c4d139c92ba: existing edit candidates were counted in the refresh admissions inventory. Keep every existing/new file <=500 lines; route new logic to the named small owner modules and new focused test files. Recheck actual scope at admission.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN mise exec -- env -C src mix test test/aiur/config/decisions_escalation_test.exs
python3 scripts/check-config-docs.py && bash scripts/test-check-config-docs.sh
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "decisions.escalation defaults" | `%{enabled: true, ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}` | embed defaults |
| "answer_ms below ack_ms is rejected" | changeset error on `executor_answer_ms` | cross-field validation |
| "urgent_factor 0 is rejected" | error | range validation |
| `check-config-docs.py` | passes with docs; fails if a key's docs entry is deleted | docs entries |

Mutation check per row.

## Completion and handoff

- [ ] Keys, accessor, docs, example templates; `lint` green.
- [ ] Defaults updated to DESIGN-E2 §6.1 answers.
- Docs: `reference/configuration.md` (this PR).
- Dependents: C2-T03.
