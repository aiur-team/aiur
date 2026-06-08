import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realScript = fileURLToPath(new URL("../stamp-versions.mjs", import.meta.url));
const TARGETS = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"];

let root;
let scriptCopy;
let launcherPkg;

function writeJson(p, obj) {
  mkdirSync(path.dirname(p), { recursive: true });
  writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
}

function readJson(p) {
  return JSON.parse(readFileSync(p, "utf8"));
}

// Mirror the repo layout in a temp tree and run a copy of the script so its
// repoRoot (derived from its own location) points at the fixture, not the repo.
function setup({ withPlatform = true } = {}) {
  root = mkdtempSync(path.join(tmpdir(), "aiur-stamp-"));
  mkdirSync(path.join(root, "packaging", "scripts"), { recursive: true });
  scriptCopy = path.join(root, "packaging", "scripts", "stamp-versions.mjs");
  copyFileSync(realScript, scriptCopy);

  launcherPkg = path.join(root, "packaging", "npm", "aiur-cli", "package.json");
  writeJson(launcherPkg, {
    name: "aiur-cli",
    version: "0.0.0",
    optionalDependencies: {
      "aiur-cli-linux-x64": "0.0.0",
      "aiur-cli-linux-arm64": "0.0.0",
      "aiur-cli-darwin-x64": "0.0.0",
      "aiur-cli-darwin-arm64": "0.0.0",
    },
  });

  if (withPlatform) {
    for (const t of TARGETS) {
      writeJson(path.join(root, "packaging", "npm", "platform", `aiur-cli-${t}`, "package.json"), {
        name: `aiur-cli-${t}`,
        version: "0.0.0",
      });
    }
  }
}

function run(version) {
  const args = version === undefined ? [scriptCopy] : [scriptCopy, version];
  return spawnSync(process.execPath, args, { encoding: "utf8" });
}

beforeEach(() => setup());
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("sets all five versions and pins optionalDependencies exactly", () => {
  const result = run("0.1.0");
  expect(result.status).toBe(0);

  const launcher = readJson(launcherPkg);
  expect(launcher.version).toBe("0.1.0");
  for (const t of TARGETS) {
    expect(launcher.optionalDependencies[`aiur-cli-${t}`]).toBe("0.1.0");
    const platform = readJson(
      path.join(root, "packaging", "npm", "platform", `aiur-cli-${t}`, "package.json"),
    );
    expect(platform.version).toBe("0.1.0");
  }
});

test("empty version errors and mutates nothing", () => {
  const before = readFileSync(launcherPkg, "utf8");
  const result = run("");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("invalid version");
  expect(readFileSync(launcherPkg, "utf8")).toBe(before);
});

test("malformed version errors and mutates nothing", () => {
  const before = readFileSync(launcherPkg, "utf8");
  const result = run("not-a-version");
  expect(result.status).not.toBe(0);
  expect(readFileSync(launcherPkg, "utf8")).toBe(before);
});

test("missing platform package.json is skipped, launcher still stamped", () => {
  rmSync(root, { recursive: true, force: true });
  setup({ withPlatform: false });
  const result = run("2.0.0");
  expect(result.status).toBe(0);
  expect(readJson(launcherPkg).version).toBe("2.0.0");
  expect(readJson(launcherPkg).optionalDependencies["aiur-cli-linux-x64"]).toBe("2.0.0");
});
