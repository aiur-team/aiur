import { test, expect } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { root, useTempRoot } from "./launcher-support.mjs";
import {
  registry,
  runRemote,
  setupRemoteLauncher,
  startServer,
  successBody,
} from "./launcher-remote-support.mjs";

useTempRoot();

const A = "a".repeat(26);

test("an inbound-only entry is not callable and --instance all skips it", () => {
  const server = startServer({ body: successBody() });
  try {
    const yaml = `${registry(server.url)}  peer:\n    gateway_id: ${A}\n    allows:\n      categories: [read]\n`;
    const setup = setupRemoteLauncher(yaml);
    const direct = runRemote(setup, ["--instance", "peer", "status"]);
    expect(direct.status).toBe(64);
    expect(direct.stderr).toContain("remote instance 'peer' is inbound-only (no url)");
    expect(server.requests()).toHaveLength(0);

    const all = runRemote(setup, ["--instance", "all", "status"]);
    expect(all.status).toBe(0);
    expect(all.stdout + all.stderr).not.toContain("peer");
    expect(server.requests()).toHaveLength(1);
  } finally {
    server.stop();
  }
});

// Self-signed HTTPS server; the pin is the sha256 of its public key (SPKI), as hex.
function tlsServer() {
  const dir = path.join(root, "tls");
  execFileSync("mkdir", ["-p", dir]);
  const key = path.join(dir, "key.pem");
  const cert = path.join(dir, "cert.pem");
  execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
    "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
  const pub = execFileSync("openssl", ["x509", "-in", cert, "-pubkey", "-noout"]);
  const der = execFileSync("openssl", ["pkey", "-pubin", "-outform", "der"], { input: pub });
  const pin = execFileSync("openssl", ["dgst", "-sha256", "-binary"], { input: der }).toString("hex");
  const script = path.join(dir, "server.mjs");
  const ready = path.join(dir, "port");
  writeFileSync(script, [
    'import { writeFileSync, readFileSync } from "node:fs";',
    `const body = JSON.stringify(${JSON.stringify(successBody())});`,
    `const server = Bun.serve({ port: 0, tls: { key: Bun.file(${JSON.stringify(key)}), cert: Bun.file(${JSON.stringify(cert)}) },`,
    "  fetch() { return new Response(body, { headers: { 'content-type': 'application/json' } }); } });",
    `writeFileSync(${JSON.stringify(ready)}, String(server.port));`,
  ].join("\n"));
  const proc = Bun.spawn([process.execPath, script], { stdout: "ignore", stderr: "ignore" });
  const deadline = Date.now() + 5000;
  while (!existsSync(ready) && Date.now() < deadline) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  if (!existsSync(ready)) throw new Error("tls server did not start");
  return { url: `https://127.0.0.1:${readFileSync(ready, "utf8")}`, pin, stop: () => proc.kill() };
}

const hasOpenssl = (() => { try { execFileSync("openssl", ["version"], { stdio: "ignore" }); return true; } catch { return false; } })();
const tlsTest = hasOpenssl ? test : test.skip;

tlsTest("tls_pin_sha256 accepts the matching public key and refuses a different one", () => {
  const server = tlsServer();
  try {
    const right = setupRemoteLauncher(registry(server.url, `token_env: AIUR_TOKEN_T\n    tls_pin_sha256: ${server.pin}`));
    const ok = runRemote(right, ["--instance", "t", "status"]);
    expect(ok.status).toBe(0);
    expect(ok.stdout).toBe("ok\n");

    const wrong = setupRemoteLauncher(registry(server.url, `token_env: AIUR_TOKEN_T\n    tls_pin_sha256: ${"0".repeat(64)}`));
    const bad = runRemote(wrong, ["--instance", "t", "status"]);
    expect(bad.status).toBe(69);
    expect(bad.stdout).not.toContain("ok");

    // Without a pin, normal CA verification applies and the self-signed endpoint is refused.
    const none = setupRemoteLauncher(registry(server.url));
    expect(runRemote(none, ["--instance", "t", "status"]).status).toBe(69);
  } finally {
    server.stop();
  }
});
