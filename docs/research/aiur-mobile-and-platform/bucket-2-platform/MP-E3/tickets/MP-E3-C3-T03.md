---
ticket_id: MP-E3-C3-T03
feature_id: MP-E3
chunk_id: MP-E3-C3
bucket: 2-platform
title: "Executor read capability record: proven | untested | unsupported per harness and version"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C2-T02, MP-E3-C3-T02]
prior_units: [U3]
prior_boundaries: [EXE]
prior_features: [MP-R1 (capabilities endpoint, R1-C2/C3)]
prior_findings: [plan acceptance 2; AGENTS.md "collapsed causes"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C3-T03 — Executor read capability

## Identity and outcome

- Bucket 2 · MP-E3 · C3 · T03.
- **User value:** every surface (dashboard, CLI, phone) can say plainly whether
  aiur can read this Executor's conversation, and why not.
- **Deliverable:** `Aiur.Executor.Capability.read/0 :: %{harness, cli_version,
  status: :proven | :untested | :unsupported | :unknown, reason, tested_range,
  observed_at}` derived from the binding, the drift counters (C2-T02) and the
  extractor's tested ranges; exposed in `executor-session --json` and, when
  MP-R1's capabilities endpoint exists, as `executor.conversation_read`.
- **Non-goals:** capability for sending (that is MP-E7's effective mode).

## Dependencies and blockers

- DESIGN-E3 (copy for each status). MP-E3-C2-T02, MP-E3-C3-T02.
- Optional: MP-R1-C2/C3 capabilities endpoint (add the field only if it exists).

## Verified starting point

- No capability record exists for the Executor at `45a290e3`; the roster only
  knows wake-stream liveness (`src/lib/aiur/executor/roster.ex:1-41`).
- Tested ranges live in the extractors (C2-T02 Claude, C3-T02 Codex).

## Chosen design

| Inputs | `status` | `reason` |
| --- | --- | --- |
| no binding | `:unknown` | `not_attached` |
| binding, no hook yet | `:unknown` | `awaiting_first_hook` |
| harness codex, reader not shipped / refused layout | `:unsupported` | `codex_reader_unavailable` / `layout_unknown` |
| version in tested range, no drift alert | `:proven` | nil |
| version outside range or drift latched | `:untested` | `version_untested` / `format_drift` |

- Unknown inputs map to `:unknown`, never to `:proven` or `:unsupported`
  (AGENTS.md collapsed-cause rule).

## Implementation steps

1. Pure `Capability.read/1` over a snapshot; thin `read/0` wrapper.
2. Add to `executor-session --json` (C1-T03) and the status snapshot (C4-T05).
3. If MP-R1's capability registry exists, register `executor.conversation_read`.

## Non-happy paths

- Binding detached → `:unknown`/`not_attached` (history still readable from the
  journal; the capability is about live capture).

## Compatibility and rollout

- Read-only projection. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/executor/capability_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| table test over every row | status + reason | each clause |
| "missing inputs are :unknown, not :proven" | `:unknown` | fallback (mutation: default `:proven` fails) |

## Completion and handoff

- Dependents: MP-E3-C6-T02 (header shows it), MP-N3 (meta-dashboard).
- Docs: MP-E3-C7-T02 lists the statuses.
