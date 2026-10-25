import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const sessionModule = fileURLToPath(new URL("../libexec/engine/session.sh", import.meta.url));

test("EXIT cleanup preserves the child status when a cleanup step fails", () => {
  const script = String.raw`
set -euo pipefail
source "$1"
_session_pidfile=""
_session_node=""
_session_workspace_root_file=""
_session_tmpfile=""
_session_argv=""
_session_release=""
_session_alert_ledger_path_file=""
_session_crash_dump_baseline_file=""
_session_capture=""
_session_launch_lock=""
reap_aiur_agents() { true && false; }
reap_workspace_cwd_from_file() { :; }
sweep_dead_tmux_sockets() { :; }
sweep_stale_tmp_artifacts() { :; }
cleanup_test_launch_private_state() { :; }
release_aiur_launch_lock() { :; }
aiur_instance_record_path() { printf /nonexistent/aiur-cleanup-test-record; }
trap 'session_cleanup; exit "$?"' EXIT
exit 7
`;
  const result = spawnSync("/bin/bash", ["-c", script, "session-cleanup-test", sessionModule], {
    encoding: "utf8",
  });

  expect(result.status).toBe(7);
});
