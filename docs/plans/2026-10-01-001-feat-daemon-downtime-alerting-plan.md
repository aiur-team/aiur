---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
created: 2026-10-01
---

# Daemon Downtime Detection and Alerting — Plan

## Summary

Implement a durable daemon downtime detection system where the daemon writes a heartbeat file on startup and periodically (every 5 minutes), and the Executor checks the heartbeat age on boot before connecting. If the heartbeat is stale (older than a configured threshold, default 1 hour), the Executor emits a durable alert to the alert ledger with topic `system.daemon.stopped`.

This solution:
- Catches all failure modes (kill -9, OOM, crash, power loss) via absence-based detection
- Requires no external tools (systemd, cron) or daemon-side monitoring
- Uses existing alert infrastructure for durable, operator-visible alerts
- Survives Executor restarts and is checkable offline

## Goal Capsule

**Objective:** Stop silent daemon downtime and surface alerts when the daemon has not been running.

**Product authority:** Issue #2764 — 4.6-day downtime went unnoticed because there was no alert mechanism for a stopped daemon.

**Open blockers:** None. Brainstorm resolved the approach (heartbeat file + Executor boot check + alert ledger).

---

## Problem Frame

The Khala Aiur daemon stopped on 2026-09-20 at 03:20Z and did not restart until 2026-09-24 18:48Z — 4.6 days of downtime with **zero alerts**. The operator discovered it manually by reading log directory names. Every other failure mode (blocked agent, red CI, exhausted credentials) raises an alert; a stopped daemon is the one state with no signal.

**Why existing solutions don't work:**
- Shutdown hook: Cannot fire on kill -9, OOM, or power loss
- Daemon-side monitoring: Cannot alert when the daemon is stopped (no process to run it)
- Cron/systemd: Adds external tooling dependencies and operational complexity

**Constraint:** The solution must detect all failure modes and must not depend on the daemon being alive.

---

## Requirements

1. **Durable alert on daemon downtime:** When the Executor detects the daemon heartbeat is stale, emit an alert to the persistent alert ledger with topic `system.daemon.stopped` so the operator sees it in the alert feed.

2. **Heartbeat write on daemon start and periodically:** Daemon writes a timestamp file (`<repo-state>/executor/<repo>.daemon-heartbeat`) on boot and refreshes it every 5 minutes.

3. **Executor boot-time check:** When the Executor CLI starts, it checks the heartbeat age. If older than the configured threshold (default 1 hour = 3,600,000 ms), it emits the alert.

4. **Configurable threshold:** Operator can adjust the stale-detection threshold via config key `monitoring.daemon_heartbeat_stale_ms`.

5. **Minimize false positives:** Alert clears automatically when heartbeat refreshes (heartbeat becomes recent again).

6. **Test coverage:** Test heartbeat write, stale detection, alert emission, and alert clearing.

---

## Key Technical Decisions

1. **Heartbeat mechanism: Timestamp file, not event journal** (session-settled: user-directed — chosen over extending `control-lifecycle.json`: simpler for external readers, no JSON parsing needed, avoids polluting durable lifecycle journal with frequent updates)

2. **Check location: Executor boot path, not cron/systemd** (session-settled: user-directed — chosen over external cron/systemd: zero external dependencies, works for local and remote operators, immediate alert when human acts)

3. **Alert destination: Alert ledger only** (session-settled: user-directed — chosen over tracker/push notifications: alert-ledger-only keeps scope bounded; tracker integration can be a follow-up)

4. **Default threshold: 1 hour (3,600,000 ms)** — allows for normal daemon restarts and scheduled maintenance windows while catching multi-day outages.

---

## Implementation Units

### U1. Add Heartbeat File Path Resolution to Aiur.Config.Paths

**Goal:** Provide a canonical function to resolve the daemon heartbeat file path.

**Requirements:** Heartbeat path must be in the project state directory (`<repo-state>/executor/<repo>.daemon-heartbeat`) so it survives daemon restarts and is accessible to the Executor.

**Dependencies:** None.

**Files:**
- `src/lib/aiur/config/paths.ex` (modify)

**Approach:**
- Add a new public function `daemon_heartbeat_path/0 :: Path.t()` that resolves the heartbeat file path
- Follow existing `*_path/0` patterns in the module (e.g., `log_root_dir/0`, `decision_state_dir/0`)
- Use `decision_state_dir/0` as the parent so the file lives in the executor-scoped state directory
- File name: `"#{repo_name()}.daemon-heartbeat"` to match the pattern of other executor-scoped files

**Patterns to follow:**
- Existing `*_path/0` and `repo_name/0` functions in `Aiur.Config.Paths`

