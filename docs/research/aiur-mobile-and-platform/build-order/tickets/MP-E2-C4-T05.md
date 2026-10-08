---
ticket_id: MP-E2-C4-T05
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: Pass the Codex feature flag when capture is on; report native_question capability
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T00, MP-E2-C4-T04]
prior_units: [U4]
prior_boundaries: [CDX #21]
prior_features: [MP-R7 (MP-R7-C2-T01 delivery_primitives / native_question), MP-R1 (capabilities endpoint)]
prior_findings: [R-Q1, owner item "enable an UnderDevelopment Codex flag in production" (DESIGN-E2)]
size_owner: "CODEX (codex/config.ex 126; codex/app_server_port.ex 287)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T05 — Pass the Codex feature flag when capture is on; report the capability

## Identity and outcome

- Bucket 2, MP-E2, chunk C4.
- **User value:** turning on `decisions.native_capture.codex` is the only step needed; aiur
  launches Codex so the model is actually offered the ask-the-user tool, and every
  surface can tell whether native capture works for this harness.
- **Deliverable:** when the gate is on, the Codex launch command gains a trailing
  `--config features.default_mode_request_user_input=true` (form confirmed by C4-T00); the
  `native_question` capability for codex reports `:in_band_hold` (gate on) or `:none`.
- **Non-goals:** turning the gate on by default (C8-T04, owner decision).

## Dependencies and blockers

- **DESIGN-E2** owner decision on using an `UnderDevelopment` flag (stage confirmed by
  `codex features list`, 0.160.0, 2026-10-06). C4-T00 PASS Q1/Q4. C4-T04 merged.
- MP-R7-C2-T01: if `Aiur.Harness.Capabilities.delivery_primitives/1` exists, set
  `native_question` there; otherwise expose `Aiur.Commands.NativeCapture.capability(:codex)`
  for the MP-R1 capabilities endpoint and the dashboard capability note (DESIGN-E2 §5).

## Verified starting point (`45a290e3`)

- `src/lib/aiur/codex/config.ex:10,20-25` `@default_command "codex app-server"`,
  overridable `codex.command`.
- `src/lib/aiur/codex/app_server_port.ex:187-205` `codex_command/2` builds a **shell
  command string**: `CodexConfig.command()` plus trailing `--config key="value"` pairs via
  `append_config/3`, relying on "codex applies the last `--config` for a key" (comment
  `:187-193`). Note `append_config/3` quotes the value as a TOML **string**.
- `codex app-server --enable <FEATURE>` is documented as equivalent to
  `-c features.<name>=true` (`codex app-server --help`, 0.160.0, read 2026-10-06).
- Tests: `src/test/aiur/codex/app_server_port_test.exs`, `codex/config_test.exs`.

## Chosen design

- In `codex_command/2`, when `Config.decisions_native_capture?(:codex)`:
  append ` --config features.default_mode_request_user_input=true` (TOML **boolean**;
  a new `append_raw_config/2` with a fixed literal — not `append_config/3`, whose quoting
  would produce the string `"true"`). Exact flag form is confirmed by C4-T00 step 2.
- Because it is a trailing `--config`, it also works when the operator set a custom
  `codex.command` that ends in a Codex invocation; a wrapper that does not pass extra
  args to Codex will simply not enable the tool (capability then reports what C4-T00's
  probe sees: no `requestUserInput` ever arrives; documented, not detected).
- Capability: PROPOSED `Aiur.Commands.NativeCapture.capability(:codex)` →
  `%{native_question: :in_band_hold | :none, reason: nil | :gate_off}`; exposed through
  MP-R7-C2-T01's `delivery_primitives` if present, else the MP-R1 capabilities endpoint,
  else only the dashboard capability note (DESIGN-E2 §5 "native capture unavailable").
- Startup failure because a future Codex rejects the key: the existing startup-failure
  classification (`codex/startup_failure.ex`) surfaces it; the operator turns the gate
  off. No automatic retry (keeps the launch path simple; documented in the config entry).

## Implementation steps

1. `codex/app_server_port.ex`: `append_raw_config/2` + one conditional pipe step.
2. `codex/config.ex` or `config.ex`: gate accessor (from C4-T02).
3. Capability function + wiring.
4. Docs: `reference/configuration.md` entry for `decisions.native_capture.codex` states
   the flag, its upstream stage ("under development"), and the custom-command caveat.

## Non-happy paths

- Gate off ⇒ command string byte-identical.
- Codex rejects the key at startup: startup failure surfaced; operator disables the gate.
- Flag on but the model never calls the tool: nothing breaks; no Commands arrive.

## Compatibility and rollout

- Gate off ⇒ argv byte-identical (test). Rollback: remove the gate.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/codex/config_test.exs test/aiur/codex/app_server_port_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `app_server_port_test` "gate off: codex command unchanged" | equals the base string for the same model/effort | gate check |
| "gate on: trailing boolean feature config" | ends with `--config features.default_mode_request_user_input=true` (no quotes around `true`) | step 1 |
| "gate on with model override: feature config still present and last-wins order kept" | both `--config` pairs present | pipe order |
| `native_capture_test` "capability reports gate_off and in_band_hold" | two maps as specified | capability fn |

Mutation check per row. Manual: `aiurdev --test` with the gate on; `ps -o args` of the
codex child shows `--config features.default_mode_request_user_input=true`.

## Completion and handoff

- [ ] Flag passed only when gated; capability reported with reason.
- Docs: `reference/configuration.md`.
- Dependents: C8-T04.
