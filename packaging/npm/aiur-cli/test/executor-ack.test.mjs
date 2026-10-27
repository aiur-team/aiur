import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const handler = fileURLToPath(new URL("../libexec/engine/executor_commands.sh", import.meta.url));
const run = (...args) => spawnSync("bash", ["-c", 'source "$1"; run_control_rpc() { printf "%s" "$1"; }; shift; cmd_executor_ack "$@"', "ack-test", handler, ...args], { encoding: "utf8" });

test("executor-ack passes encoded ID and attribution to the control facade", () => {
  for (const flags of [[], ["--executor-id", 'executor"with$chars'], ["--executor-id=executor-two"]]) {
    const result = run("dec_0123456789abcdef", ...flags);
    expect(result.status).toBe(0);
    const executor = flags.length === 0 ? "aiur-cli" : flags.length === 1 ? "executor-two" : flags[1];
    expect(result.stdout).toBe(`Aiur.AgentControlCLI.executor_ack([decision_id: Base.decode64!("${Buffer.from("dec_0123456789abcdef").toString("base64")}"), executor_id: Base.decode64!("${Buffer.from(executor).toString("base64")}")])`);
  }
});

test("executor-ack refuses malformed IDs, extra arguments and missing flag values", () => {
  for (const args of [[], ["bad"], ["dec_0123456789abcdef", "extra"], ["dec_0123456789abcdef", "--unknown"], ["dec_0123456789abcdef", "--executor-id"]]) {
    const result = run(...args);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("executor-ack");
    expect(result.stdout).toBe("");
  }
});
