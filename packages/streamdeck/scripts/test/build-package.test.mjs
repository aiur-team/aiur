import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { clearInterval, clearTimeout, setInterval } from "node:timers";
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
    const releaseTag = process.env.PACKAGE_RELEASE_TAG ?? "v0.0.0-test";
    assert.equal(manifest.content_address, `releases/download/${releaseTag}/${manifest.artifact}`);
    assert.equal(manifest.release_asset_path, `releases/download/${releaseTag}/${manifest.artifact}`);
    if (archiveOutput) {
      // Without --asset-base the archive name is content-addressed.
      assert.ok(manifest.artifact.endsWith(`-${archiveDigest}.tar.gz`));
      assert.equal(manifest.commit, fixtureCommit);
      assert.equal(archiveOutput, `${archive}\n`);
    }
    execFileSync("tar", ["-xzf", archive, "-C", extract]);
    // The extracted root is always versioned, whatever the archive was named.
    const root = join(extract, `aiur-streamdeck-${manifest.version}-${manifest.target}`);
    assert.match(await readFile(join(root, "BUILD-INFO.json"), "utf8"), new RegExp(manifest.commit));
    const bundledNode = await stat(join(root, "runtime", "node"));
    assert.ok(bundledNode.mode & 0o111, "the archive bundles an executable Node runtime");
    assert.match(await readFile(join(root, "bin", "aiur-streamdeck"), "utf8"), /exec "\$root\/runtime\/node"/);
    assert.match(await readFile(join(root, "share", "udev", "70-streamdeck.rules"), "utf8"), /0fd9/);
    assert.match(await readFile(join(root, "share", "systemd", "aiur-streamdeck.service"), "utf8"), /bin\/aiur-streamdeck/);
    await new Promise((resolve, reject) => {
      const child = spawn(join(root, "bin", "aiur-streamdeck"), [], {
        env: { ...process.env, AIUR_STREAMDECK_FORCE_ABSENT: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let output = "";
      child.stdout.on("data", (chunk) => (output += chunk));
      child.stderr.on("data", (chunk) => (output += chunk));
      let stoppedByTest = false;
      const deadline = setTimeout(() => {
        if (child.exitCode !== null) return;
        reject(new Error(`sidecar did not announce readiness; output: ${output}`));
        child.kill("SIGTERM");
      }, 10_000);
      const stopWhenReady = setInterval(() => {
        if (!/no Stream Deck \+ detected; waiting for hotplug/.test(output)) return;
        clearInterval(stopWhenReady);
        clearTimeout(deadline);
        stoppedByTest = child.kill("SIGTERM");
      }, 25);
      child.on("exit", (code, signal) => {
        clearInterval(stopWhenReady);
        clearTimeout(deadline);
        try {
          assert.match(output, /no Stream Deck \+ detected; waiting for hotplug/);
          assert.ok(stoppedByTest);
          assert.ok(code === 0 || signal === "SIGTERM", `unexpected exit: code=${code}, signal=${signal}`);
          resolve();
        } catch (error) { reject(error); }
      });
    });
  } finally {
    if (!process.env.PACKAGE_ARTIFACT_DIR) await rm(output, { recursive: true, force: true });
    await rm(extract, { recursive: true, force: true });
  }
});

test("a fixed asset base names the archive and manifest for a rolling release", async () => {
  const output = await mkdtemp(join(fileURLToPath(packageRoot), ".package-artifact-"));
  try {
    const archiveOutput = execFileSync(process.execPath, ["scripts/build-package.mjs", "--output", output, "--commit", fixtureCommit, "--version", "0.0.0-nightly.0123456789ab", "--source-date-epoch", "0", "--release-tag", "streamdeck-nightly", "--asset-base", "aiur-streamdeck-nightly-linux-x64"], { cwd: packageRoot, encoding: "utf8" });
    const entries = (await readdir(output)).sort();
    assert.deepEqual(entries, ["aiur-streamdeck-nightly-linux-x64.json", "aiur-streamdeck-nightly-linux-x64.tar.gz"]);
    const manifest = JSON.parse(await readFile(join(output, "aiur-streamdeck-nightly-linux-x64.json"), "utf8"));
    const archive = join(output, manifest.artifact);
    assert.equal(archiveOutput, `${archive}\n`);
    assert.equal(manifest.artifact, "aiur-streamdeck-nightly-linux-x64.tar.gz");
    assert.equal(manifest.version, "0.0.0-nightly.0123456789ab");
    assert.equal(manifest.commit, fixtureCommit);
    // The fixed name carries no digest, so the manifest's sha256 is the integrity contract.
    assert.equal(manifest.sha256, createHash("sha256").update(await readFile(archive)).digest("hex"));
    assert.equal(manifest.content_address, "releases/download/streamdeck-nightly/aiur-streamdeck-nightly-linux-x64.tar.gz");
    assert.equal(manifest.release_asset_path, manifest.content_address);
    const listing = execFileSync("tar", ["-tzf", archive], { encoding: "utf8" });
    assert.match(listing, /^aiur-streamdeck-0\.0\.0-nightly\.0123456789ab-linux-x64\/BUILD-INFO\.json$/m);
  } finally {
    await rm(output, { recursive: true, force: true });
  }
});

test("an asset base must be a plain file name stem", () => {
  assert.throws(
    () => execFileSync(process.execPath, ["scripts/build-package.mjs", "--commit", fixtureCommit, "--version", "0.0.0-test", "--source-date-epoch", "0", "--asset-base", "../escape"], { cwd: packageRoot, encoding: "utf8", stdio: "pipe" }),
    /--asset-base must be a plain file name stem/,
  );
});
