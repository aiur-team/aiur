import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const handler = fileURLToPath(new URL("../libexec/engine/executor_commands.sh", import.meta.url));
const run = (...args) => spawnSync("bash", ["-c", 'source "$1"; run_control_rpc() { printf "%s" "$1"; }; shift; cmd_executor_claim_decision "$@"', "claim-test", handler, ...args], { encoding: "utf8" });
const b64 = (value) => `Base.decode64!("${Buffer.from(value).toString("base64")}")`;
const ID = "dec_0123456789abcdef";

test("claim passes decision_id, executor_id and ttl_s to the control facade", () => {
  const result = run("executor-claim-decision", ID, "--as", "exec-a", "--ttl", "60");
  expect(result.status).toBe(0);
  expect(result.stdout).toBe(`Aiur.AgentControlCLI.executor_claim_decision([decision_id: ${b64(ID)}, executor_id: ${b64("exec-a")}, ttl_s: 60])`);
});

test("release omits ttl_s and refuses --ttl", () => {
  const ok = run("executor-release-decision", ID, "--as=exec-a");
  expect(ok.status).toBe(0);
  expect(ok.stdout).toBe(`Aiur.AgentControlCLI.executor_release_decision([decision_id: ${b64(ID)}, executor_id: ${b64("exec-a")}])`);
  for (const flags of [["--ttl", "60"], ["--ttl=60"]]) {
    const bad = run("executor-release-decision", ID, "--as", "exec-a", ...flags);
    expect(bad.status).toBe(64);
    expect(bad.stdout).toBe("");
  }
});

test("claim refuses malformed IDs, a missing or invalid --as, and a non-numeric --ttl", () => {
  for (const args of [["bad", "--as", "a"], [ID], [ID, "--as"], [ID, "--as", "bad id"], [ID, "--as", "a", "--ttl", "x"], [ID, "--as", "a", "extra"]]) {
    const result = run("executor-claim-decision", ...args);
    expect(result.status).toBe(64);
    expect(result.stdout).toBe("");
  }
});
