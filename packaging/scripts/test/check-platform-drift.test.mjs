import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realScript = fileURLToPath(new URL("../check-platform-drift.mjs", import.meta.url));

const DEFAULT = ["linux-x64", "linux-arm64", "darwin-arm64"];

let root;

function writeJson(p, obj) {
  mkdirSync(path.dirname(p), { recursive: true });
  writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
}

function workflowWith(matrixTargets, loopLists) {
  const entries = matrixTargets.map((t) => `          - runner: placeholder\n            target: ${t}`);
  const loops = loopLists
    .map(
      (list, i) => `      - name: Loop ${i}
        run: |
          for t in ${list.join(" ")}; do
            npm publish "artifacts/aiur-cli-$t"/*.tgz --access public
          done`,
    )
    .join("\n");
  return `name: release-npm
jobs:
  build:
    strategy:
      matrix:
        include:
${entries.join("\n")}
  smoke:
    strategy:
      matrix:
        include:
${entries.join("\n")}
  publish:
    steps:
${loops}
`;
}

// Build an isolated repo-shaped fixture and run a copy of the drift check
// inside it. Each list can be overridden independently to simulate the ways the
// publish/pin sets drift apart.
function setup({
  publish = DEFAULT, // PUBLISH_TARGETS in the copied platforms.mjs
  pinned = publish, // optionalDependencies in the copied launcher package.json
  matrix = publish, // build/smoke matrix targets in the copied workflow
  loops = [publish, publish], // each `for t in …` publish loop in the workflow
} = {}) {
  root = mkdtempSync(path.join(tmpdir(), "aiur-drift-"));
  const scriptsDir = path.join(root, "packaging", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  copyFileSync(realScript, path.join(scriptsDir, "check-platform-drift.mjs"));
  writeFileSync(
    path.join(scriptsDir, "platforms.mjs"),
    `// fixture\nexport const PUBLISH_TARGETS = ${JSON.stringify(publish)};\n`,
  );

  writeJson(path.join(root, "packaging", "npm", "aiur-cli", "package.json"), {
    name: "aiur-cli",
    version: "0.0.5",
    optionalDependencies: Object.fromEntries(pinned.map((t) => [`aiur-cli-${t}`, "0.0.5"])),
  });

  const workflowPath = path.join(root, ".github", "workflows", "release-npm.yml");
  mkdirSync(path.dirname(workflowPath), { recursive: true });
  writeFileSync(workflowPath, workflowWith(matrix, loops));
}

function run() {
  const script = path.join(root, "packaging", "scripts", "check-platform-drift.mjs");
  return spawnSync(process.execPath, [script], { encoding: "utf8" });
}

beforeEach(() => {
  root = undefined;
});
afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true });
});

test("passes when pinned, published, and PUBLISH_TARGETS agree", () => {
  setup();
  const result = run();
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("OK");
  expect(result.stdout).toContain("darwin-arm64");
});

test("fails when a platform is pinned but never published (the #2110 shape)", () => {
  // aiur-cli-darwin-x64 was pinned but absent from the publish loop: Intel Mac
  // installs succeeded into a runtime with no binary.
  setup({ pinned: [...DEFAULT, "darwin-x64"] });
  const result = run();
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("drift");
  expect(result.stderr).toContain("darwin-x64");
  expect(result.stderr).toContain("optionalDependencies");
});

test("fails when a platform is published but never pinned", () => {
  setup({ matrix: [...DEFAULT, "darwin-x64"], loops: [[...DEFAULT, "darwin-x64"], [...DEFAULT, "darwin-x64"]] });
  const result = run();
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("drift");
  expect(result.stderr).toContain("darwin-x64");
});

test("fails when a single publish loop drifts even though the matrix is correct", () => {
  // The check must evaluate each loop independently, not union them: a platform
  // dropped from one publish loop while present elsewhere must be caught.
  setup({ loops: [DEFAULT, [...DEFAULT, "darwin-x64"]] });
  const result = run();
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("drift");
  expect(result.stderr).toContain("darwin-x64");
});

test("fails when the shared PUBLISH_TARGETS source diverges from both", () => {
  setup({ publish: [...DEFAULT, "darwin-x64"], pinned: DEFAULT, matrix: DEFAULT, loops: [DEFAULT, DEFAULT] });
  const result = run();
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("drift");
  expect(result.stderr).toContain("PUBLISH_TARGETS");
});

test("passes against the real repo (committed state is drift-free)", () => {
  // Run the actual script, whose repoRoot resolves to this repository, not the
  // fixture. This is the same assertion CI makes.
  const result = spawnSync(process.execPath, [realScript], { encoding: "utf8" });
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("OK");
});
