import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));
function run(args) {
  const env = { ...process.env, AIUR_AGENT_WORKSPACE: "", AIUR_PROJECT_ROOT: "", AIUR_REPO_ROOT: "" };
  return spawnSync("bash", ["-c", 'source "$1"; run_control_rpc() { printf "%s\\n" "$1"; }; shift; cmd_queue "$@"', "queue-test", engine, ...args], { encoding: "utf8", cwd: "/", env });
}
test("queue show safely passes names through the shared engine RPC", () => {
  const name = 'paseo"; $(touch forbidden)';
  const result = run(["show", "--queue", name, "--json"]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, `Aiur.AgentControlCLI.queue([json: true, queue: Base.decode64!("${Buffer.from(name).toString("base64")}")])\n`);
});
test("queue add accepts JSON and preserves the mutation options", () => {
  const result = run(["add", "141", "142", "--queue", "paseo", "--json"]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'Aiur.AgentControlCLI.queue([verb: :add, caller_agent_workspace: Base.decode64!(""), json: true, queue: Base.decode64!("cGFzZW8="), ids: ["141","142"]])\n');
});
test("queue rejects missing names, unsupported verbs, and stray arguments", () => {
  for (const args of [[], ["unknown", "1"], ["show", "--queue"], ["show", "--queue", ""], ["show", "--queue", "--json"], ["show", "1"], ["show", "--bad"]]) {
    const result = run(args);
    assert.equal(result.status, 64);
    assert.match(result.stderr, /aiur: queue/);
    assert.equal(result.stdout, "");
  }
});
