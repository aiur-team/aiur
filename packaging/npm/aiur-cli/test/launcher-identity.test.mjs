import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, statSync, chmodSync } from "node:fs";
import path from "node:path";
import { captureFile, root, useTempRoot } from "./launcher-support.mjs";
import { setupControlRpc } from "./launcher-control-support.mjs";

useTempRoot();

const ID = "abcdefghijklmnopqrstuvwxyz".slice(0, 26).replace(/[^a-z2-7]/g, "a");
const gwKey = (id) => "gw-" + createHash("sha256").update(id).digest("hex").slice(0, 10);

// A HOME with ~/.aiur/machine (given body) and, optionally, an identity file.
function fixture(machine, { identity = true } = {}) {
  const home = path.join(root, "home");
  const state = path.join(home, ".config", "aiur");
  mkdirSync(path.join(home, ".aiur"), { recursive: true });
  mkdirSync(path.join(root, "repo", ".aiur"), { recursive: true });
  writeFileSync(path.join(root, "repo", ".aiur", "config"), "");
  if (machine !== null) writeFileSync(path.join(home, ".aiur", "machine"), machine);
  if (identity) {
    mkdirSync(path.join(state, "machine"), { recursive: true, mode: 0o700 });
    writeFileSync(path.join(state, "machine", "identity.json"), JSON.stringify({ schema_version: 1, machine_id: ID }));
  }
  return { home, state };
}

function identity(launcher, home, cwd, env = {}) {
  const e = { ...process.env, HOME: home, ...env };
  for (const k of ["AIUR_INSTANCE_KEY", "AIUR_BG_STATE_DIR", "AIUR_RELEASE_NODE", "AIUR_REPO_ROOT", "AIUR_GATEWAY_MODE", "XDG_CONFIG_HOME"]) if (!(k in env)) delete e[k];
  const r = spawnSync(launcher, ["__identity"], { encoding: "utf8", env: e, cwd });
  return Object.fromEntries(r.stdout.split("\n").filter(Boolean).map((l) => l.split(/=(.*)/s).slice(0, 2)));
}

const PROJECTS = "projects:\n  - repo: o/a\n    config: /x/.aiur/config\n";
const launcherOf = () => setupControlRpc().launcher;

test("L1 gateway key is the same from any directory", () => {
  const { home } = fixture(PROJECTS);
  const launcher = launcherOf();
  const a = identity(launcher, home, "/tmp");
  const b = identity(launcher, home, path.join(root, "repo"));
  expect(a.AIUR_INSTANCE_KEY).toBe(gwKey(ID));
  expect(b.AIUR_INSTANCE_KEY).toBe(gwKey(ID));
  expect(a.AIUR_PROJECT_ROOT_SOURCE).toBe("gateway");
});

test("L3 without projects the key is the cwd-derived one", () => {
  const launcher = launcherOf();
  for (const machine of [null, "projects: []\n", "projects:\nmobile:\n  x: 1\n"]) {
    const { home } = fixture(machine);
    const r = identity(launcher, home, path.join(root, "repo"));
    expect(r.AIUR_INSTANCE_KEY).toMatch(/^[a-f0-9]{10}$/);
    expect(r.AIUR_PROJECT_ROOT_SOURCE).toBe("repo");
  }
});

test("L4/L5 explicit key and AIUR_GATEWAY_MODE=0 beat gateway mode", () => {
  const { home } = fixture(PROJECTS);
  const launcher = launcherOf();
  expect(identity(launcher, home, "/tmp", { AIUR_INSTANCE_KEY: "test-x" }).AIUR_INSTANCE_KEY).toBe("test-x");
  expect(identity(launcher, home, "/tmp", { AIUR_GATEWAY_MODE: "0" }).AIUR_INSTANCE_KEY).toMatch(/^[a-f0-9]{10}$/);
});

test("L6 identity is created once, 0600 in a 0700 dir, in the Store shape", () => {
  const { home, state } = fixture(PROJECTS, { identity: false });
  const launcher = launcherOf();
  const first = identity(launcher, home, "/tmp").AIUR_INSTANCE_KEY;
  const file = path.join(state, "machine", "identity.json");
  const body = JSON.parse(readFileSync(file, "utf8"));
  expect(body.machine_id).toMatch(/^[a-z2-7]{26}$/);
  expect(body.schema_version).toBe(1);
  expect(statSync(file).mode & 0o777).toBe(0o600);
  expect(statSync(path.dirname(file)).mode & 0o777).toBe(0o700);
  expect(first).toBe(gwKey(body.machine_id));
  expect(identity(launcher, home, "/tmp").AIUR_INSTANCE_KEY).toBe(first);
});

test("L2 aiur status from /tmp reaches the gateway daemon", () => {
  const { home } = fixture(PROJECTS);
  const { launcher, releaseDir } = setupControlRpc();
  const node = `aiur-${process.env.USER}-${gwKey(ID)}`;
  const epmd = path.join(releaseDir, "erts-15.0", "bin", "epmd");
  writeFileSync(epmd, `#!/usr/bin/env bash\n[ "$1" = "-names" ] && { echo "epmd: up"; echo "name ${node} at port 12345"; }\nexit 0\n`);
  chmodSync(epmd, 0o755);
  const env = { ...process.env, HOME: home, AIUR_RELEASE_DIR: releaseDir, AIUR_TEST_OUT: captureFile, AIUR_FAKE_RPC_MODE: "ok" };
  for (const k of ["AIUR_INSTANCE_KEY", "AIUR_BG_STATE_DIR", "AIUR_RELEASE_NODE", "AIUR_REPO_ROOT", "XDG_CONFIG_HOME"]) delete env[k];
  const r = spawnSync(launcher, ["status"], { encoding: "utf8", env, cwd: "/tmp" });
  expect(r.status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("RPC_EXPR:");
});
