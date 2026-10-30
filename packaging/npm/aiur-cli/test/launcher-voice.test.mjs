import { test, expect } from "bun:test";
import { readFileSync, existsSync, rmSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runControl, setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();
const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };
const id = "vc_aaaaaaaaaaaaaaaaaaaaaa";

test("voice transcripts forwards validated list and show arguments", () => {
  const { launcher, releaseDir } = setupControlRpc();
  expect(runControl(launcher, releaseDir, env, ["voice", "transcripts", "--target", "org/repo#4140", "--limit", "10", "--json"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain('Aiur.VoiceCLI.transcripts(["--target", "org/repo#4140", "--limit", "10", "--json"])');
  expect(runControl(launcher, releaseDir, env, ["voice", "transcripts", id, "--json"]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain(`Aiur.VoiceCLI.transcripts(["${id}", "--json"])`);
});

test("voice transcripts rejects malformed and injection values before RPC", () => {
  const { launcher, releaseDir } = setupControlRpc();
  for (const args of [
    ['vc_aaaaaaaaaaaaaaaaaaaaaa");System.halt();#'], ["../transcript"], [""], ["--target", 'x");System.halt();#'],
    ["--limit", "1);System.halt()"], ["--limit", "101"], ["--limit="], ["--target="], ["--target"], ["--other"], [id, id], [id, "--limit", "1"],
  ]) {
    rmSync(captureFile, { force: true });
    const result = runControl(launcher, releaseDir, env, ["voice", "transcripts", ...args]);
    expect(result.status).toBe(64);
    expect(existsSync(captureFile)).toBe(false);
  }
});

test("voice deletion requires matching confirmation before RPC", () => {
  const { launcher, releaseDir } = setupControlRpc();
  for (const args of [["--delete"], [id, "--delete"], [id, "--confirm", id],
    [id, "--delete", "--confirm", 'x");System.halt();#'], [id, "--delete", "--confirm", id, "--json"]]) {
    rmSync(captureFile, { force: true });
    expect(runControl(launcher, releaseDir, env, ["voice", "transcripts", ...args]).status).toBe(64);
    expect(existsSync(captureFile)).toBe(false);
  }
  expect(runControl(launcher, releaseDir, env, ["voice", "transcripts", id, "--delete", "--confirm", id]).status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain(`Aiur.VoiceCLI.transcripts(["${id}", "--delete", "--confirm", "${id}"])`);
});
