---
ticket_id: MP-E2-C2-T05
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: decisions.escalation config keys with documented defaults
status: blocked
blocked_by: [DESIGN-E2]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: []
prior_findings: [DESIGN-E2 §6.1 (owner defaults), contract §5]
size_owner: "DECISIONS (config/schema/decisions.ex 62; config.ex 1,471 — accessor lines only) + DOCS (configuration.md)"
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

- Blocked by **DESIGN-E2 §6.1**: Kevin approves or changes the three defaults. The schema
  and docs can be written now; the default literals are a one-line change after approval.
- No predecessors. May run concurrently with C2-T01, C2-T02.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/config/schema/decisions.ex` (62 lines): `embedded_schema` with two
  fields, `changeset/2` using `cast/4` with an explicit list.
- `src/lib/aiur/config.ex:1137-1144` builds the supervisor policy from
  `settings!().decisions`.
- `scripts/check-config-docs.py` + `scripts/test-check-config-docs.sh` (AGENTS.md: the
  `lint` job fails when a key is missing from `website/docs-app/reference/configuration.md`).
- Annotated templates: `.aiur/examples/config.example`, `src/examples/workflows/*.yaml`
  (AGENTS.md "Docs ship with the change").

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
2. `config.ex`: accessor next to `:1137-1144`.
3. `website/docs-app/reference/configuration.md`: four entries with defaults and the
   sentence "A Command routed to the Executor moves to you after …".
4. `.aiur/examples/config.example` and the three `src/examples/workflows/*.yaml`: a
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

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/config/decisions_escalation_test.exs
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
