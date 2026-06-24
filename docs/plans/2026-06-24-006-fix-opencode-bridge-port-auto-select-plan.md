---
title: "fix: Auto-select opencode bridge port"
type: fix
date: 2026-06-24
---

# fix: Auto-select opencode bridge port

## Summary

Aiur should keep the default opencode bridge port when it is available, automatically move to the next free local port when only the built-in default is in play, and preserve explicit `AIUR_OPENCODE_BRIDGE_PORT` or workflow `opencode.bridge_port` pins.

---

## Problem Frame

Two local checkouts can both reach application boot with the default bridge port `4097`. Today the second checkout fails inside Bandit with `:eaddrinuse`, which reads like a broken Aiur node instead of a local port collision.

---

## Requirements

- R1. When the effective bridge port comes from Aiur's built-in default and that port is occupied, startup selects a nearby free port and uses it for the bridge and downstream opencode workspace config.
- R2. When `AIUR_OPENCODE_BRIDGE_PORT` or workflow `opencode.bridge_port` supplies the port, Aiur does not silently substitute another port.
- R3. When an explicit port is occupied, startup reports a clear message with the occupied port, best-effort owning process details, and an `AIUR_OPENCODE_BRIDGE_PORT=<port>` workaround.
- R4. Tests cover occupied-default selection and explicit override behavior without relying on a hard-coded host port being free on the developer machine.

---

## Key Technical Decisions

- **Resolve at the bridge boundary:** The bridge supervisor is the first place that knows the effective host and can safely probe TCP availability before Bandit starts.
- **Track port source, not only port value:** Config must distinguish `default` from `env` and `workflow` even when all resolve to `4097`, because only the default may auto-select.
- **Propagate the selected default through app env:** When auto-selection picks another port, write it to `:opencode_bridge_port_override` before the bridge starts so later `Config.bridge_port/0` calls build matching opencode URLs.

---

## Implementation Units

### U1. Source-aware bridge port config

- **Goal:** Expose whether the bridge port came from application env, `AIUR_OPENCODE_BRIDGE_PORT`, workflow YAML, or the built-in default.
- **Files:** Modify `src/lib/aiur/opencode/config.ex`; test in `src/test/aiur/opencode/config_test.exs`.
- **Approach:** Keep `Config.bridge_port/0` as the public value API and add a source-returning API for startup selection. Read raw workflow YAML through `Aiur.Workflow.current/0` so schema defaults do not make an omitted value look explicit.
- **Patterns to follow:** Existing `section_value/1` and env parsing in `src/lib/aiur/opencode/config.ex`.
- **Test scenarios:** Env override wins over workflow config; workflow config is reported as explicit; omitted workflow config reports the built-in default.
- **Verification:** Existing config tests still pass and new source tests pin precedence.

### U2. Default-only port auto-selection

- **Goal:** Probe the effective bridge host/port before Bandit starts, select a nearby free port for default-source collisions, and fail explicitly for pinned collisions.
- **Files:** Create `src/lib/aiur/opencode/bridge_port.ex`; modify `src/lib/aiur/opencode/bridge_supervisor.ex`; test in `src/test/aiur/opencode/bridge_port_test.exs`.
- **Approach:** Use a short-lived TCP listen probe on the configured host. For default-source ports, scan upward for a free port and return it. For explicit-source ports, return an error string that includes the owner lookup and workaround.
- **Patterns to follow:** Keep `BridgeSupervisor` small like the existing child-spec construction; isolate testable logic in a pure-ish helper module.
- **Test scenarios:** Occupied default port selects the next available port; free default port stays unchanged; occupied env/config source returns an actionable error; port `0` is passed through for tests.
- **Verification:** Focused tests exercise real local sockets without fixed port assumptions.

### U3. Preserve launch propagation and validation

- **Goal:** Confirm the selected port reaches the bridge, `Config.bridge_port/0`, and opencode workspace URL generation.
- **Files:** Modify `.aiur/config`; modify or add focused tests under `src/test/aiur/opencode/`; optionally adjust `src/test/scripts_aiurdev_test.exs` only if the script layer also needs derived-port behavior.
- **Approach:** Assert `BridgeSupervisor` writes the selected default into application env before building its Bandit child spec, and keep the existing engine export test for explicit env propagation.
- **Patterns to follow:** Existing non-starting config tests and supervisor child-spec tests where available.
- **Test scenarios:** After default auto-selection, `Config.bridge_port/0` returns the selected port; explicit env/config does not mutate to another value.
- **Verification:** Targeted opencode tests pass, then broader compile/lint/manual CLI checks run before PR.

---

## Scope Boundaries

- Do not change opencode-serve slot port allocation; it already lets opencode pick its own port.
- Do not change dashboard port selection or tmux session identity.
- Do not silently override user-pinned bridge ports.

---

## Risks & Dependencies

- TCP preflight has a small time-of-check/time-of-use race; Bandit remains the final authority if another process binds between probe and startup.
- Owner lookup depends on local tools such as `lsof`; the failure message must remain useful when owner details are unavailable.

---

## Sources / Research

- `scripts/aiurdev` already exports `AIUR_OPENCODE_BRIDGE_PORT` for agent workspace sandboxes.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` re-exports `AIUR_OPENCODE_BRIDGE_PORT` into the tmux-launched BEAM.
- `src/lib/aiur/opencode/config.ex` currently gives app env, `AIUR_OPENCODE_BRIDGE_PORT`, workflow config, then default precedence.
- `src/lib/aiur/opencode/bridge_supervisor.ex` is the Bandit bridge listener owner.
