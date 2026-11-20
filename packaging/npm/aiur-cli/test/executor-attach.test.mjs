import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
const script = fileURLToPath(new URL("../libexec/aiur-executor-session.sh", import.meta.url));
function run(command, args = [], cwd = process.cwd(), env = {}) {
  return spawnSync("bash", ["-c", 'source "$1"; shift; run_control_rpc() { printf "%s\\n" "$1"; }; encode_control_value() { printf %s "$1" | base64 | tr -d "\\n"; }; "$@"', "test", script, command, ...args], { encoding: "utf8", cwd, env: { ...process.env, ...env } });
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
  expect(result.stdout).toContain(Buffer.from(spawnSync("git", ["-C", process.cwd(), "rev-parse", "--show-toplevel"], { encoding: "utf8" }).stdout.trim() || process.cwd()).toString("base64"));
});
test("detach and session reject extra arguments and use binding RPCs", () => {
  expect(run("cmd_executor_detach", ["extra"]).status).toBe(64);
  expect(run("cmd_executor_session", ["--json", "extra"]).status).toBe(64);
  expect(run("cmd_executor_detach").stdout).toContain("Aiur.AgentControlCLI.executor_detach(");
  expect(run("cmd_executor_session", ["--json"]).stdout).toContain("Aiur.AgentControlCLI.executor_session(json: true)");
});

test("attach and detach resolve the project root from a nested directory", () => {
  const root = mkdtempSync(path.join(tmpdir(), "executor project-"));
  try {
    expect(spawnSync("git", ["-C", root, "init", "--quiet"]).status).toBe(0);
    const nested = path.join(root, "nested");
    mkdirSync(nested);
    for (const [command, args] of [["cmd_executor_attach", ["--harness", "claude"]], ["cmd_executor_detach", []]]) {
      const result = run(command, args, nested);
      expect(result.status).toBe(0);
      expect(result.stdout).toContain(Buffer.from(root).toString("base64"));
      expect(result.stdout).not.toContain(Buffer.from(nested).toString("base64"));
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test("future-regression guard: attach outside a repository falls back to the caller directory", () => {
  const root = mkdtempSync(path.join(tmpdir(), "executor-no-repo-"));
  try {
    const result = run("cmd_executor_attach", ["--harness", "claude"], root, { GIT_CEILING_DIRECTORIES: path.dirname(root) });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain(Buffer.from(root).toString("base64"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
