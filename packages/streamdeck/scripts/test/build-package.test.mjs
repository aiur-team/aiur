import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const packageRoot = new URL("../..", import.meta.url);
const fixtureCommit = "0123456789abcdef0123456789abcdef01234567";

test("builds a self-contained archive with traceable provenance", async () => {
  const output = await mkdtemp(join(fileURLToPath(packageRoot), ".package-artifact-"));
  const extract = await mkdtemp(join(fileURLToPath(packageRoot), ".package-extract-"));
  try {
    execFileSync(process.execPath, ["scripts/build-package.mjs", "--output", output, "--commit", fixtureCommit, "--version", "0.0.0-test", "--source-date-epoch", "0"], { cwd: packageRoot, stdio: "inherit" });
    const manifest = JSON.parse(await readFile(join(output, "aiur-streamdeck-0.0.0-test-linux-x64.json"), "utf8"));
    const archive = join(output, manifest.artifact);
    assert.equal(manifest.commit, fixtureCommit);
    assert.match(manifest.artifact, /-[a-f0-9]{64}\.tar\.gz$/);
    assert.match(manifest.content_address, new RegExp(`^releases/download/streamdeck-${fixtureCommit}/aiur-streamdeck-.*-[a-f0-9]{64}\\.tar\\.gz$`));
    assert.equal(manifest.release_asset_path, `releases/download/streamdeck-${fixtureCommit}/${manifest.artifact}`);
    execFileSync("tar", ["-xzf", archive, "-C", extract]);
    const root = join(extract, "aiur-streamdeck-0.0.0-test-linux-x64");
    assert.match(await readFile(join(root, "BUILD-INFO.json"), "utf8"), new RegExp(fixtureCommit));
    assert.match(await readFile(join(root, "README.md"), "utf8"), /does not need\nNode/);
    assert.match(await readFile(join(root, "share", "udev", "70-streamdeck.rules"), "utf8"), /0fd9/);
    assert.match(await readFile(join(root, "share", "systemd", "aiur-streamdeck.service"), "utf8"), /bin\/aiur-streamdeck/);
    await new Promise((resolve, reject) => {
      const child = spawn(join(root, "bin", "aiur-streamdeck"), [], { stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      child.stdout.on("data", (chunk) => (output += chunk));
      child.stderr.on("data", (chunk) => (output += chunk));
      let stoppedByTest = false;
      setTimeout(() => {
        if (child.exitCode !== null) {
          reject(new Error("sidecar exited before the clean-install smoke test stopped it"));
          return;
        }
        stoppedByTest = child.kill("SIGTERM");
      }, 300);
      child.on("exit", (code, signal) => {
        try { assert.match(output, /no Stream Deck \+ detected; waiting for hotplug/); assert.ok(stoppedByTest); assert.equal(signal, null); assert.equal(code, 0); resolve(); } catch (error) { reject(error); }
      });
    });
  } finally {
    await rm(output, { recursive: true, force: true });
    await rm(extract, { recursive: true, force: true });
  }
});
