import { test, expect } from "bun:test";
import { chmodSync, writeFileSync } from "node:fs";
import path from "node:path";
import { useTempRoot } from "./launcher-support.mjs";
import { runRemote, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

const registry = (instances) =>
  ["version: 1", "instances:", ...Object.entries(instances).flatMap(([n, url]) => [`  ${n}:`, `    url: ${url}`, "    token_env: AIUR_TOKEN_T"]), ""].join("\n");

// The local daemon's reply: whether the shared store took the change, plus the encoded change to relay.
function setup(instances) {
  const s = setupRemoteLauncher(registry(instances));
  const release = path.join(s.releaseDir, "bin", "aiur");
  writeFileSync(
    release,
    [
      "#!/usr/bin/env bash",
      'if [ "$1" = rpc ]; then',
      '  printf "LOCAL_EXPR:%s\\n" "$2" >>"$AIUR_TEST_OUT"',
      '  printf "AIUR_FLEET_CHANGE %s Zm9v\\n__AIUR_CONTROL_EXIT__:0\\n" "${AIUR_FAKE_FLEET_STORE:-stored}"',
      "fi",
      "",
    ].join("\n"),
  );
  chmodSync(release, 0o755);
  return s;
}

test("pause --all-gateways labels a reachable gateway paused now and an offline one will pause on reconnect", () => {
  const live = startServer({ name: "live", body: successBody("applied\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const result = runRemote(setup({ live: live.url, offline: "http://127.0.0.1:1" }), ["pause", "--all-gateways"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("live: paused now");
    expect(result.stdout).toMatch(/offline: will pause on reconnect/);
    expect(live.requests()[0].body.expression).toContain("apply_fleet_pause_change");
  } finally {
    live.stop();
  }
}, 30_000);

test("store down and gateway unreachable is unknown and exits 69; store down but gateway reachable still pauses it", () => {
  const live = startServer({ name: "live", body: successBody("applied\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const env = { AIUR_FAKE_FLEET_STORE: "unstored" };
    const down = runRemote(setup({ live: live.url, offline: "http://127.0.0.1:1" }), ["pause", "--all-gateways"], env);
    expect(down.status).toBe(69);
    expect(down.stdout).toContain("live: paused now");
    expect(down.stdout).toMatch(/offline: unknown/);
  } finally {
    live.stop();
  }
}, 30_000);
