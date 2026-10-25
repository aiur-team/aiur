import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

test("restart boots the saved release after a failed refresh and retains the handoff", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-restart-rollback-"));
  const previous = path.join(root, "release");
  const ledger = path.join(root, "alert-ledger.jsonl");
  const ledgerFile = path.join(root, "ledger-path");
  const events = path.join(root, "events");
  mkdirSync(path.join(previous, "bin"), { recursive: true });
  writeFileSync(path.join(previous, "AIUR_BUILD_STAMP"), "source_sha=previous-sha\n");
  writeFileSync(path.join(previous, "bin", "aiur"), "#!/bin/sh\n");
  chmodSync(path.join(previous, "bin", "aiur"), 0o755);
  writeFileSync(ledgerFile, `${ledger}\n`);
  writeFileSync(ledger, "");
  const script = String.raw`
source "$1"
AIUR_RELEASE_DIR="$2"
AIUR_ALERT_LEDGER_PATH_FILE="$3"
AIUR_BG_STATE_DIR="$TMPDIR/state"
export AIUR_RELEASE_DIR AIUR_ALERT_LEDGER_PATH_FILE
export AIUR_BG_STATE_DIR
AIUR_RESTART_BUILD_CMD=': '
AIUR_RESTART_HANDOFF_ID=''
prepare_restart_handoff() { AIUR_RESTART_HANDOFF_ID='handoff-123'; export AIUR_RESTART_HANDOFF_ID; }
cmd_stop() { :; }
resolve_release() { :; }
probe_control_liveness() { printf down; }
run_control_rpc() { printf 'handoff adopted'; }
TEST_EVENTS="$4"
TEST_BOOT_CAPTURE="$TMPDIR/boot.out.log"
TEST_LEDGER="$TMPDIR/alert-ledger.jsonl"
report_restart_handoff() { printf 'reported:%s\n' "$AIUR_RESTART_HANDOFF_ID" >>"$TEST_EVENTS"; }
AIUR_RESTART_START_ATTEMPTS=1
AIUR_RESTART_RETRY_DELAY_SECONDS=0
dispatch_run() {
  printf '%s|%s|%s\n' "$AIUR_RELEASE_DIR" "$*" "$AIUR_RESTART_HANDOFF_ID" >>"$TEST_EVENTS"
  case "$AIUR_RELEASE_DIR" in
    *aiur-previous-release.*) return 0 ;;
    *)
      echo 'new release panic: missing module' >"$TEST_BOOT_CAPTURE"
      printf '%s\n' "$TEST_LEDGER" >"$AIUR_ALERT_LEDGER_PATH_FILE"
      preserve_restart_failure_artifacts "$TEST_BOOT_CAPTURE" "$AIUR_ALERT_LEDGER_PATH_FILE"
      exit 1
      ;;
  esac
}
cmd_restart --keep-agents
`;
  const result = spawnSync("bash", ["-c", script, "restart-test", engine, previous, ledgerFile, events], {
    encoding: "utf8",
    env: { ...process.env, TMPDIR: root },
  });

  try {
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("rolled back to previous-sha: new release failed with new release panic: missing module");
    const starts = readFileSync(events, "utf8").trim().split("\n");
    expect(starts).toHaveLength(3);
    expect(starts[0]).toContain("handoff-123");
    expect(starts[0]).toContain("--bg");
    expect(starts[0]).not.toContain("aiur-previous-release.");
    expect(starts[1]).toContain("handoff-123");
    expect(starts[1]).toContain("--bg");
    expect(starts[1]).toContain("aiur-previous-release.");
    expect(starts[2]).toBe("reported:handoff-123");
    const alert = readFileSync(ledger, "utf8");
    expect(alert).toContain('"severity":"critical"');
    expect(alert).toContain('"name":"system.restart.rollback"');
    expect(alert).toContain("previous-sha");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("run_session preserves boot output and alert path before deleting startup tempfiles", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-restart-capture-"));
  const sourceCapture = path.join(root, "startup.capture");
  const sourceLedgerPath = path.join(root, "alert-ledger-path");
  const preservedCapture = path.join(root, "restart.capture");
  const preservedLedgerPath = path.join(root, "restart.alert-path");
  const logs = path.join(root, "logs");
  const config = path.join(root, "tmux.conf");
  const tmuxDir = path.join(root, "bin");
  mkdirSync(tmuxDir);
  writeFileSync(config, "");
  writeFileSync(sourceLedgerPath, `${path.join(logs, "alerts.ndjson")}\n`);
  writeFileSync(path.join(tmuxDir, "tmux"), "#!/bin/sh\nexit 1\n");
  chmodSync(path.join(tmuxDir, "tmux"), 0o755);

  const script = String.raw`
source "$1"
AIUR_BG_STATE_DIR="$TMPDIR/state"
AIUR_ALERT_LEDGER_PATH_FILE="$2"
AIUR_RESTART_STARTUP_CAPTURE="$3"
AIUR_RESTART_ALERT_PATH_CAPTURE="$4"
AIUR_TMUX_CONF="$5"
AIUR_RELEASE_NODE='aiur-test@127.0.0.1'
export AIUR_BG_STATE_DIR AIUR_ALERT_LEDGER_PATH_FILE AIUR_RESTART_STARTUP_CAPTURE AIUR_RESTART_ALERT_PATH_CAPTURE AIUR_TMUX_CONF AIUR_RELEASE_NODE
TEST_SOURCE_CAPTURE="$6"
resolve_release() { :; }
aiur_resolve_identity() { :; }
prepare_distribution() { :; }
aiur_launch_lock_path() { printf '%s/launch.lock' "$TMPDIR"; }
acquire_aiur_launch_lock() { return 0; }
release_aiur_launch_lock() { :; }
run_session_prepare_env() { startup_capture="$TEST_SOURCE_CAPTURE"; launch_tempfiles=("$startup_capture" "$AIUR_ALERT_LEDGER_PATH_FILE"); }
run_session_write_pane_launcher() { :; }
run_session_reclaim_stale_nodes() { :; }
sweep_stale_tmp_artifacts() { :; }
sweep_orphan_test_private_dirs() { :; }
run_session_start_tmux() { printf 'new release panic: missing module\n' >"$startup_capture"; }
wait_for_session_startup() { return 1; }
print_config_status() { :; }
record_new_crash_dump_alert() { :; }
reap_aiur_agents() { :; }
kill_beams_matching() { :; }
run_session background
`;
  const result = spawnSync("bash", ["-c", script, "capture-test", engine, sourceLedgerPath, preservedCapture, preservedLedgerPath, config, sourceCapture], {
    encoding: "utf8",
    env: { ...process.env, TMPDIR: root, PATH: `${tmuxDir}:${process.env.PATH}` },
  });

  try {
    expect(result.status).toBe(1);
    expect(readFileSync(preservedCapture, "utf8")).toContain("new release panic: missing module");
    expect(readFileSync(preservedLedgerPath, "utf8")).toBe(`${path.join(logs, "alerts.ndjson")}\n`);
    expect(() => readFileSync(sourceCapture, "utf8")).toThrow();
    expect(() => readFileSync(sourceLedgerPath, "utf8")).toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("restart removes the saved release when stop fails before startup", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-restart-stop-cleanup-"));
  const release = path.join(root, "release");
  mkdirSync(path.join(release, "bin"), { recursive: true });
  writeFileSync(path.join(release, "AIUR_BUILD_STAMP"), "source_sha=previous-sha\n");
  writeFileSync(path.join(release, "bin", "aiur"), "#!/bin/sh\n");
  chmodSync(path.join(release, "bin", "aiur"), 0o755);

  const script = String.raw`
source "$1"
AIUR_RELEASE_DIR="$2"
AIUR_RESTART_BUILD_CMD=':'
export AIUR_RELEASE_DIR
cmd_stop() { return 9; }
cmd_restart
`;
  const result = spawnSync("bash", ["-c", script, "restart-test", engine, release], {
    encoding: "utf8",
    env: { ...process.env, TMPDIR: root },
  });

  try {
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("restart aborted: stop failed (exit 9)");
    expect(readdirSync(root)).toEqual(["release"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
