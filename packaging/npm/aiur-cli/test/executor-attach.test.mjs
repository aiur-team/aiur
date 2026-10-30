import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const script = fileURLToPath(new URL("../libexec/aiur-executor-session.sh", import.meta.url));
function run(command, args = []) {
  return spawnSync("bash", ["-c", 'source "$1"; shift; run_control_rpc() { printf "%s\\n" "$1"; }; encode_control_value() { printf %s "$1" | base64 | tr -d "\\n"; }; "$@"', "test", script, command, ...args], { encoding: "utf8" });
}
test("attach requires an explicit supported harness and rejects unknown flags", () => {
  for (const args of [[], ["--harness"], ["--harness", "other"], ["--harness", "claude", "--bad"]]) {
    expect(run("cmd_executor_attach", args).status).toBe(64);
  }
});
test("attach forwards validated options and encoded caller repository", () => {
  const result = run("cmd_executor_attach", ["--harness=codex", "--takeover", "--print-config"]);
  expect(result.status).toBe(0);
  expect(result.stdout).toContain('Aiur.AgentControlCLI.executor_attach(harness: "codex", takeover?: true, print_config: true');
  expect(result.stdout).toContain(Buffer.from(process.cwd()).toString("base64"));
});
test("detach and session reject extra arguments and use binding RPCs", () => {
  expect(run("cmd_executor_detach", ["extra"]).status).toBe(64);
  expect(run("cmd_executor_session", ["--json", "extra"]).status).toBe(64);
  expect(run("cmd_executor_detach").stdout).toContain("Aiur.AgentControlCLI.executor_detach(");
  expect(run("cmd_executor_session", ["--json"]).stdout).toContain("Aiur.AgentControlCLI.executor_session(json: true)");
});
