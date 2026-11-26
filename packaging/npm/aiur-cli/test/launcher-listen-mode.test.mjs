import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();
test("listen-mode forwards ticket and options as encoded strings", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };
  for (const args of [["42", "--json"], ["42", "async", "--expected-version", "0"]]) {
    expect(runControl(launcher, releaseDir, env, ["listen-mode", ...args]).status).toBe(0);
    const encoded = args.slice(1).map(arg => `Base.decode64!("${Buffer.from(arg).toString("base64")}")`).join(", ");
    expect(readFileSync(captureFile, "utf8")).toContain(`Aiur.ListenModeCli.run(Base.decode64!("NDI="), [${encoded}])`);
  }
  expect(runControl(launcher, releaseDir, env, ["listen-mode"]).status).toBe(64);
});
