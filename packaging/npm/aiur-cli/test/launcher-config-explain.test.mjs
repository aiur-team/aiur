import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();
test("config explain forwards key and project as encoded strings", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };
  const b64 = s => Buffer.from(s).toString("base64");
  expect(runControl(launcher, releaseDir, env, ["config", "explain", "agent.priority", "--project", "o/a", "--json"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain(
    `Aiur.ControlCLI.ConfigExplain.explain(Base.decode64!("${b64("agent.priority")}"), json: true, project: Base.decode64!("${b64("o/a")}"))`,
  );
  expect(runControl(launcher, releaseDir, env, ["config", "explain"]).status).toBe(64);
  expect(runControl(launcher, releaseDir, env, ["config"]).status).toBe(64);
});
