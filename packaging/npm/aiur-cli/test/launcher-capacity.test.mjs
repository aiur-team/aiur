import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();
test("capacity report forwards --since as an encoded string and --json as a boolean", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };
  const b64 = s => Buffer.from(s).toString("base64");
  expect(runControl(launcher, releaseDir, env, ["capacity", "report", "--since", "2026-11-01", "--json"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain(`Aiur.Capacity.ReportCLI.rpc(Base.decode64!("${b64("2026-11-01")}"), true)`);
  expect(runControl(launcher, releaseDir, env, ["capacity", "report"]).status).not.toBe(0);
  expect(runControl(launcher, releaseDir, env, ["capacity"]).status).not.toBe(0);
  expect(runControl(launcher, releaseDir, env, ["capacity", "report", "--since", "2026-11-01", "--bogus"]).status).not.toBe(0);
});