**Test scenarios:**
- `daemon_heartbeat_path/0` returns a valid absolute path under the decision state directory
- Path contains the repo name identifier
- Path remains consistent across repeated calls

**Verification:** Function is callable and returns a sensible path without errors.

---

### U2. Create Config Schema for Monitoring Thresholds

**Goal:** Add operator-configurable threshold for daemon heartbeat staleness detection.

**Requirements:** New config key `monitoring.daemon_heartbeat_stale_ms` with default value 3,600,000 ms (1 hour).

**Dependencies:** None.

**Files:**
- `src/lib/aiur/config/schema/monitoring.ex` (create)
- `src/lib/aiur/config.ex` (modify to load schema)
- `src/lib/aiur/config/schema.ex` (modify if needed to integrate new schema)

**Approach:**
- Create `Aiur.Config.Schema.Monitoring` following the Ecto schema pattern used in other schema modules
- Add embedded field `daemon_heartbeat_stale_ms` with type `:integer`, default 3,600,000
- Add validation to ensure the value is positive
- Integrate into the main Config module's schema loading (check how `Aiur.Config.Schema.Observability` is loaded)

**Patterns to follow:**
- `src/lib/aiur/config/schema/observability.ex` — same Ecto embedded schema pattern with integer fields and validations
- `src/lib/aiur/config.ex` — how other schema modules are loaded and accessed

**Test scenarios:**
- Config loads with default value when key is absent
- Config loads custom value when key is present
- Validation rejects non-positive values
- Value can be read via `Aiur.Config.Settings`

**Verification:** Config key is readable and defaults are applied correctly.

---

### U3. Write Daemon Heartbeat on Application Start

**Goal:** Write the initial heartbeat file when the daemon boots.

**Requirements:** Heartbeat file is written before any supervisor is started, so the startup timestamp is captured.

**Dependencies:** U1 (Config.Paths.daemon_heartbeat_path/0).

**Files:**
- `src/lib/aiur/daemon_heartbeat.ex` (create) — new module for heartbeat operations
- `src/lib/aiur.ex` (Aiur.Application.start) — hook the initial write

**Approach:**
- Create `Aiur.DaemonHeartbeat` module with a `write!/0` function that writes current timestamp to the heartbeat file
- Write format: single line with ISO 8601 timestamp (e.g., `2026-10-01T12:34:56.789Z\n`)
- Call `Aiur.DaemonHeartbeat.write!()` early in `Aiur.Application.start/2`, immediately after the daemon lifecycle journal recording (the `record_daemon_start()` call)
- Best-effort: heartbeat write failure must not crash boot — catch and log, continue
- Use file operations that work cross-platform (not POSIX-specific)

**Patterns to follow:**
- `Aiur.DaemonLifecycle` — best-effort pattern with Logger.warning on errors
- Existing timestamp handling (DateTime.utc_now, ISO formatting)

**Test scenarios:**
- Heartbeat file is created with a valid timestamp on write
- File is readable and contains an ISO 8601 timestamp
- Write fails gracefully if the parent directory doesn't exist: create parent directories automatically; if creation fails, log and continue without raising
- Multiple writes overwrite the previous timestamp

**Verification:** Heartbeat file exists after daemon boot with a recent timestamp.

---

### U4. Create DaemonHeartbeatWriter Periodic Worker

**Goal:** Refresh the daemon heartbeat every 5 minutes to keep it current.

**Requirements:** Heartbeat is updated periodically so staleness is detectable if the daemon crashes or hangs.

**Dependencies:** U3 (Aiur.DaemonHeartbeat module).

**Files:**
- `src/lib/aiur/daemon_heartbeat_writer.ex` (create) — GenServer using PeriodicWorker
- `src/lib/aiur.ex` (Aiur.Application) — add to child_specs to start the worker

**Approach:**
- Create `Aiur.DaemonHeartbeatWriter` using `use Aiur.PeriodicWorker`
- Implement `c:tick/1` callback that calls `Aiur.DaemonHeartbeat.write!()`
- Set interval to 5 minutes (300,000 ms)
- Best-effort: tick failures are caught and logged by PeriodicWorker, schedule continues
- Add to Aiur.Application's child specs in the appropriate position (after PubSub, not at boot-critical position)

**Patterns to follow:**
- `Aiur.PeriodicWorker` usage pattern (see `src/lib/aiur/events/ls_remote_ticker.ex`)
- Aiur.Application child_specs ordering (rest_for_one strategy respects order)

**Test scenarios:**
- Worker starts and schedules the first tick
- Tick interval is 5 minutes
- Each tick writes a new heartbeat file
- Tick failures don't crash the worker or stop the schedule
- Heartbeat timestamps advance on each tick

