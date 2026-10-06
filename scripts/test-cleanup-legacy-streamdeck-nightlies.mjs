import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const cleanupScript = path.join(root, "scripts/cleanup-legacy-streamdeck-nightlies.mjs");
const workflow = readFileSync(path.join(root, ".github/workflows/streamdeck-package.yml"), "utf8");
const tmp = mkdtempSync(path.join(os.tmpdir(), "aiur-streamdeck-nightly-cleanup-"));

function writeState(statePath, state) {
  writeFileSync(statePath, JSON.stringify(state));
}

function runFixture(releases) {
  const bin = path.join(tmp, "bin");
  const statePath = path.join(tmp, "state.json");
  const fakeGh = path.join(bin, "gh");
  const fakeGhSource = `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const statePath = process.env.FAKE_GH_STATE;
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
if (args[0] === "api" && args.some((arg) => arg.endsWith("/releases"))) {
  for (const release of state.releases) console.log(JSON.stringify([release.tag_name, release.prerelease]));
} else if (args[0] === "api" && args.some((arg) => arg.endsWith("/tags"))) {
  for (const tag of state.tags) console.log(tag);
} else if (args[0] === "release" && args[1] === "delete") {
  const tag = args[2];
  state.deleted.push(tag);
  state.releases = state.releases.filter((release) => release.tag_name !== tag);
  state.tags = state.tags.filter((name) => name !== tag);
  fs.writeFileSync(statePath, JSON.stringify(state));
} else {
  console.error("unexpected gh invocation: " + args.join(" "));
  process.exit(2);
}
`;

  mkdirSync(bin, { recursive: true });
  writeFileSync(fakeGh, fakeGhSource);
  chmodSync(fakeGh, 0o755);
  writeState(statePath, { releases, tags: releases.map((release) => release.tag_name), deleted: [] });

  const result = spawnSync(process.execPath, [cleanupScript], {
    encoding: "utf8",
    env: {
      ...process.env,
      GH_REPO: "aiur-team/aiur",
      FAKE_GH_STATE: statePath,
      PATH: `${bin}:${process.env.PATH}`,
    },
  });

  return { result, state: JSON.parse(readFileSync(statePath, "utf8")) };
}

try {
  const legacy = `streamdeck-${"a".repeat(40)}`;
  const releases = [
    { tag_name: legacy, prerelease: true },
    { tag_name: "streamdeck-nightly", prerelease: true },
    { tag_name: "streamdeck-" + "b".repeat(39), prerelease: true },
    { tag_name: "v0.0.9", prerelease: false },
  ];
  const success = runFixture(releases);
  assert.equal(success.result.status, 0, success.result.stderr);
  assert.deepEqual(success.state.deleted, [legacy]);
  assert.ok(success.state.releases.some((release) => release.tag_name === "streamdeck-nightly"));
  assert.ok(success.state.tags.includes("v0.0.9"));

  const unsafe = runFixture([{ tag_name: legacy, prerelease: false }]);
  assert.notEqual(unsafe.result.status, 0);
  assert.match(unsafe.result.stderr, /refusing to delete non-prerelease/);
  assert.deepEqual(unsafe.state.deleted, []);

  const cleanupCommand = "node scripts/cleanup-legacy-streamdeck-nightlies.mjs";
  const mergeCleanup = workflow.indexOf(cleanupCommand);
  const publishCleanup = workflow.indexOf(cleanupCommand, mergeCleanup + cleanupCommand.length);
  const tagMove = workflow.indexOf('git push --force origin "${COMMIT}:refs/tags/${NIGHTLY_TAG}"');
  assert.ok(workflow.includes("  push:\n    branches:\n      - main"), "main pushes trigger cleanup");
  assert.ok(mergeCleanup >= 0, "main push job runs the cleanup script");
  assert.ok(publishCleanup > mergeCleanup, "nightly publisher runs cleanup too");
  assert.ok(tagMove > publishCleanup, "nightly cleanup runs before moving the rolling tag");

  console.log("streamdeck nightly cleanup tests passed");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
