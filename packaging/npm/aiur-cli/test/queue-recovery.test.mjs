import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const script = fileURLToPath(new URL("../libexec/aiur-queue.sh", import.meta.url));
function run(args, workspace = "") {
  return spawnSync("bash", ["-c", 'source "$1"; run_control_rpc() { printf "%s\\n" "$1"; }; shift; cmd_queue "$@"', "queue-test", script, ...args], { cwd: "/", env: { ...process.env, AIUR_AGENT_WORKSPACE: workspace, AIUR_PROJECT_ROOT: "", AIUR_REPO_ROOT: "" }, encoding: "utf8" });
}
test("recover and confirmed clear route through the shared daemon guard", () => {
  for (const [args, expected] of [
    [["recover"], "verb: :recover"],
    [["recover", "--force"], "force: true"],
    [["clear", "--remove-markers", "--yes"], "remove_markers: true, yes: true"],
  ]) {
    const result = run(args);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Aiur.AgentControlCLI.queue/);
    assert.ok(result.stdout.includes(expected));
    assert.ok(result.stdout.includes('caller_agent_workspace: Base.decode64!("")'));
    const blocked = run(args, "/workspace");
    assert.equal(blocked.status, 64);
    assert.match(blocked.stderr, /blocked inside agent workspaces/);
    assert.equal(blocked.stdout, "");
  }
});
test("clear requires explicit confirmation before making RPC", () => {
  const result = run(["clear", "--remove-markers"]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /requires --yes/);
  assert.equal(result.stdout, "");
});
// Deliberate future regression guard: unsupported input was already refused before these verbs existed.
test("recovery verbs reject IDs, unrelated flags, and duplicate flags", () => {
  for (const args of [["recover", "1"], ["clear", "--yes"], ["clear", "--remove-markers", "--yes", "1"], ["recover", "--yes"], ["clear", "--force"], ["recover", "--force", "--force"], ["clear", "--remove-markers", "--yes", "--yes"]]) {
    const result = run(args);
    assert.equal(result.status, 64);
    assert.equal(result.stdout, "");
  }
});