**Verification:** Heartbeat file mtime updates every 5 minutes during a running daemon.

---

### U5. Add DaemonHeartbeatChecker to Executor Boot

**Goal:** Check heartbeat staleness when the Executor starts and emit an alert if the daemon appears down.

**Requirements:** Alert is emitted to the persistent alert ledger so the operator sees it in the alert feed, even if they restart the Executor.

**Dependencies:** U1 (Config.Paths.daemon_heartbeat_path/0), U2 (monitoring config).

**Files:**
- `src/lib/aiur/daemon_heartbeat_checker.ex` (create) — heartbeat check logic and alert emission
- `src/lib/aiur_web/executor_cli.ex` OR equivalent boot path (identify exact location)
- Test files as needed

**Approach:**
- Create `Aiur.DaemonHeartbeatChecker` module with a `check_and_alert!/0` function
- Function logic:
  1. Read heartbeat file if it exists; if not, treat as no heartbeat (assume daemon never ran or very old)
  2. Parse the timestamp from the file
  3. Calculate age: `DateTime.utc_now() - parsed_timestamp`
  4. Get threshold from config (`Aiur.Config.daemon_heartbeat_stale_ms()`)
  5. If age > threshold: emit alert via `Aiur.Alerts.emit_system("system.daemon.stopped", ...)`
  6. If age <= threshold: emit a resolved alert with topic `system.daemon.stopped.resolved` to signal the condition has cleared. The alert ledger will deduplicate and handle state transitions.
- Best-effort: checker failures (missing file, parse errors, config errors) are logged and continue — do not block Executor boot
- Call `Aiur.DaemonHeartbeatChecker.check_and_alert!()` in Executor boot path, after config is loaded but before attempting daemon connection
- Alert message: descriptive, including the age of the heartbeat in human-readable format (e.g., "Daemon heartbeat is 2h0m old (threshold: 1h0m); daemon may have stopped")

**Patterns to follow:**
- Alert emission pattern from `Aiur.BuildGateHoldMonitor` (check, emit, track alerted topic, clear when condition resolves)
- Alert ledger interaction (topic naming: `system.daemon.stopped`)
- Best-effort error handling (catch, log, continue)

**Test scenarios:**
- Checker emits alert when heartbeat is older than threshold
- Checker does not emit alert when heartbeat is recent
- Checker handles missing heartbeat file gracefully (treats as old)
- Checker handles unparseable heartbeat file gracefully
- Checker emits resolved alert when heartbeat transitions from stale to recent
- Alert topic is consistent (`system.daemon.stopped` for stale, `system.daemon.stopped.resolved` for clear)
- Checker is stateless and computes output based solely on current heartbeat age (no internal state affects repeated calls)

**Verification:** Alert appears in alert feed when daemon heartbeat is stale; clears when heartbeat refreshes.

---

### U6. Add Test Coverage for Heartbeat Mechanism

**Goal:** Test heartbeat write, periodic refresh, staleness detection, and alert emission.

**Requirements:** Comprehensive test scenarios covering heartbeat operations, configuration, and Executor boot check.

**Dependencies:** U1, U2, U3, U4, U5.

**Files:**
- `src/test/aiur/daemon_heartbeat_test.exs` (create)
- `src/test/aiur/daemon_heartbeat_writer_test.exs` (create)
- `src/test/aiur/daemon_heartbeat_checker_test.exs` (create)
- `src/test/aiur/config/schema/monitoring_test.exs` (create)

**Approach:**
- **DaemonHeartbeat tests:** file write/read, timestamp formatting, overwrite behavior
- **DaemonHeartbeatWriter tests:** tick scheduling, interval, failure handling, no accumulation
- **DaemonHeartbeatChecker tests:** staleness detection, alert emission/clearing, missing file handling, config threshold
- **Monitoring schema tests:** config loading, validation, defaults
- Use temporary directories for heartbeat files (do not pollute real state)
- Mock time where needed to test age calculations without sleeping
- Use `start_paused?: true` in PeriodicWorker tests to drive ticks manually

**Patterns to follow:**
- Existing test patterns in `src/test/aiur/` (setup/teardown, fixtures, mocking)
- Mocking patterns for DateTime in age-calculation tests

**Test scenarios:** (See individual units above for comprehensive lists)

**Verification:** All tests pass; coverage of heartbeat, periodic refresh, staleness detection, and alert flows.

---

### U7. Update Configuration Documentation

**Goal:** Document the new `monitoring.daemon_heartbeat_stale_ms` config key.

**Requirements:** Config key is documented so operators can find and adjust it.

