import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

function run(args) {
  return spawnSync(
    "bash",
    ["-c", 'source "$1"; run_control_rpc() { printf "%s\\n" "$1"; }; shift; cmd_rework "$@"', "rework-test", engine, ...args],
    { encoding: "utf8", cwd: "/" }
  );
}

test("rework sends the ticket and a base64 reason through the control RPC", () => {
  const reason = 'test still asserts "full screen"\nupdate it';
  const result = run(["327", "--reason", reason]);
  assert.equal(result.status, 0);
  const encoded = Buffer.from(reason).toString("base64");
  assert.equal(result.stdout, `Aiur.AgentControlCLI.rework("327", Base.decode64!("${encoded}"))\n`);
});

test("rework refuses a missing reason, a bad id and unknown options before any RPC", () => {
  for (const args of [["327"], ["327", "--reason", "  "], ["abc", "--reason", "x"], ["327", "--reason", "x", "--ready"]]) {
    const result = run(args);
    assert.equal(result.status, 64);
    assert.match(result.stderr, /aiur: (rework|unknown rework option)/);
    assert.equal(result.stdout, "");
  }
});
