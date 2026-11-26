import { test, expect } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { captureFile, root, useTempRoot } from "./launcher-support.mjs";
import { runRemoteEngine, setupRemoteLauncher } from "./launcher-remote-support.mjs";

// `gateway join` and `gateway register` run in the shell; B is a stub that answers hello and enrol.
useTempRoot();

const emptyReg = "version: 1\ninstances:\n";
const B = "b".repeat(26);
const OWN = "o".repeat(26);

function startGatewayStub({ hello, enrol }) {
  const script = path.join(root, "gateway-stub.mjs");
  const ready = path.join(root, "gateway-stub.port");
  const log = path.join(root, "gateway-stub.ndjson");
  rmSync(ready, { force: true });
  rmSync(log, { force: true });
  writeFileSync(
    script,
    [
      'import { appendFileSync, writeFileSync } from "node:fs";',
      "const cfg = JSON.parse(process.env.STUB);",
      "const server = Bun.serve({ port: 0, async fetch(req) {",
      "  const url = new URL(req.url); const text = await req.text();",
      "  appendFileSync(process.env.LOG, JSON.stringify({ method: req.method, path: url.pathname, body: text }) + '\\n');",
      "  const r = url.pathname.endsWith('/hello') ? cfg.hello : cfg.enrol;",
      "  return new Response(JSON.stringify(r.body), { status: r.status || 200, headers: { 'content-type': 'application/json' } });",
      "} });",
      "writeFileSync(process.env.READY, String(server.port));",
      "",
    ].join("\n"),
  );
  const proc = Bun.spawn([process.execPath, script], {
    env: { ...process.env, STUB: JSON.stringify({ hello, enrol }), LOG: log, READY: ready },
    stdout: "ignore",
    stderr: "ignore",
  });
  const deadline = Date.now() + 5000;
  while (!existsSync(ready) && Date.now() < deadline) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  const requests = () =>
    existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  return {
    url: `http://127.0.0.1:${readFileSync(ready, "utf8")}`,
    requests,
    enrols: () => requests().filter((r) => r.method === "POST"),
    stop: () => proc.kill(),
  };
}

const code = (url, over = {}) =>
  "aiur-invite:" +
  Buffer.from(
    JSON.stringify({ v: 1, url, gateway_id: B, fp: null, id: "ab12cd34", secret: "aiur_inv_secret", exp: Math.floor(Date.now() / 1000) + 600, ...over }),
  ).toString("base64url");

function withStub(opts, fn) {
  const stub = startGatewayStub(opts);
  try {
    const setup = setupRemoteLauncher(emptyReg);
    mkdirSync(path.join(root, "state", "machine"), { recursive: true });
    writeFileSync(
      path.join(root, "state", "machine", "identity.json"),
      JSON.stringify({ schema_version: 1, machine_id: OWN, machine_label: "Mine", created_at: "2026-01-01T00:00:00Z" }),
    );
    fn(stub, setup);
  } finally {
    stub.stop();
  }
}
const openHello = { body: { gateway_id: B, gateway_label: "B", enrollment: "open" } };
const granted = { body: { gateway_id: B, label: "B", token: "aiur_tok123", granted: ["read"], pending: ["message"] } };
const registryOf = (setup) => readFileSync(path.join(setup.home, ".aiur", "remote-instances.yaml"), "utf8");
const tokenPath = (setup) => path.join(setup.home, ".aiur", "peers", "nook.token");

test("join with a valid code writes the peer entry with its gateway id and a 0600 token file", () => {
  withStub({ hello: openHello, enrol: granted }, (stub, setup) => {
    const r = runRemoteEngine(setup, ["gateway", "join", code(stub.url), "--name", "nook"]);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("pending on nook: message");
    expect(r.stderr).toContain("no TLS pin");
    const reg = registryOf(setup);
    expect(reg).toContain(`gateway_id: "${B}"`);
    expect(reg).not.toContain("tls_pin_sha256");
    expect(readFileSync(tokenPath(setup), "utf8")).toBe("aiur_tok123");
    expect(statSync(tokenPath(setup)).mode & 0o777).toBe(0o600);
    const [post] = stub.enrols();
    expect(JSON.parse(post.body)).toEqual({ id: "ab12cd34", secret: "aiur_inv_secret", gateway_id: OWN, label: "Mine" });
  });
});

test("join refuses a hello that is not the invite's gateway, sending no secret and writing nothing", () => {
  withStub({ hello: { body: { ...openHello.body, gateway_id: "c".repeat(26) } }, enrol: granted }, (stub, setup) => {
    const r = runRemoteEngine(setup, ["gateway", "join", code(stub.url), "--name", "nook"]);
    expect(r.status).toBe(65);
    expect(stub.enrols()).toHaveLength(0);
    expect(registryOf(setup)).toBe(emptyReg);
    expect(existsSync(tokenPath(setup))).toBe(false);
  });
});

test("join writes nothing when B refuses the enrol (used, expired or wrong secret)", () => {
  withStub({ hello: openHello, enrol: { status: 410, body: { error: "invite_used" } } }, (stub, setup) => {
    const r = runRemoteEngine(setup, ["gateway", "join", code(stub.url), "--name", "nook"]);
    expect(r.status).toBe(65);
    expect(r.stderr).toContain("invite_used");
    expect(registryOf(setup)).toBe(emptyReg);
    expect(existsSync(tokenPath(setup))).toBe(false);
  });
});

test("join fails fast on an expired code or an unknown version, before any request", () => {
  withStub({ hello: openHello, enrol: granted }, (stub, setup) => {
    const old = runRemoteEngine(setup, ["gateway", "join", code(stub.url, { exp: 1 }), "--name", "nook"]);
    expect(old.status).toBe(65);
    expect(old.stderr).toContain("expired");
    const v2 = runRemoteEngine(setup, ["gateway", "join", code(stub.url, { v: 2 }), "--name", "nook"]);
    expect(v2.status).toBe(64);
    expect(v2.stderr).toContain("unsupported invite version");
    expect(stub.requests()).toHaveLength(0);
  });
});

test("register adds an entry with no invite and no tailscale, and refuses a duplicate name", () => {
  const setup = setupRemoteLauncher(emptyReg);
  const tokenFile = path.join(root, "pc.token");
  writeFileSync(tokenFile, "aiur_manual", { mode: 0o600 });
  const args = ["gateway", "register", "pc", "--url", "http://127.0.0.1:4001", "--token-file", tokenFile];
  expect(runRemoteEngine(setup, args).status).toBe(0);
  expect(registryOf(setup)).toContain(`  pc:\n    url: "http://127.0.0.1:4001"\n    token_file: "${tokenFile}"`);
  expect(runRemoteEngine(setup, args).status).toBe(64);
});

test("invite, join, register, remove and rotate are refused over --gateway with exit 64", () => {
  const reg = `version: 1\ninstances:\n  nook:\n    url: http://127.0.0.1:1\n    token_env: AIUR_TOKEN_T\n    gateway_id: ${B}\n`;
  const setup = setupRemoteLauncher(reg);
  rmSync(captureFile, { force: true });
  for (const verb of ["invite", "join", "register", "remove", "rotate"]) {
    const r = runRemoteEngine(setup, ["--gateway", "nook", "gateway", verb, "x"]);
    expect(r.status).toBe(64);
    expect(r.stderr).toContain(`${verb} is local to the gateway it changes`);
  }
});
