---
ticket_id: MP-N4-C3-T07
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Machine-side push status line in `aiur status` / `aiur mobile status` and setup copy
status: blocked
blocked_by: [DESIGN-N4, DESIGN-N2, MP-N4-C3-T04, MP-N2-C3-T3]
prior_units: []
prior_boundaries: [control-cli (launcher/engine), new #41 candidate push-relay]
prior_features: [MP-N2]
prior_findings: [AGENTS.md "If a surface computes an age, it renders the age"]
size_owner: aiur-engine.sh / agent_control_cli.ex owners per U8 ledger
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T07 — Push status line and setup copy

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Show the `push` capability to the operator on the machine:
one line in `aiur status` and a `push` block in `aiur mobile status [--json]` (MP-N2-C3-T3),
covering the DESIGN-N4 §4 machine-side states: notifications off, relay not configured
(no registered device), relay degraded with `since`, devices with push `gone`, and
"push deregistration pending" after a revoke.

## Dependencies and blockers

- **Blocked on DESIGN-N4 content**: §2 "Setup: notifications off / relay not configured /
  permission denied / force-stopped (Android) … in-app banners and the machine-side `aiur`
  status line" — the wording and which states appear in `aiur status` versus only in
  `aiur mobile status` are owner decisions. DESIGN-N2 owns `aiur mobile status` layout.
- C3-T04 (capability data), MP-N2-C3-T3 (`aiur mobile status --json`).

## Verified starting point

- `aiur status` → `cmd_status` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:2612`,
  dispatch at `:4110`) → `Aiur.AgentControlCli.status/1`
  (`src/lib/aiur/agent_control_cli.ex:100`), which prints load then
  `print_status_report/3` (`:189`).
- AGENTS.md: a surface that computes an age renders it (`observed_at`, `age_ms`,
  `freshness`).

## Chosen design (structure fixed; copy pending DESIGN-N4)

- JSON (`aiur mobile status --json`): `"push": {"state", "reason", "since", "observed_at",
  "age_ms", "devices": {"registered": n, "gone": n, "deregistration_pending": n}}`.
- Text: one line; exact copy from DESIGN-N4 D-* answers.
- No relay URL, handle or secret in output.

## Implementation steps

After approval: add the JSON block (MP-N2 owner merges layout), add the line in
`print_status_report/3` or a sibling printer, update `website/docs-app/reference/cli.md`
for both commands (AGENTS.md CLI-output rule: documented behaviour changes).

## Non-happy paths

- Daemon unreachable: `aiur status` already reports that; the push line is omitted, not
  shown as "off" (unknown ≠ off).
- Capability `unknown` → rendered as unknown with age, never as `available`.

## Compatibility and rollout

Additive output. Scripts parsing `aiur status` text are unsupported; JSON is additive.

## Verification

`src/test/aiur/agent_control_cli_test.exs` (exists at `45a290e3`) gains:
`"status prints push degraded with age"` (fixture capability) and
`"push unknown is not printed as off"` — the latter must fail if the unknown branch is
replaced with the `disabled` rendering (AGENTS.md unknown-path rule). Manual: `aiurdev
--bg`, then `aiurdev status`, observe the line (AGENTS.md manual testing applies to CLI
output via the real launcher).

Commands (from `src/`): `mise exec -- mix test test/aiur/agent_control_cli_test.exs`.

## Completion and handoff

- [ ] DESIGN-N4 approved copy used verbatim; `reference/cli.md` updated.
- Dependents: MP-N4-C7 (setup-state checks).
