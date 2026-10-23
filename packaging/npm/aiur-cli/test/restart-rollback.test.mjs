import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

test("restart boots the saved release after a failed refresh and retains the handoff", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-restart-rollback-"));
  const previous = path.join(root, "release");
  const logs = path.join(root, "logs");
  const ledger = path.join(root, "alert-ledger.jsonl");
  const ledgerFile = path.join(root, "ledger-path");
  const events = path.join(root, "events");
  mkdirSync(path.join(previous, "bin"), { recursive: true });
  mkdirSync(path.join(logs, "log"), { recursive: true });
  writeFileSync(path.join(previous, "AIUR_BUILD_STAMP"), "source_sha=previous-sha\n");
  writeFileSync(path.join(previous, "bin", "aiur"), "#!/bin/sh\n");
  chmodSync(path.join(previous, "bin", "aiur"), 0o755);
  writeFileSync(ledgerFile, `${ledger}\n`);
  writeFileSync(ledger, "");
  writeFileSync(path.join(logs, "log", "boot.out.log"), "new release panic: missing module\n");

  const script = String.raw`
source "$1"
AIUR_RELEASE_DIR="$2"
AIUR_LOGS_ROOT="$3"
AIUR_ALERT_LEDGER_PATH_FILE="$4"
export AIUR_RELEASE_DIR AIUR_LOGS_ROOT AIUR_ALERT_LEDGER_PATH_FILE
AIUR_RESTART_BUILD_CMD=': '
AIUR_RESTART_HANDOFF_ID=''
prepare_restart_handoff() { AIUR_RESTART_HANDOFF_ID='handoff-123'; export AIUR_RESTART_HANDOFF_ID; }
cmd_stop() { :; }
resolve_release() { :; }
probe_control_liveness() { printf down; }
run_control_rpc() { printf 'handoff adopted'; }
TEST_EVENTS="$5"
report_restart_handoff() { printf 'reported:%s\n' "$AIUR_RESTART_HANDOFF_ID" >>"$TEST_EVENTS"; }
dispatch_run() {
  printf '%s|%s|%s\n' "$AIUR_RELEASE_DIR" "$*" "$AIUR_RESTART_HANDOFF_ID" >>"$TEST_EVENTS"
  case "$AIUR_RELEASE_DIR" in
    *aiur-previous-release.*) return 0 ;;
    *) return 1 ;;
  esac
}
cmd_restart --keep-agents
`;
  const result = spawnSync("bash", ["-c", script, "restart-test", engine, previous, logs, ledgerFile, events], {
    encoding: "utf8",
    env: { ...process.env, TMPDIR: root },
  });

  try {
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("rolled back to previous-sha: new release failed with new release panic: missing module");
    const starts = readFileSync(events, "utf8").trim().split("\n");
    expect(starts).toHaveLength(3);
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
