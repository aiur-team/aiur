#!/usr/bin/env node
// Assert the aiur-cli platform packages stay in lockstep: the set pinned in the
// launcher's optionalDependencies must equal the set the release workflow
// builds and publishes, and both must equal PUBLISH_TARGETS (the single source
// of truth in packaging/scripts/platforms.mjs).
//
// A pin with no published package is a silent broken install — aiur-cli pinned
// aiur-cli-darwin-x64@0.0.4/0.0.5 which was never published, so Intel Mac
// installs succeeded into a runtime with no binary (#2110). A published package
// with no pin is dead weight. CI and the release setup run this so the two
// lists cannot drift apart again.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PUBLISH_TARGETS } from "./platforms.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const launcherPkgPath = path.join(repoRoot, "packaging", "npm", "aiur-cli", "package.json");
const workflowPath = path.join(repoRoot, ".github", "workflows", "release-npm.yml");
const PIN_PREFIX = "aiur-cli-";

function fail(message) {
  process.stderr.write(`check-platform-drift: ${message}\n`);
  process.exit(1);
}

// The set pinned in the launcher's optionalDependencies (the `aiur-cli-*`
// keys). This is what a user's `npm install -g aiur-cli` resolves.
function pinnedTargets() {
  const pkg = JSON.parse(readFileSync(launcherPkgPath, "utf8"));
  const deps = pkg.optionalDependencies ?? {};
  return Object.keys(deps)
    .filter((k) => k.startsWith(PIN_PREFIX))
    .map((k) => k.slice(PIN_PREFIX.length))
    .sort();
}

// The `target:` triples in the release workflow's build/smoke matrices — the
// platforms the workflow actually compiles into platform packages. Commented
// entries (`#   target: …`) are ignored.
function matrixTargets() {
  const text = readFileSync(workflowPath, "utf8");
  const targets = new Set();
  for (const line of text.split("\n")) {
    const m = /^\s+target:\s*([a-z0-9-]+)\s*$/.exec(line);
    if (m) targets.add(m[1]);
  }
  return [...targets].sort();
}

// Every `for t in <triples>; do` loop in the release workflow — the lists the
// workflow publishes and artifact-checks. Returned per loop (not unioned) so a
// single drifting loop is reported instead of masked.
function publishLoopTargets() {
  const text = readFileSync(workflowPath, "utf8");
  const loops = [];
  for (const line of text.split("\n")) {
    const m = /^\s*for t in ([\w-]+(?:\s+[\w-]+)*); do\s*$/.exec(line);
    if (m) loops.push(m[1].split(" ").sort());
  }
  return loops;
}

function describe(targets) {
  return targets.length ? targets.join(", ") : "(none)";
}

const expected = [...PUBLISH_TARGETS].sort();
const problems = [];

const pinned = pinnedTargets();
if (pinned.join(" ") !== expected.join(" ")) {
  problems.push(
    `launcher optionalDependencies pin [${describe(pinned)}] != PUBLISH_TARGETS [${describe(expected)}]`,
  );
}

const matrix = matrixTargets();
if (matrix.join(" ") !== expected.join(" ")) {
  problems.push(
    `release workflow matrix targets [${describe(matrix)}] != PUBLISH_TARGETS [${describe(expected)}]`,
  );
}

for (const loop of publishLoopTargets()) {
  if (loop.join(" ") !== expected.join(" ")) {
    problems.push(
      `release workflow 'for t in' loop [${loop.join(" ")}] != PUBLISH_TARGETS [${describe(expected)}]`,
    );
  }
}

if (problems.length) {
  fail(
    "platform publish/pin drift:\n  - " +
      problems.join("\n  - ") +
      "\nThe platform packages the release workflow publishes must equal the packages pinned " +
      "in packaging/npm/aiur-cli/package.json. Update packaging/scripts/platforms.mjs and " +
      ".github/workflows/release-npm.yml together; see issue #2110.",
  );
}

process.stdout.write(
  `check-platform-drift: OK — pinned, published, and PUBLISH_TARGETS all agree: ${describe(expected)}\n`,
);
