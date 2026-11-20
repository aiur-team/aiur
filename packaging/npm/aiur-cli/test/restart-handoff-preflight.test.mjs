import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

// open-game-maker, 2026-11-20: an Executor kept only the last lines of a failed
// `restart --keep-agents`. The reason was printed lines earlier, so all it saw was
// "aborted before stop: handoff preflight failed". The abort line must carry it.
function preflight(rpcBody) {
  return spawnSync("bash", ["-c", `
source "$ENGINE"
aiur_write_restart_diagnostic() { :; }
run_control_rpc() { ${rpcBody} }
prepare_restart_handoff
`], { encoding: "utf8", timeout: 15000, env: { ...process.env, ENGINE: engine } });
}

function abortLine(result) {
  return result.stderr.trim().split("\n").at(-1);
}

test("a failed preflight names the daemon's reason on the abort line", () => {
  const result = preflight(`echo "handoff preflight failed: {:timeout, :prepare_handoff_snapshot}" >&2; return 1;`);
  expect(result.status).toBe(1);
  expect(abortLine(result)).toBe("❌ restart --keep-agents aborted before stop: handoff preflight failed: {:timeout, :prepare_handoff_snapshot}");
});

test("a daemon that is down is named on the abort line, not the advice after it", () => {
  const result = preflight(`
    echo "aiur: background daemon at aiur-x@127.0.0.1 is DOWN after an unexpected exit; agents may be orphaned" >&2
    echo "  timestamp: 2026-11-20T12:57:58Z" >&2
    echo "aiur: run 'aiur stop' to reap any orphaned agents, then start aiur again" >&2
    return 1;`);
  expect(result.status).toBe(1);
  expect(abortLine(result)).toBe("❌ restart --keep-agents aborted before stop: handoff preflight failed: aiur: background daemon at aiur-x@127.0.0.1 is DOWN after an unexpected exit; agents may be orphaned");
  expect(result.stderr).toContain("run 'aiur stop'");
});

test("a preflight that fails silently still aborts with the plain message", () => {
  const result = preflight(`return 1;`);
  expect(result.status).toBe(1);
  expect(abortLine(result)).toBe("❌ restart --keep-agents aborted before stop: handoff preflight failed");
});
