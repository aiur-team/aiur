import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import {
  HOST_TRIPLE,
  captureFile,
  root,
  runShim,
  setupPackage,
  setupRealLauncher,
} from "./launcher-support.mjs";

const sleep = (milliseconds) =>
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);

export function setupRemoteLauncher(registry) {
  const { fakeBin } = setupPackage({ tmuxVersion: null, withOpencode: false });
  const { launcher, releaseDir: fixtureReleaseDir } = setupRealLauncher();
  const releaseDir = path.join(root, "node_modules", `aiur-cli-${HOST_TRIPLE}`, "release");
  rmSync(releaseDir, { recursive: true, force: true });
  cpSync(fixtureReleaseDir, releaseDir, { recursive: true });
  const home = path.join(root, "home");
  mkdirSync(path.join(home, ".aiur"), { recursive: true });
  writeFileSync(path.join(home, ".aiur", "remote-instances.yaml"), registry);

  const release = path.join(releaseDir, "bin", "aiur");
  writeFileSync(
    release,
    [
      "#!/usr/bin/env bash",
      'if [ "$1" = rpc ]; then',
      '  printf "LOCAL_EXPR:%s\\n" "$2" >>"$AIUR_TEST_OUT"',
      '  printf ":ok\\n__AIUR_CONTROL_EXIT__:0\\n"',
      "fi",
      "",
    ].join("\n"),
  );
  chmodSync(release, 0o755);

  return { fakeBin, home, launcher, releaseDir };
}

export function runRemote(setup, args, env = {}) {
  const home = env.HOME || setup.home;
  const remoteState = path.join(home, ".aiur", "remote-state");
  mkdirSync(remoteState, { recursive: true });
  return runShim({
    args,
    fakeBin: setup.fakeBin,
    env: {
      HOME: home,
      PATH: `${setup.fakeBin}:${process.env.PATH}`,
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_TEST_OUT: captureFile,
      AIUR_TOKEN_T: "remote-secret-token",
      AIUR_REMOTE_STATE_DIR: remoteState,
      ...env,
    },
  });
}

export function runRemoteEngine(setup, args, env = {}) {
  return spawnSync(setup.launcher, args, {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: setup.home,
      PATH: `${setup.fakeBin}:${process.env.PATH}`,
      AIUR_JS_RUNTIME: process.execPath,
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_RELEASE_DIR: setup.releaseDir,
      AIUR_TEST_OUT: captureFile,
      AIUR_TOKEN_T: "remote-secret-token",
      ...env,
    },
  });
}

export function startServer({ name = "default", status = 200, body, barrierFile, barrierCount = 0, onRequest }) {
  if (!/^[a-z0-9-]+$/.test(name)) throw new Error(`invalid fake server name: ${name}`);
  const serverScript = path.join(root, `remote-server-${name}.mjs`);
  const readyFile = path.join(root, `remote-server-${name}.port`);
  const requestFile = path.join(root, `remote-requests-${name}.ndjson`);
  rmSync(readyFile, { force: true });
  rmSync(requestFile, { force: true });
  writeFileSync(
    serverScript,
    [
      'import { appendFileSync, readFileSync, writeFileSync } from "node:fs";',
      "const response = JSON.parse(process.env.AIUR_TEST_RESPONSE);",
      "const server = Bun.serve({",
      "  port: 0,",
      "  async fetch(request) {",
      "    const requestBody = await request.text();",
      "    appendFileSync(process.env.AIUR_TEST_REQUESTS, JSON.stringify({",
      "      authorization: request.headers.get('authorization'),",
      "      body: JSON.parse(requestBody),",
      "    }) + '\\n');",
      "    if (process.env.AIUR_TEST_ON_REQUEST) {",
      "      const countFile = process.env.AIUR_TEST_REQUEST_COUNT_FILE;",
      "      let count = 0; try { count = Number(readFileSync(countFile, 'utf8')); } catch (_) {}",
      "      writeFileSync(countFile, String(count + 1));",
      "      const handler = (await import(process.env.AIUR_TEST_ON_REQUEST)).default;",
      "      const dynamic = await handler(JSON.parse(requestBody), count + 1);",
      "      if (dynamic) return new Response(JSON.stringify(dynamic.body), { status: dynamic.status || 200, headers: { 'content-type': 'application/json' } });",
      "    }",
      "    if (process.env.AIUR_TEST_BARRIER) {",
      "      appendFileSync(process.env.AIUR_TEST_BARRIER, process.env.AIUR_TEST_SERVER_NAME + '\\n');",
      "      const deadline = Date.now() + 5000;",
      "      while (readFileSync(process.env.AIUR_TEST_BARRIER, 'utf8').trim().split('\\n').filter(Boolean).length < Number(process.env.AIUR_TEST_BARRIER_COUNT)) {",
      "        if (Date.now() >= deadline) return new Response('barrier timed out', { status: 500 });",
      "        await Bun.sleep(10);",
      "      }",
      "    }",
      "    return new Response(JSON.stringify(response.body), {",
      "      status: response.status,",
      "      headers: { 'content-type': 'application/json' },",
      "    });",
      "  },",
      "});",
      "writeFileSync(process.env.AIUR_TEST_READY, String(server.port));",
      "process.on('SIGTERM', () => { server.stop(true); process.exit(0); });",
      "",
    ].join("\n"),
  );

  if (barrierFile) appendFileSync(barrierFile, "");
  const server = Bun.spawn([process.execPath, serverScript], {
    env: {
      ...process.env,
      AIUR_TEST_READY: readyFile,
      AIUR_TEST_REQUESTS: requestFile,
      AIUR_TEST_RESPONSE: JSON.stringify({ status, body }),
      AIUR_TEST_SERVER_NAME: name,
      AIUR_TEST_BARRIER: barrierFile || "",
      AIUR_TEST_BARRIER_COUNT: String(barrierCount),
      AIUR_TEST_ON_REQUEST: onRequest || "",
      AIUR_TEST_REQUEST_COUNT_FILE: path.join(root, `remote-count-${name}`),
    },
    stdout: "ignore",
    stderr: "pipe",
  });

  const deadline = Date.now() + 5_000;
  while (!existsSync(readyFile) && Date.now() < deadline) sleep(10);
  if (!existsSync(readyFile)) {
    server.kill();
    throw new Error("fake remote server did not start");
  }

  return {
    url: `http://127.0.0.1:${readFileSync(readyFile, "utf8")}`,
    requests() {
      if (!existsSync(requestFile)) return [];
      return readFileSync(requestFile, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line));
    },
    stop() {
      server.kill();
    },
  };
}

export function registry(url, credential = "token_env: AIUR_TOKEN_T") {
  return `version: 1\ninstances:\n  t:\n    url: ${url}\n    ${credential}\n`;
}

export function successBody(output = "ok\n__AIUR_CONTROL_EXIT__:0\n") {
  return {
    contract: "aiur.control.result",
    contract_version: 1,
    instance_id: "test/t",
    build: { version: "0.1.0", commit: "abc1234" },
    output,
    elapsed_ms: 1,
  };
}
