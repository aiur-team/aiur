import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

test("set runtime settings safely forwards values, list modes, and unset", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = {
    AIUR_FAKE_RPC_MODE: "ok",
    AIUR_FAKE_EPMD_REGISTERED: "1",
    AIUR_AGENT_WORKSPACE: "/custom-agent-root/repo/5969",
  };

  expect(
    runControl(launcher, releaseDir, env, [
      "set",
      "agent.routing",
      '{"3":"openrouter:model with spaces"}',
    ]).status,
  ).toBe(0);
  expect(runControl(launcher, releaseDir, env, ["set", "--list"]).status).toBe(0);
  expect(runControl(launcher, releaseDir, env, ["set", "--list", "--json"]).status).toBe(0);
  expect(
    runControl(launcher, releaseDir, env, [
      "set",
      "--unset",
      "agent.max_concurrent_builds",
    ]).status,
  ).toBe(0);

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain(
    'Aiur.AgentControlCLI.set_setting(Base.decode64!("YWdlbnQucm91dGluZw=="), Base.decode64!("eyIzIjoib3BlbnJvdXRlcjptb2RlbCB3aXRoIHNwYWNlcyJ9"), caller_cwd: Base.decode64!("',
  );
  expect(capture).toContain(
    'caller_agent_workspace_env: Base.decode64!("L2N1c3RvbS1hZ2VudC1yb290L3JlcG8vNTk2OQ=="))',
  );
  expect(capture).toContain("Aiur.AgentControlCLI.list_settings()");
  expect(capture).toContain("Aiur.AgentControlCLI.list_settings(json: true)");
  expect(capture).toContain(
    'Aiur.AgentControlCLI.unset_setting(Base.decode64!("YWdlbnQubWF4X2NvbmN1cnJlbnRfYnVpbGRz"), caller_cwd: Base.decode64!("',
  );
});

test("set runtime settings validates argument shapes before rpc", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };

  expect(runControl(launcher, releaseDir, env, ["set", "agent.routing"]).status).toBe(64);
  expect(runControl(launcher, releaseDir, env, ["set", "--list", "--yaml"]).status).toBe(64);
  expect(runControl(launcher, releaseDir, env, ["set", "--unset"]).status).toBe(64);
  expect(existsSync(captureFile)).toBe(false);
});
