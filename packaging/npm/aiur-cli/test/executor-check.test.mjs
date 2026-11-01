import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../libexec/aiur-executor-session.sh", import.meta.url));
function run(args, code = 0) {
  return spawnSync("bash", ["-c", `
    source "$1"
    shift
    encode_control_value() { printf %s "$1" | base64 | tr -d '\\n'; }
    executor_project_root() { printf %s '/repo with spaces'; }
    run_control_rpc() { printf '%s\\n' "$1"; return ${code}; }
    cmd_executor_attach "$@"
  `, "executor-check", script, ...args], { encoding: "utf8" });
}

test("check routes to read-only RPC without requiring a harness", () => {
  const result = run(["--check"]);
  expect(result.status).toBe(0);
  expect(result.stdout).toBe('Aiur.AgentControlCLI.executor_check(json: false, repo_root: "L3JlcG8gd2l0aCBzcGFjZXM=" |> Base.decode64!())\n');
});

test("check forwards JSON and preserves diagnostic failure exit", () => {
  const result = run(["--json", "--check"], 1);
  expect(result.status).toBe(1);
  expect(result.stdout).toContain("executor_check(json: true");
});

for (const args of [["--json"], ["--check", "--harness", "claude"], ["--check", "--takeover"], ["--check", "--print-config"]]) {
  test(`rejects incompatible arguments ${args.join(" ")}`, () => {
    const result = run(args);
    expect(result.status).toBe(64);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("aiur:");
  });
}
