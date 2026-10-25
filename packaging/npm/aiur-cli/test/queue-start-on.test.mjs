import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const script = fileURLToPath(new URL("../libexec/aiur-queue.sh", import.meta.url));
function run(args, workspace = "") {
  return spawnSync("bash", ["-c", 'source "$1"; todo_rpc_seconds() { echo 30; }; run_control_rpc() { printf "%s\\n" "$1"; }; shift; cmd_queue "$@"', "queue-test", script, ...args], { cwd: "/", env: { ...process.env, AIUR_AGENT_WORKSPACE: workspace, AIUR_PROJECT_ROOT: "", AIUR_REPO_ROOT: "" }, encoding: "utf8" });
}
test("add and set forward every start trigger through the shared RPC", () => {
  for (const trigger of ["issue_closed", "pr_merged", "pr_approved", "pr_ci_green", "pr_opened"]) {
    for (const args of [["add", "12", "13", "--queue", "wave"], ["add", "--build-order", "2573"], ["set", "wave"]]) {
      const result = run([...args, "--start-on", trigger]);
      assert.equal(result.status, 0, result.stderr);
      assert.ok(result.stdout.includes(`start_on: Base.decode64!("${Buffer.from(trigger).toString("base64")}")`));
      assert.match(result.stdout, /Aiur.AgentControlCLI.queue/);
      assert.ok(result.stdout.includes(`verb: :${args[0]}`));
      if (args[0] === "set") assert.ok(result.stdout.includes('queue: Base.decode64!("d2F2ZQ==")'));
      if (args.includes("--build-order")) assert.match(result.stdout, /build_order: 2573/);
    }
  }
  const result = run(["set", "wave", "--start-on", "default"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /start_on: Base.decode64!\("ZGVmYXVsdA=="\)/);
});
test("invalid start trigger exits 64 and lists the valid values", () => {
  const result = run(["add", "12", "--start-on", "soon"]);
  assert.equal(result.status, 64);
  assert.equal(result.stdout, "");
  for (const trigger of ["issue_closed", "pr_merged", "pr_approved", "pr_ci_green", "pr_opened"]) assert.ok(result.stderr.includes(trigger));
});
test("set enforces required arguments and remains guarded in agent workspaces", () => {
  for (const args of [["set"], ["set", "wave"], ["set", "wave", "other", "--start-on", "pr_opened"], ["set", "wave", "--start-on"], ["set", "wave", "--start-on", "pr_opened", "--start-on", "pr_merged"]]) {
    const result = run(args);
    assert.equal(result.status, 64);
    assert.equal(result.stdout, "");
  }
  const result = run(["set", "wave", "--start-on", "pr_opened"], "/workspace");
  assert.equal(result.status, 64);
  assert.match(result.stderr, /blocked inside agent workspaces/);
});
// Future regression guard: unrelated verbs already rejected this flag.
test("start-on is restricted to add and set, default to set", () => {
  for (const args of [["remove", "12", "--start-on", "pr_opened"], ["show", "--start-on", "pr_opened"], ["add", "12", "--start-on", "default"]]) assert.equal(run(args).status, 64);
});
