import { test, expect } from "bun:test";
import { readFileSync, existsSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { captureFile, setupRealLauncher, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();

const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };

test("status --json prints the projects view; --handoff --json keeps its path", () => {
  const { launcher, releaseDir } = setupControlRpc();

  expect(runControl(launcher, releaseDir, env, ["status", "--json"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("RPC_EXPR:Aiur.AgentControlCLI.status(json: true)");

  rmSync(captureFile, { force: true });
  expect(runControl(launcher, releaseDir, env, ["status", "--handoff", "--json"]).status).toBe(0);
  const handoff = readFileSync(captureFile, "utf8");
  expect(handoff).toContain("RPC_EXPR:Aiur.Handoff.CLI.report(json: true)");
  expect(handoff).not.toContain("AgentControlCLI.status(json: true)");
});

test("gateway reload calls the daemon; anything else is a usage error", () => {
  const { launcher, releaseDir } = setupControlRpc();

  expect(runControl(launcher, releaseDir, env, ["gateway", "reload"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("RPC_EXPR:Aiur.Gateway.Cli.reload([])");

  for (const [args, message] of [
    [["gateway", "restart"], "gateway requires permissions"],
    [["gateway", "reload", "extra"], "unexpected argument extra"],
    [["gateway", "reload", "--json"], "--json requires gateway"],
  ]) {
    rmSync(captureFile, { force: true });
    const result = runControl(launcher, releaseDir, env, args);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain(message);
    expect(existsSync(captureFile)).toBe(false);
  }
});

test("gateway migrate-state evals the gateway module directly, passing its flags through", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const result = spawnSync("bash", [launcher, "gateway", "migrate-state", "--apply"], {
    encoding: "utf8",
    env: { ...process.env, AIUR_RELEASE_DIR: releaseDir, AIUR_TEST_OUT: captureFile },
  });
  expect(result.status).toBe(0);
  const out = readFileSync(captureFile, "utf8");
  expect(out).toContain("System.halt(Aiur.Gateway.StateMigrationCli.main(Aiur.CLI.argv_from_file()))");
  expect(out).toContain("ARGV_FILE:--apply");
  expect(out).not.toContain("ARGV_FILE:gateway");
});
