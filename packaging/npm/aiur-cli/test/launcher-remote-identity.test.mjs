import { test, expect } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { useTempRoot } from "./launcher-support.mjs";
import {
  registry,
  runRemote,
  setupRemoteLauncher,
  startServer,
  successBody,
} from "./launcher-remote-support.mjs";

useTempRoot();

const A = "a".repeat(26);
const B = "b".repeat(26);
const body = (id) => ({ ...successBody("secret-output\n__AIUR_CONTROL_EXIT__:0\n"), ...(id === undefined ? {} : { gateway_id: id }) });
const marker = (setup, name = "t") => path.join(setup.home, ".aiur", "remote-state", "seen-gateway", name);

function withServer(id, extraRegistry, fn, args = ["--instance", "t", "status"]) {
  const server = startServer({ body: body(id) });
  try {
    const setup = setupRemoteLauncher(registry(server.url, `token_env: AIUR_TOKEN_T\n${extraRegistry}`));
    return fn(setup, runRemote(setup, args), server);
  } finally {
    server.stop();
  }
}

test("a pinned gateway_id that the server contradicts exits 77 and withholds output", () => {
  withServer(B, `    gateway_id: ${A}\n`, (_setup, result) => {
    expect(result.status).toBe(77);
    expect(result.stderr.split("\n")[0]).toBe("aiur: gateway identity mismatch for 't'");
    expect(result.stderr).toContain("may have run");
    expect(result.stdout).not.toContain("secret-output");
  });
});

test("a pinned gateway_id that matches prints output silently and writes no marker", () => {
  withServer(A, `    gateway_id: ${A}\n    label: Nook\n`, (setup, result) => {
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("secret-output\n");
    expect(result.stderr).toBe("");
    expect(existsSync(marker(setup))).toBe(false);
  });
});

test("a pinned entry refuses a response that carries no gateway_id", () => {
  for (const id of [undefined, null]) {
    withServer(id, `    gateway_id: ${A}\n`, (_setup, result) => {
      expect(result.status).toBe(77);
      expect(result.stderr).toContain("gateway identity unverified for 't'");
      expect(result.stdout).not.toContain("secret-output");
    });
  }
});

test("an unpinned entry prints the pin line once and leaves the registry untouched", () => {
  const server = startServer({ body: body(A) });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const file = path.join(setup.home, ".aiur", "remote-instances.yaml");
    const before = readFileSync(file, "utf8");
    const first = runRemote(setup, ["--instance", "t", "status"]);
    expect(first.status).toBe(0);
    expect(first.stdout).toBe("secret-output\n");
    expect(first.stderr).toContain(`gateway ${A}`);
    expect(first.stderr).toContain(`\n    gateway_id: ${A}\n`);
    expect(readFileSync(marker(setup), "utf8")).toBe(A);
    expect(readFileSync(file, "utf8")).toBe(before);

    const second = runRemote(setup, ["--instance", "t", "status"]);
    expect(second.status).toBe(0);
    expect(second.stderr).toBe("");

    server.stop();
    const other = startServer({ body: body(B) });
    try {
      writeFileSync(file, registry(other.url));
      const drift = runRemote(setup, ["--instance", "t", "status"]);
      expect(drift.status).toBe(0);
      expect(drift.stderr).toContain(`answers as gateway ${B}`);
      expect(drift.stderr).toContain(`answered as ${A} before`);
      expect(readFileSync(marker(setup), "utf8")).toBe(A);
    } finally {
      other.stop();
    }
  } finally {
    server.stop();
  }
});

test("an unpinned entry whose server reports no id behaves as before", () => {
  withServer(undefined, "", (setup, result) => {
    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    expect(existsSync(marker(setup))).toBe(false);
  });
});

test("allows blocks, label and tls_pin_sha256 parse; bad values are rejected with the line", () => {
  const extra = `    label: Nook\n    tls_pin_sha256: ${"0".repeat(64)}\n    allows:\n      categories: [read, bogus]\n      credentials:\n        - id: x\n`;
  withServer(undefined, extra, (_setup, result) => {
    expect(result.status).toBe(0);
  });
  for (const bad of ["    gateway_id: short\n", `    tls_pin_sha256: ABCD\n`, `    gateway_id: ${A}\n    gateway_id: ${A}\n`]) {
    withServer(undefined, bad, (_setup, result) => {
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("invalid remote instance registry");
    });
  }
});

test("--instance all isolates a mismatching row and keeps per-instance markers", () => {
  const a = startServer({ name: "a", body: body(A) });
  const b = startServer({ name: "b", body: body(B) });
  try {
    const yaml = `version: 1\ninstances:\n  a:\n    url: ${a.url}\n    token_env: AIUR_TOKEN_T\n    gateway_id: ${A}\n  b:\n    url: ${b.url}\n    token_env: AIUR_TOKEN_T\n    gateway_id: ${A}\n`;
    const setup = setupRemoteLauncher(yaml);
    const result = runRemote(setup, ["--instance", "all", "status"]);
    expect(result.status).toBe(77);
    expect(result.stdout + result.stderr).toContain("gateway identity mismatch for 'b'");
    expect(result.stdout + result.stderr).toContain("secret-output");
  } finally {
    a.stop();
    b.stop();
  }
});
