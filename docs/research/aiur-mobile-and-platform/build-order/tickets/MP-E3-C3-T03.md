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
  MP-R1's capabilities endpoint exists, through the **identity-contract IDs** (Phase D,
  X-15; no new `executor.conversation_read` ID):
  - `executor.conversation`: `proven` → `available`; `untested` → `degraded`, reason
    `unknown`; `unsupported` → `unavailable`, reason `unknown`; no binding →
    `unavailable`, reason `executor_not_managed` (identity §1.4). The internal status atom
    travels as attribute `detail` (for example `detail: "unsupported_cli_version"`), so
    clients that know only the closed reason enum (identity §2.2) still render it.
  - `executor.harness` (`claude | codex`, from the binding) and `executor.session_ref`
    (MP-E4 `SessionRef` of the current session) are filled here; both are absent when
    no binding exists.
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
3. If MP-R1's capability registry exists, provide `executor.conversation`,
   `executor.harness` and `executor.session_ref` with the mapping above (X-15). Test:
   "untested maps to degraded/unknown with detail; no binding maps to
   unavailable/executor_not_managed" (*fails without* the mapping clause).

## Non-happy paths

- Binding detached → `:unknown`/`not_attached` (history still readable from the
  journal; the capability is about live capture).

## Compatibility and rollout

- Read-only projection. Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/capability_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| table test over every row | status + reason | each clause |
| "missing inputs are :unknown, not :proven" | `:unknown` | fallback (mutation: default `:proven` fails) |

## Completion and handoff

- Dependents: MP-E3-C6-T02 (header shows it), MP-N3 (meta-dashboard).
- Docs: MP-E3-C7-T02 lists the statuses.
