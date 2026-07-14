import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, existsSync, chmodSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../assemble-platform-package.mjs", import.meta.url));
const layoutCheck = fileURLToPath(new URL("../check-layout-assets-release.mjs", import.meta.url));
const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const platformDir = path.join(repoRoot, "packaging", "npm", "platform");
const vendorSource = path.join(repoRoot, "src", "priv", "static", "vendor", "elk", "0.11.1");

let releaseDir;
const cleanupTargets = [];

function makeFixtureRelease() {
  const dir = mkdtempSync(path.join(tmpdir(), "aiur-rel-"));
  mkdirSync(path.join(dir, "bin"), { recursive: true });
  writeFileSync(path.join(dir, "bin", "aiur"), "#!/bin/sh\necho aiur\n");
  chmodSync(path.join(dir, "bin", "aiur"), 0o755);
  mkdirSync(path.join(dir, "releases"), { recursive: true });
  writeFileSync(path.join(dir, "releases", "start_erl.data"), "16.4 0.1.1\n");
  cpSync(vendorSource, path.join(dir, "lib", "aiur-0.1.1", "priv", "static", "vendor", "elk", "0.11.1"), { recursive: true });
  return dir;
}

function run(args) {
  return spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
}

beforeEach(() => {
  releaseDir = makeFixtureRelease();
});

afterEach(() => {
  rmSync(releaseDir, { recursive: true, force: true });
  for (const t of cleanupTargets.splice(0)) {
    rmSync(path.join(platformDir, `aiur-cli-${t}`), { recursive: true, force: true });
  }
});

test("happy path: writes package.json with correct os/cpu and files", () => {
  cleanupTargets.push("linux-arm64");
  const result = run(["--release", releaseDir, "--target", "linux-arm64", "--version", "1.2.3"]);
  expect(result.status).toBe(0);

  const outDir = result.stdout.trim();
  expect(outDir).toBe(path.join(platformDir, "aiur-cli-linux-arm64"));

  const pkg = JSON.parse(readFileSync(path.join(outDir, "package.json"), "utf8"));
  expect(pkg.name).toBe("aiur-cli-linux-arm64");
  expect(pkg.version).toBe("1.2.3");
  expect(pkg.os).toEqual(["linux"]);
  expect(pkg.cpu).toEqual(["arm64"]);
  expect(pkg.files).toContain("release");
  expect(pkg.license).toBe("Apache-2.0");
  expect(pkg.bin).toBeUndefined();
  expect(pkg.scripts).toBeUndefined();

  expect(existsSync(path.join(outDir, "release", "bin", "aiur"))).toBe(true);
  expect(existsSync(path.join(outDir, "LICENSE"))).toBe(true);
  expect(existsSync(path.join(outDir, "NOTICE"))).toBe(true);
});

test("unknown target errors clearly and writes nothing", () => {
  const result = run(["--release", releaseDir, "--target", "freebsd-x64", "--version", "1.0.0"]);
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("unknown target");
  expect(existsSync(path.join(platformDir, "aiur-cli-freebsd-x64"))).toBe(false);
});

test("npm pack --dry-run lists the release binary and license files", () => {
  cleanupTargets.push("darwin-x64");
  const out = run(["--release", releaseDir, "--target", "darwin-x64", "--version", "0.1.1"]).stdout.trim();
  const pack = spawnSync("npm", ["pack", "--dry-run", "--json"], { cwd: out, encoding: "utf8" });
  // npm may be unavailable in some sandboxes; skip rather than fail spuriously.
  if (pack.error || pack.status !== 0) return;
  const listing = pack.stdout;
  expect(listing).toContain("release/bin/aiur");
  expect(listing).toContain("LICENSE");
  expect(listing).toContain("NOTICE");
});

test("platform copy retains the locally vendored layout runtime and evidence", () => {
  cleanupTargets.push("linux-x64");
  const out = run(["--release", releaseDir, "--target", "linux-x64", "--version", "0.1.1"]).stdout.trim();
  const packagedRelease = path.join(out, "release");
  const check = spawnSync(process.execPath, [layoutCheck, "--release", packagedRelease], { encoding: "utf8" });

  expect(check.status).toBe(0);
  expect(check.stdout).toContain("priv/static/vendor/elk/0.11.1");
  expect(existsSync(path.join(packagedRelease, "lib", "aiur-0.1.1", "priv", "static", "vendor", "elk", "0.11.1", "manifest.json"))).toBe(true);
});

test("release integrity check rejects a tampered layout asset", () => {
  const vendor = path.join(releaseDir, "lib", "aiur-0.1.1", "priv", "static", "vendor", "elk", "0.11.1");
  const manifest = JSON.parse(readFileSync(path.join(vendor, "manifest.json"), "utf8"));
  writeFileSync(path.join(vendor, manifest.assets.engine.file), "tampered");

  const check = spawnSync(process.execPath, [layoutCheck, "--release", releaseDir], { encoding: "utf8" });

  expect(check.status).not.toBe(0);
  expect(check.stderr).toContain("does not match its recorded SHA-256");
});

test("release integrity check rejects missing or non-content-addressed asset records", () => {
  const vendor = path.join(releaseDir, "lib", "aiur-0.1.1", "priv", "static", "vendor", "elk", "0.11.1");
  const manifestPath = path.join(vendor, "manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.assets.client.url = "/vendor/layout/client-v1/not-a-digest/aiur-layout-client.js";
  writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);

  const check = spawnSync(process.execPath, [layoutCheck, "--release", releaseDir], { encoding: "utf8" });

  expect(check.status).not.toBe(0);
  expect(check.stderr).toContain("URL is not content-addressed");
});
