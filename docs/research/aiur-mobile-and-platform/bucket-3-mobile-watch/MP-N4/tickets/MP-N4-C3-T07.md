---
ticket_id: MP-N4-C3-T07
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Machine-side push status line in `aiur status` / `aiur mobile status` and setup copy
status: blocked
blocked_by: [DESIGN-N4, DESIGN-N2, MP-N4-C3-T04, MP-N2-C3-T03]
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
one line in `aiur status` and a `push` block in `aiur mobile status [--json]` (MP-N2-C3-T03),
covering the DESIGN-N4 §4 machine-side states: notifications off, relay not configured
(no registered device), relay degraded with `since`, devices with push `gone`, and
"push deregistration pending" after a revoke.

## Dependencies and blockers

- **Blocked on DESIGN-N4 content**: §2 "Setup: notifications off / relay not configured /
  permission denied / force-stopped (Android) … in-app banners and the machine-side `aiur`
  status line" — the wording and which states appear in `aiur status` versus only in
  `aiur mobile status` are owner decisions. DESIGN-N2 owns `aiur mobile status` layout.
- C3-T04 (capability data), MP-N2-C3-T03 (`aiur mobile status --json`).

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

Build the structure now; only the human-readable strings wait for DESIGN-N4 §2 "Setup"
and §4 states (put them in one module so the approved copy is a one-file change).

1. `src/lib/aiur/push/status_report.ex` (PROPOSED, in the push package): pure
   `build(capability, devices_snapshot, now) :: map` returning the JSON block above, and
   `line(map) :: String.t()` for text. State keys (one per DESIGN-N4 §4 machine-side
   state): `:off` (`unavailable/disabled`), `:not_configured`, `:no_devices`
   (`available`, `devices.registered == 0`), `:degraded` (with `since` and age),
   `:devices_gone`, `:deregistration_pending`, `:keys_lost` (any device row with
   `push_health: keys_lost`, contract §7; Phase D M6 — "phone notifications broken"),
   `:unknown`. Copy lives in `src/lib/aiur/push/status_copy.ex` with placeholder strings
   marked `# DESIGN-N4 §4 pending`.
2. `print_status_report/3` (`agent_control_cli.ex:189`) calls `line/1` when the status
   payload carries a `push` key; absent key → no line.
3. MP-N2-C3-T03's `aiur mobile status --json` embeds `build/3` under `"push"`, plus per
   device `push_health`.
4. Docs: `website/docs-app/reference/cli.md` (`aiur status`, `aiur mobile status` push
   block and every state) and `website/docs-app/guide/` notifications page (what
   "phone notifications broken" means and the re-pair fix).

## Non-happy paths

- Daemon unreachable: `aiur status` already reports that; the push line is omitted, not
  shown as "off" (unknown ≠ off).
- Capability `unknown` → rendered as unknown with age, never as `available` or `off`.
- A device row with `push_health: keys_lost` while the capability is `available` → the
  line still shows `:keys_lost` (a per-device fault is not hidden by an overall OK).

## Compatibility and rollout

Additive output. Scripts parsing `aiur status` text are unsupported; JSON is additive.

## Verification

`src/test/aiur/push/status_report_test.exs` (PROPOSED) and
`src/test/aiur/agent_control_cli_test.exs` (exists at `45a290e3`). Test names carry the
DESIGN-N4 §4 state key:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"§4 relay degraded: line and JSON carry since and age_ms"` | `state: degraded`, `since`, `age_ms` present and rendered | drop `age_ms` from the line (AGENTS.md computed-age rule) |
| `"§4 notifications off: disabled renders :off"` | `:off` | map `disabled` to `:not_configured` |
| `"§4 unknown is not printed as off"` | `:unknown` with age | replace the unknown branch with the `disabled` rendering |
| `"§4 phone notifications broken: keys_lost device surfaces"` | `:keys_lost`, device id fingerprint only | ignore `push_health` |
| `"§4 deregistration pending after revoke"` | `deregistration_pending: 1` | count only `gone` |
| `"no relay URL, handle or secret in output"` | sentinel strings absent from JSON and text | print the registration row |
| `"status prints push line"` (agent_control_cli_test) | one line when `push` present, none when absent | always print |

Commands (isolated HOME, tokens unset):
`env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/push/status_report_test.exs test/aiur/agent_control_cli_test.exs`.
Mutation check: revert each "Must fail without" hunk in a worktree, confirm the named
test fails, report the command in the PR. Manual: `aiurdev --bg`, then `aiurdev status`,
observe the line (AGENTS.md manual testing applies to CLI output via the real launcher).

## Completion and handoff

- [ ] DESIGN-N4 approved copy replaces the placeholders in `status_copy.ex` verbatim;
  `reference/cli.md` and the guide page updated.
- Dependents: MP-N4-C7 (setup-state checks).
