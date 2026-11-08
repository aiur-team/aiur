import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { runRemoteEngine, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

const entry = (name, url, id, label) =>
  `  ${name}:\n    url: ${url}\n    token_env: AIUR_TOKEN_T\n    gateway_id: ${id}\n${label ? `    label: ${label}\n` : ""}`;
const ID = { a: "a".repeat(26), b: "b".repeat(26), c: "c".repeat(26) };

// Server i answers with the i-th gateway id, as a pinned entry requires.
function withServers(count, body, fn) {
  const ids = [ID.a, ID.b, ID.c];
  const servers = Array.from({ length: count }, (_, i) =>
    startServer({ name: `gw${i}`, body: { ...successBody(body), gateway_id: ids[i] } }),
  );
  try {
    fn(servers);
  } finally {
    servers.forEach((s) => s.stop());
  }
}
const total = (servers) => servers.reduce((n, s) => n + s.requests().length, 0);
const run = (reg, args) => {
  const setup = setupRemoteLauncher(reg);
  rmSync(captureFile, { force: true });
  return runRemoteEngine(setup, args);
};

test("--gateway resolves a label case-insensitively, a name, and an id", () => {
  withServers(2, "ok\n__AIUR_CONTROL_EXIT__:0\n", ([s1, s2]) => {
    const reg = `version: 1\ninstances:\n${entry("nook", s1.url, ID.a, "Nook")}${entry("pc", s2.url, ID.b, "PC")}`;
    for (const sel of ["Nook", "nOOk", ID.a.toUpperCase()]) {
      expect(run(reg, ["--gateway", sel, "status"]).status).toBe(0);
    }
    expect(s1.requests()).toHaveLength(3);
    expect(run(reg, ["--gateway=pc", "status"]).status).toBe(0);
    expect(s2.requests()).toHaveLength(1);
    const prefix = run(reg, ["--gateway", "aaaa", "status"]);
    expect(prefix.status).toBe(64);
    expect(prefix.stderr).toContain("unknown gateway 'aaaa'");
    expect(total([s1, s2])).toBe(4);
  });
});

test("--gateway refuses an ambiguous selector without any request", () => {
  withServers(2, "ok\n__AIUR_CONTROL_EXIT__:0\n", ([s1, s2]) => {
    const reg = `version: 1\ninstances:\n${entry("nook", s1.url, ID.a, "Home")}${entry("lab", s2.url, ID.b, "nook")}`;
    const result = run(reg, ["--gateway", "nook", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("ambiguous");
    expect(result.stderr.indexOf("  nook  (name)")).toBeGreaterThan(-1);
    expect(result.stderr.indexOf('  lab  (label "nook")')).toBeGreaterThan(result.stderr.indexOf("  nook  (name)"));
    expect(total([s1, s2])).toBe(0);
    // --instance stays an exact name lookup.
    expect(run(reg, ["--instance", "nook", "status"]).status).toBe(0);
    expect(s1.requests()).toHaveLength(1);
    // one entry matching by name and label is not ambiguous
    const same = `version: 1\ninstances:\n${entry("pc", s1.url, ID.a, "PC")}`;
    expect(run(same, ["--gateway", "pc", "status"]).status).toBe(0);
  });
});

test("--gateway local runs locally, even with no registry match", () => {
  withServers(1, "ok\n__AIUR_CONTROL_EXIT__:0\n", ([s1]) => {
    const reg = `version: 1\ninstances:\n  local:\n    url: ${s1.url}\n    token_env: AIUR_TOKEN_T\n`;
    const result = run(reg, ["--gateway", "local", "status"]);
    expect(result.status).toBe(0);
    expect(readFileSync(captureFile, "utf8")).toContain("LOCAL_EXPR:Aiur.AgentControlCLI.status()");
    expect(s1.requests()).toHaveLength(0);
    expect(run(reg, ["--instance", "local", "status"]).status).toBe(0);
    expect(s1.requests()).toHaveLength(1);
  });
});

test("--gateway rejects two selectors, empty values, stop, and awk-special labels", () => {
  withServers(1, "ok\n__AIUR_CONTROL_EXIT__:0\n", ([s1]) => {
    const reg = `version: 1\ninstances:\n${entry("nook", s1.url, ID.a, "a\\tb \"q\"")}`;
    for (const args of [
      ["--gateway", "nook", "--instance", "nook", "status"],
      ["--instance", "nook", "--gateway", "nook", "status"],
      ["--gateway=a", "--gateway=b", "status"],
    ]) {
      const r = run(reg, args);
      expect(r.status).toBe(64);
      expect(r.stderr).toContain("use one of --gateway or --instance");
    }
    for (const args of [["--gateway="], ["--gateway"]]) {
      const r = run(reg, args);
      expect(r.status).toBe(64);
      expect(r.stderr).toContain("--gateway requires a name");
    }
    const stop = run(reg, ["--gateway", "nook", "stop"]);
    expect(stop.status).toBe(64);
    expect(stop.stderr).toContain("stop is local to the gateway's host; run it there");
    expect(run(reg, ["--instance", "nook", "stop"]).stderr).toContain("stop is local to the instance's host\n");
    const reload = run(reg, ["--gateway", "nook", "gateway", "reload"]);
    expect(reload.status).toBe(64);
    expect(reload.stderr).toContain("gateway is local to the gateway's host; run it there");
    expect(total([s1])).toBe(0);
    expect(run(reg, ["--gateway", 'a\\tb "q"', "status"]).status).toBe(0);
    expect(s1.requests()).toHaveLength(1);
    expect(existsSync(captureFile)).toBe(false);
  });
});

test("aiurdev --gateway local refuses a following selector with exit 64", () => {
  const shim = new URL("../../../../scripts/aiurdev", import.meta.url).pathname;
  for (const rest of [["--instance", "pc"], ["--instance=pc"], ["--gateway", "pc"], ["--gateway=pc"]]) {
    const r = spawnSync(shim, ["--gateway", "local", ...rest, "status"], { encoding: "utf8", timeout: 20000 });
    expect(r.status).toBe(64);
    expect(r.stderr).toContain("use one of --gateway or --instance");
  }
});