**Dependencies:** U2 (config schema).

**Files:**
- `website/docs-app/reference/configuration.md` (modify)

**Approach:**
- Add entry for `monitoring.daemon_heartbeat_stale_ms` in the configuration reference
- Include default value (3,600,000 ms / 1 hour)
- Explain purpose: threshold for detecting stale daemon heartbeat
- Include a guidance line on recommended values (e.g., "set higher if you have long planned downtime")
- Match the existing documentation format for similar timeout/interval keys

**Patterns to follow:**
- Existing config documentation entries in `reference/configuration.md`
- Format: key path, type, default, description

**Test scenarios:** (Documentation only; no code tests)

**Verification:** Config key appears in documentation with clear description and default value.

---

## Scope Boundaries

### In Scope

- Daemon heartbeat file write on startup and periodic refresh
- Executor boot-time staleness check
- Alert emission to alert ledger
- Configuration key for threshold
- Test coverage for heartbeat mechanism
- Documentation update

### Out of Scope (Deferred to Follow-Up)

- Investigation of the specific 2026-09-20 03:20Z daemon crash (separate ticket) — the control-lifecycle journal will help; this feature enables future crash analysis
- Tracker (Linear/GitHub) comment integration — scope is alert-ledger-only; tracker notifications can be added in a follow-up PR
- Push notification integration — future enhancement
- Systemd/cron integration — not needed; Executor boot check is sufficient
- Remote or multi-instance monitoring — single-instance Executor model assumed

---

## Existing Patterns & References

- **Periodic worker pattern:** `src/lib/aiur/periodic_worker.ex`, `src/lib/aiur/events/ls_remote_ticker.ex`
- **Alert emission pattern:** `src/lib/aiur/build_gate_hold_monitor.ex`, `Aiur.Alerts` module
- **Config schema pattern:** `src/lib/aiur/config/schema/observability.ex`
- **Path resolution pattern:** `Aiur.Config.Paths`, existing `*_path/0` functions
- **Best-effort error handling:** `Aiur.DaemonLifecycle.record_start/1` (log and continue)

---

## Risks & Mitigations

**Risk: Heartbeat file permissions or ownership issues prevent write on some systems**
- *Mitigation:* Best-effort write with clear logging; no boot crash. Executor check handles missing file gracefully.

**Risk: Executor boot check runs too late if Executor connects to daemon before checking heartbeat**
- *Mitigation:* Place check early in Executor boot, immediately after config load, before daemon connection attempt.

**Risk: False positive alerts if daemon is intentionally paused (e.g., maintenance) for >1 hour**
- *Mitigation:* Configurable threshold allows operators to extend window during planned downtime. Operator can manually clear alert if needed (follow-up: add Executor command to suppress alerts).

**Risk: Heartbeat file staleness is not the same as daemon being unable to serve requests**
- *Mitigation:* This is expected — heartbeat staleness is the only absence-based signal. Daemon health itself (can it respond to requests) is a separate concern and out of scope.

---

## Operational & Rollout Notes

- **Operator action required:** Add `monitoring.daemon_heartbeat_stale_ms: 3600000` to `.aiur/config` if a custom threshold is desired. Default applies if omitted.
- **No migration needed:** Heartbeat check is best-effort; it gracefully handles the absence of a heartbeat file.
- **Monitoring:** Operator can check heartbeat file mtime manually if debugging: `ls -l <repo-state>/executor/<repo>.daemon-heartbeat`
- **Alert clearing:** Alert clears automatically when daemon restarts and heartbeat becomes current.

---

## Definition of Done

- All implementation units complete and merged
- All test scenarios in each unit pass
- Config documentation updated
- No blocking code review findings
- No regressions in existing daemon or Executor functionality
- Alert appears and clears correctly on a live daemon (manual testing: stop daemon, check alert, restart daemon, alert clears)

---

## Verification Contract

**Executor-level:**
- Daemon heartbeat file exists at expected path after startup
- Heartbeat file updates every 5 minutes during normal operation
- Executor boot detects stale heartbeat and emits alert
- Alert topic is `system.daemon.stopped`
- Alert surfaces in `aiur alerts` / dashboard alert feed
- Alert clears when daemon restarts

**Unit-level:** (See test scenarios in each implementation unit)

---

## Sources & Research

- Issue #2764: "A stopped daemon raises no alert: 4.6 days of Khala downtime went unnoticed"
- Brainstorm decision: Heartbeat file + Executor boot check + alert ledger
- Codebase patterns: `Aiur.PeriodicWorker`, `Aiur.Config.Paths`, `Aiur.Alerts`, `Aiur.BuildGateHoldMonitor`
