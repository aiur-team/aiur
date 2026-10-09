---
title: EXP-X1-6 Capture setting - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x1/brainstorm.md
ticket: EXP-X1-6
complexity: 1
---

# EXP-X1-6 Capture setting - Plan

## Summary

Make the capture setting explicit:

- Capture is on by default, and the user can turn it off.
- No capture is gated by `--debug`.
- The GitHub fact reads get their own sub-switch.
- The UI and docs say clearly when capture is off.
- The "debug telemetry" wording is removed.

## Verified state (origin/main 1c4409e43)

- `observability.telemetry_enabled` is a boolean, default `true` (`src/lib/aiur/config/schema/observability.ex:17`). `Aiur.Config.telemetry_enabled?/1` fails open to `true` (`src/lib/aiur/config.ex:1025-1033`).
- At boot, `Aiur.RunTelemetry.start_boot/0` caches the value (`src/lib/aiur/run_telemetry.ex:24-43`). The supervisor starts only when it is enabled (`src/lib/aiur.ex:41,85,404`). A change needs a restart.
- `--debug` gates the debug log level and durable chat-pane recording only (`website/docs-app/reference/cli.md:50,63`; `src/lib/aiur/log_file.ex:107-157`). It gates no telemetry or analytics. **No capture gate exists to remove.**
- Two places still call capture "debug": the Writer moduledoc ("this debug-only path", `src/lib/aiur/run_telemetry/writer.ex:20`), and the HTML dashboard eyebrow "Aiur / debug telemetry" (`src/lib/aiur/run_telemetry/dashboard.ex:154`).
- The config docs list the setting (`website/docs-app/reference/configuration.md:679`).

Requirements: R5 (brainstorm). Decisions KD1 and KD8.

## Key Technical Decisions

- **KTD1. Keep `observability.telemetry_enabled` as the master switch** (session-settled: operator; the brief chose a user setting, default on). We do not rename it. Reason: renaming breaks existing configs, and the name already says what it does.
- **KTD2. Add `observability.capture_github_facts`** (default `true`). It gates only the EXP-X1-4 reads. It has no effect when the master switch is off.
- **KTD3. Show the capture state.**
  - `/analytics` shows a one-line notice when telemetry is disabled: "Analytics capture is off (observability.telemetry_enabled: false). Experiments will have no data for this period." Today the page shows "missing telemetry" with no reason.
  - The disabled period is also recorded: on boot with capture off, the daemon writes `{boot_id, started_at, telemetry_enabled: false}` to `<state-node>/analytics/capture-gaps.ndjson`. This is the only write it makes. X4 and X6 can then mark a window as "not captured", instead of reading it as "no work happened". Reason: a silent gap would bias before/after comparisons.
- **KTD4. Wording.** "Debug" goes away from capture surfaces. The CLI reference for `--debug` gains one line: "Analytics capture does not depend on `--debug`."

## Implementation Units

### U1. Config field and docs

**Files:** `src/lib/aiur/config/schema/observability.ex`, `src/lib/aiur/config.ex` (`capture_github_facts?/1`, which fails open to true), `website/docs-app/reference/configuration.md`, `website/docs-app/reference/cli.md` (the `--debug` row), `src/test/aiur/config_test.exs` (or the closest observability test).
**Test scenarios:**
- A default config gives `capture_github_facts?() == true`.
- An explicit `false` gives false.
- An unreadable config gives true (fail open, like `telemetry_enabled?`).
- `scripts/check-config-docs.py` passes with the new row.

### U2. Capture-gap marker and analytics notice

**Files:** `src/lib/aiur.ex` (on boot with telemetry off, call `Aiur.RunTelemetry.CaptureGaps.record/1`, best-effort), `src/lib/aiur/run_telemetry/capture_gaps.ex` (new), `src/lib/aiur_web/live/analytics_live.ex` (the notice), `src/test/aiur/run_telemetry/capture_gaps_test.exs`, `src/test/aiur_web/live/analytics_live_test.exs`.
**Test scenarios:**
- A boot with telemetry disabled appends one gap line with the boot id.
- A boot with telemetry enabled appends nothing.
- A write failure is logged, and boot continues.
- The analytics page with telemetry disabled renders the notice text. With telemetry enabled, there is no notice.

### U3. Remove debug framing

**Files:** `src/lib/aiur/run_telemetry/writer.ex` (moduledoc line 20), `src/lib/aiur/run_telemetry/dashboard.ex` (line 154 eyebrow becomes "Aiur / run telemetry"), `src/test/aiur/run_telemetry/dashboard_test.exs`, if it asserts the eyebrow.
**Test expectation:** The dashboard test asserts the new eyebrow. Otherwise none, because the change is wording only.

## Interfaces offered to other areas

- X2, X4, X6: `capture-gaps.ndjson` rows mark windows as not captured.
- X1-4: reads `capture_github_facts?/0`.
