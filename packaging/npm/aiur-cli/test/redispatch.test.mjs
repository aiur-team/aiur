import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

function run(args) {
  return spawnSync(
    "bash",
    ["-c", 'source "$1"; run_control_rpc() { printf "%s\\n" "$1"; }; shift; cmd_redispatch "$@"', "redispatch-test", engine, ...args],
    { encoding: "utf8", cwd: "/" }
  );
}

test("redispatch passes explicit IDs and a valid backend through the control RPC", () => {
  const result = run(["142", "143", "--backend", "claude-repl"]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'Aiur.AgentControlCLI.redispatch(["142", "143"], "claude-repl")\n');
});

test("redispatch rejects unsafe backend specs and repeated backend options", () => {
  for (const args of [
    ["142", "--backend", 'codex"); System.cmd("touch", ["/tmp/unsafe"]) #'],
    ["142", "--backend", "claude", "--backend", "codex"]
  ]) {
    const result = run(args);
    assert.equal(result.status, 64);
    assert.match(result.stderr, /aiur: --backend/);
    assert.equal(result.stdout, "");
  }
});
