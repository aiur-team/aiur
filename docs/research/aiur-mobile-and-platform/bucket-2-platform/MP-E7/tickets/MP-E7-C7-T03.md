---
ticket_id: MP-E7-C7-T03
feature_id: MP-E7
chunk_id: MP-E7-C7
bucket: 2-platform
title: "CLI get/set listener mode and POST /api/v1/:id/listen-mode (names from DESIGN-E7)"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C2-T01, MP-E7-C2-T03]
repo: aiur-team/aiur
wave: 4
prior_units: [U9]
prior_boundaries: [CTL, WEB]
prior_features: []
prior_findings: [phase-b-reconciliation RC-05 (C2 surfaces moved to C7)]
size_owner: CTL (agent_control_cli.ex is 3,482 lines — new module only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C7-T03 — Operator control surfaces: CLI and HTTP

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C7. Moved here from
  MP-E7-C2 (former C2-T3) because the command name and output are DESIGN-E7
  §1.5 decisions; C2 keeps only the internal API.
- **User value:** the operator (or a script / the Executor, if E7-D3 allows)
  reads and sets an agent's listener mode from the CLI and HTTP API, and
  `aiur message` says which mode applied.
- **Deliverable:**
  1. A CLI subcommand (name per DESIGN-E7 §1.5; placeholder here:
     `aiur listen-mode <ticket> [steer|sync|async] [--expected-version N]
     [--json]`) via the shared engine, handled by a new
     `Aiur.ListenModeCli` module (PROPOSED).
  2. `POST /api/v1/:issue_identifier/listen-mode` (path fixed by the MP-E7
     plan) with body `{mode, expected_version, idempotency_key}` →
     `200 {requested, effective, effective_reason, version, actor}` |
     `409 {error: "mode_conflict", current: …}` | `422` invalid mode |
     `404` unknown ticket; `GET` same path returns the record.
  3. `aiur message` output adds the mode under which the message was
     accepted (copy per DESIGN-E7).
- **Non-goals:** dashboard/TUI (C7-T01/T02); Executor authority (E7-D3)
  beyond rejecting `actor: executor` unless DESIGN-E7 allows it.

## Dependencies and blockers

- **DESIGN-E7 §1.5** (command name, output, `aiur message` wording) and
  **E7-D3** (who may set).
- **MP-E7-C2-T01** (ModeStore CAS write), **MP-E7-C2-T03** (internal
  control API and the `listener` read map).
- **May run concurrently with** C7-T02, C7-T05; **C7-T01 depends on it**.

## Verified starting point (at `45a290e3`)

- Router write scope: `[:dashboard_auth, :api_write, :require_writable]` with
  `post("/api/v1/:issue_identifier/messages", …)` and a `method_not_allowed`
  match (`aiur_web/router.ex:152-159`). The new route goes in the same scope
  (contract §12: same authority as sending a message).
- Shared engine dispatches subcommands; `message)` case at
  `packaging/npm/aiur-cli/libexec/aiur-engine.sh:4222`; Elixir side
  `AgentControlCli.message/3` (`agent_control_cli.ex:1363-1372`), output
  helpers `report_message_outcome/3` (`:1466-1476`).
- CLI docs table: `website/docs-app/reference/cli.md:117-127`.
- Tests: `src/test/aiur/agent_control_cli_test.exs`; controller tests under
  `src/test/aiur_web/controllers/`; launcher tests
  `packaging/npm/aiur-cli/test/launcher.test.mjs` (`bun test`).

## Chosen design

- HTTP controller: new `AiurWeb.ListenModeController` (PROPOSED), not the
  oversized observability controller. Idempotency: same
  `idempotency_key` + same body → first result.
- CLI: engine case → RPC to `Aiur.ListenModeCli.run/2`; without a mode arg it
  prints the record; with one it writes. `--json` prints the record verbatim
  plus `observed_at`/`age_ms` (AGENTS.md: CLI emits freshness fields).
  Conflict exits non-zero (code per DESIGN-E7; proposal 3) and prints the
  current record.
- `aiur message`: `report_message_outcome/3` appends the accepted mode from
  the send result (C3-T04 receipt) — under `:legacy` routing it prints
  nothing new.

## Implementation steps

1. Controller + route + `method_not_allowed` match.
2. `Aiur.ListenModeCli` + engine dispatch case + help text.
3. `aiur message` wording.
4. Tests. 5. `reference/cli.md` rows (this PR; AGENTS.md docs rule).

## Non-happy paths

- Read-only dashboard: `require_writable` refuses as for `messages`.
- Agent not running: write still allowed (mode is per ticket run, contract §5).
- Unknown ticket: `404`.
- RPC timeout: CLI prints "outcome unknown" and the idempotency key to retry
  (pattern `cli.md:127`).

## Compatibility and rollout

New command + route; additive. Under `:legacy` routing the record is stored
but delivery ignores it — output must say so (copy per DESIGN-E7) so the
operator is not misled.

## Verification

- `listen_mode_controller_test.exs`: `"stale expected_version returns 409
  with current record"` — mutation: drop the CAS check → fails;
  `"same idempotency key returns first result"`; `"invalid mode 422"`;
  `"read-only dashboard refuses"`.
- `listen_mode_cli_test.exs`: `"set prints requested and effective with
  reason when they differ"`; `"--json includes observed_at and age_ms"` —
  mutation: omit `age_ms` → fails.
- `agent_control_cli_test.exs`: `"message under listener routing names the
  mode"`; `"message under legacy routing output unchanged"` (guard).
- `bun test` in `packaging/npm/aiur-cli`: launcher routes the new subcommand.
- Commands: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test test/aiur_web/controllers test/aiur/agent_control_cli_test.exs`;
  `env -C packaging/npm/aiur-cli bun test`.
- Manual: `scripts/aiurdev listen-mode <n> async`, then `scripts/aiurdev
  message <n> "x"` and read the output.

## Completion and handoff

- [ ] `website/docs-app/reference/cli.md` rows for the command and changed
  `aiur message` output (required in this PR).
- Dependents: C7-T01, C7-T02, MP-E3-C5 (Executor mode, if DESIGN-E7 §1.7).
