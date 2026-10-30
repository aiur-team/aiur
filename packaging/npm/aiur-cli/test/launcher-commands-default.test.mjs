import { test, expect } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();

test("bare commands requests only open work while explicit all includes history", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };

  expect(runControl(launcher, releaseDir, env, ["commands"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("Aiur.AgentControlCLI.commands([filter: :open])");

  rmSync(captureFile, { force: true });
  expect(runControl(launcher, releaseDir, env, ["commands", "--filter", "all"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("Aiur.AgentControlCLI.commands([filter: :all])");
});
