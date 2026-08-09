import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const packageRoot = new URL("../..", import.meta.url);
const fixtureCommit = "0123456789abcdef0123456789abcdef01234567";

test("builds a self-contained archive with traceable provenance", async () => {
  const output = process.env.PACKAGE_ARTIFACT_DIR ?? await mkdtemp(join(fileURLToPath(packageRoot), ".package-artifact-"));
  const extract = await mkdtemp(join(fileURLToPath(packageRoot), ".package-extract-"));
  try {
    const archiveOutput = process.env.PACKAGE_ARTIFACT_DIR
      ? undefined
      : execFileSync(process.execPath, ["scripts/build-package.mjs", "--output", output, "--commit", fixtureCommit, "--version", "0.0.0-test", "--source-date-epoch", "0", "--release-tag", "v0.0.0-test"], { cwd: packageRoot, encoding: "utf8" });
    const manifests = (await readdir(output)).filter((entry) => entry.endsWith(".json"));
    assert.equal(manifests.length, 1, "the package directory contains one manifest");
    const manifest = JSON.parse(await readFile(join(output, manifests[0]), "utf8"));
    const archive = join(output, manifest.artifact);
    const archiveDigest = createHash("sha256").update(await readFile(archive)).digest("hex");
    assert.match(manifest.commit, /^[0-9a-f]{40}$/);
    assert.equal(manifest.sha256, archiveDigest);
    assert.ok(manifest.artifact.endsWith(`-${archiveDigest}.tar.gz`));
    const releaseTag = process.env.PACKAGE_RELEASE_TAG ?? "v0.0.0-test";
    assert.equal(manifest.content_address, `releases/download/${releaseTag}/${manifest.artifact}`);
    assert.equal(manifest.release_asset_path, `releases/download/${releaseTag}/${manifest.artifact}`);
    if (archiveOutput) {
      assert.equal(manifest.commit, fixtureCommit);
      assert.equal(archiveOutput, `${archive}\n`);
    }
    execFileSync("tar", ["-xzf", archive, "-C", extract]);
    const archiveSuffix = `-${manifest.sha256}.tar.gz`;
    assert.ok(manifest.artifact.endsWith(archiveSuffix));
    const root = join(extract, manifest.artifact.slice(0, -archiveSuffix.length));
    assert.match(await readFile(join(root, "BUILD-INFO.json"), "utf8"), new RegExp(manifest.commit));
    const bundledNode = await stat(join(root, "runtime", "node"));
    assert.ok(bundledNode.mode & 0o111, "the archive bundles an executable Node runtime");
    assert.match(await readFile(join(root, "bin", "aiur-streamdeck"), "utf8"), /exec "\$root\/runtime\/node"/);
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
    if (!process.env.PACKAGE_ARTIFACT_DIR) await rm(output, { recursive: true, force: true });
    await rm(extract, { recursive: true, force: true });
  }
});
