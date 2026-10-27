import { test, expect } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import {
  captureFile,
  root,
  useTempRoot,
} from "./launcher-support.mjs";
import {
  registry,
  runRemote,
  runRemoteEngine,
  setupRemoteLauncher,
  startServer,
  successBody,
} from "./launcher-remote-support.mjs";

useTempRoot();

test("named remote status prints output and propagates its marker exit code", () => {
  for (const exitCode of [0, 7]) {
    const server = startServer({
      body: {
        contract: "aiur.control.result",
        contract_version: 1,
        instance_id: "test/t",
        build: { version: "0.1.0", commit: "abc1234" },
        output: `ok\n__AIUR_CONTROL_EXIT__:${exitCode}\n`,
        elapsed_ms: 1,
      },
    });
    try {
      const setup = setupRemoteLauncher(registry(server.url));
      const result = runRemote(setup, ["--instance", "t", "status"]);
      expect(result.status).toBe(exitCode);
      expect(result.stdout).toBe("ok\n");
      expect(result.stderr).not.toContain("remote-secret-token");
      expect(server.requests()).toHaveLength(1);
    } finally {
      server.stop();
    }
  }
});

test("the shared engine accepts --instance before classifying the command", () => {
  const server = startServer({ body: successBody() });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const result = runRemoteEngine(setup, ["--instance", "t", "status"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("ok\n");
    expect(server.requests()).toHaveLength(1);
  } finally {
    server.stop();
  }
});

test("the shared engine rejects an empty --instance before transport", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    rmSync(captureFile, { force: true });
    const result = runRemoteEngine(setup, ["--instance=", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("--instance requires a name");
    expect(existsSync(captureFile)).toBe(false);
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("the shared engine ignores an ambient remote instance without the flag", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    rmSync(captureFile, { force: true });
    const result = runRemoteEngine(setup, ["status"], { AIUR_REMOTE_INSTANCE: "t" });
    expect(result.status).toBe(0);
    expect(existsSync(captureFile)).toBe(true);
    expect(readFileSync(captureFile, "utf8")).toContain("LOCAL_EXPR:Aiur.AgentControlCLI.status()");
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("remote requests carry the exact expression used by local RPC", () => {
  const server = startServer({
    body: {
      contract: "aiur.control.result",
      contract_version: 1,
      instance_id: "test/t",
      build: { version: "0.1.0", commit: "abc1234" },
      output: ":ok\n__AIUR_CONTROL_EXIT__:0\n",
      elapsed_ms: 1,
    },
  });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    for (const args of [["status"], ["agents", "--all"], ["message", "12", "hi"]]) {
      rmSync(captureFile, { force: true });
      const local = runRemote(setup, args);
      expect(local.status).toBe(0);
      const localExpression = readFileSync(captureFile, "utf8").match(/^LOCAL_EXPR:(.*)$/m)[1];

      const remote = runRemote(setup, ["--instance=t", ...args]);
      expect(remote.status).toBe(0);
      const request = server.requests().at(-1);
      expect(request.body.expression).toBe(localExpression);
      expect(request.body.contract).toBe("aiur.control.call");
      expect(request.body.contract_version).toBe(1);
      expect(request.body.command).toBe(args[0]);
      expect(request.body.timeout_ms).toBe(args[0] === "message" ? 70_000 : 10_000);
      expect(request.body.max_scope).toBe("write");
      expect(request.authorization).toBe("Bearer remote-secret-token");
    }
  } finally {
    server.stop();
  }
}, 20_000);

test("remote bearer token travels through curl stdin instead of argv", () => {
  const server = startServer({ body: successBody() });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const argsFile = path.join(root, "remote-curl-argv");
    const curlPath = process.env.PATH.split(path.delimiter).map((dir) => path.join(dir, "curl")).find((file) => existsSync(file));
    const curl = path.join(setup.fakeBin, "curl");
    writeFileSync(curl, `#!/usr/bin/env bash\nprintf '%s' "$*" >"$AIUR_TEST_CURL_ARGS"\nexec "$AIUR_TEST_REAL_CURL" "$@"\n`);
    chmodSync(curl, 0o755);
    const result = runRemote(setup, ["--instance", "t", "status"], {
      AIUR_TEST_CURL_ARGS: argsFile,
      AIUR_TEST_REAL_CURL: curlPath,
    });
    expect(result.status).toBe(0);
    expect(readFileSync(argsFile, "utf8")).toContain("--header @-");
    expect(readFileSync(argsFile, "utf8")).not.toContain("remote-secret-token");
    expect(server.requests()[0].authorization).toBe("Bearer remote-secret-token");
  } finally {
    server.stop();
  }
});

test("watch cleans every remote RPC before starting its next interval", () => {
  const server = startServer({ body: successBody("watch\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const tmpdir = path.join(root, "watch-remote-tmp");
    const sleepCount = path.join(root, "watch-sleep-count");
    const leakFile = path.join(root, "watch-remote-leak");
    mkdirSync(tmpdir, { recursive: true });
    const fakeSleep = path.join(setup.fakeBin, "sleep");
    writeFileSync(fakeSleep, [
      "#!/usr/bin/env bash",
      `count=0; [ ! -f '${sleepCount}' ] || count=$(cat '${sleepCount}')`,
      `count=$((count + 1)); printf '%s' "$count" >'${sleepCount}'`,
      `if find "$TMPDIR" -maxdepth 1 -name 'aiur-remote-*' -type f | grep -q .; then touch '${leakFile}'; fi`,
      `if [ "$count" -ge 2 ]; then kill -TERM "$PPID"; fi`,
      "exit 0",
      "",
    ].join("\n"));
    chmodSync(fakeSleep, 0o755);
    const result = runRemote(setup, ["--instance", "t", "watch", "--full", "--interval", "1"], { TMPDIR: tmpdir });
    expect(result.signal).toBe("SIGTERM");
    expect(server.requests().length).toBeGreaterThanOrEqual(2);
    expect(existsSync(leakFile)).toBe(false);
    expect(readdirSync(tmpdir)).toEqual([]);
  } finally {
    server.stop();
  }
}, 20_000);

test("local status stays on release RPC and sends no HTTP request", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const result = runRemote(setup, ["status"]);
    expect(result.status).toBe(0);
    expect(readFileSync(captureFile, "utf8")).toContain("LOCAL_EXPR:Aiur.AgentControlCLI.status()");
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("local-only commands and implicit remote Executor identities refuse before HTTP", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const stopped = runRemote(setup, ["--instance", "t", "stop"]);
    expect(stopped.status).toBe(64);
    expect(stopped.stderr).toContain("stop is local to the instance's host");

    for (const args of [
      ["executor-wait", "--timeout", "1"],
      ["executor-claim"],
      ["executor-release"],
      ["executor-fast-forward", "4"],
    ]) {
      const result = runRemote(setup, ["--instance", "t", ...args]);
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("requires --as <id>");
    }
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("registry rejects insecure non-loopback URLs and accepts loopback HTTP", () => {
  for (const url of ["http://example.com", "http://x.ts.net"]) {
    const setup = setupRemoteLauncher(registry(url));
    const result = runRemote(setup, ["--instance", "t", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("HTTPS");
  }

  const server = startServer({ body: successBody() });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    expect(runRemote(setup, ["--instance", "t", "status"]).status).toBe(0);
  } finally {
    server.stop();
  }
});

test("HTTPS targets pass URL validation", () => {
  const setup = setupRemoteLauncher(registry("https://x.ts.net"));
  const curl = path.join(setup.fakeBin, "curl");
  writeFileSync(
    curl,
    [
      "#!/usr/bin/env bash",
      "response=",
      "while [ $# -gt 0 ]; do",
      '  case "$1" in -o|--output) shift; response="$1" ;; esac',
      "  shift",
      "done",
      "cat >/dev/null",
      `printf '%s' '${JSON.stringify(successBody())}' >"$response"`,
      "printf 200",
      "",
    ].join("\n"),
  );
  chmodSync(curl, 0o755);
  const result = runRemote(setup, ["--instance", "t", "status"]);
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("HTTPS");
});

test("token files must be mode 0600", () => {
  const server = startServer({ body: successBody() });
  try {
    const tokenFile = path.join(root, "remote-token");
    rmSync(tokenFile, { force: true });
    writeFileSync(tokenFile, "file-secret-token\n", { mode: 0o644 });
    chmodSync(tokenFile, 0o644);
    expect(statSync(tokenFile).mode & 0o777).toBe(0o644);
    const setup = setupRemoteLauncher(registry(server.url, `token_file: ${tokenFile}`));
    const result = runRemote(setup, ["--instance", "t", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("mode 0600");
    expect(result.stderr).not.toContain("file-secret-token");
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("token_file paths beginning with ~/ resolve beneath HOME", () => {
  const server = startServer({ body: successBody() });
  try {
    const setup = setupRemoteLauncher(registry(server.url, "token_file: ~/remote-token"));
    const tokenFile = path.join(setup.home, "remote-token");
    writeFileSync(tokenFile, "tilde-secret-token\n", { mode: 0o600 });
    chmodSync(tokenFile, 0o600);
    const result = runRemote(setup, ["--instance", "t", "status"]);
    expect(result.status).toBe(0);
    expect(server.requests()[0].authorization).toBe("Bearer tilde-secret-token");
  } finally {
    server.stop();
  }
});

test("authentication and build errors are mapped without exposing the token", () => {
  for (const response of [
    {
      status: 401,
      body: { error: { code: "unauthenticated" } },
      expectedStatus: 77,
      message: "token rejected by t",
    },
    {
      status: 403,
      body: { error: { code: "scope_denied", required_scope: "write" } },
      expectedStatus: 77,
      message: "write scope",
    },
    {
      status: 422,
      body: {
        error: {
          code: "call_refused",
          reason: "unknown_on_build",
          detail: "status",
          build: { version: "0.4.2", commit: "deadbee" },
        },
      },
      expectedStatus: 64,
      message: "unsupported on t (0.4.2 deadbee)",
    },
    {
      status: 422,
      body: {
        error: {
          code: "call_refused",
          reason: "option_not_allowed",
          detail: "new_option",
          build: { version: "0.4.1", commit: "cab005e" },
        },
      },
      expectedStatus: 64,
      message: "unsupported on t (0.4.1 cab005e)",
    },
  ]) {
    const server = startServer(response);
    try {
      const setup = setupRemoteLauncher(registry(server.url));
      const result = runRemote(setup, ["--instance", "t", "status"]);
      expect(result.status).toBe(response.expectedStatus);
      expect(result.stderr).toContain(response.message);
      expect(result.stderr).not.toContain("remote-secret-token");
      expect(server.requests()).toHaveLength(1);
    } finally {
      server.stop();
    }
  }
}, 20_000);

test("transport and invalid-success responses map to unavailable", () => {
  const unreachable = setupRemoteLauncher(registry("http://127.0.0.1:1"));
  const transport = runRemote(unreachable, ["--instance", "t", "status"]);
  expect(transport.status).toBe(69);
  expect(transport.stderr).toContain("could not reach remote instance 't'");

  const server = startServer({ body: { output: "missing contract" } });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const malformed = runRemote(setup, ["--instance", "t", "status"]);
    expect(malformed.status).toBe(69);
    expect(malformed.stderr).toContain("invalid control response");
    expect(server.requests()).toHaveLength(1);
  } finally {
    server.stop();
  }
});

test("gateway timeouts preserve the unknown write outcome without retrying", () => {
  const server = startServer({ status: 504, body: { error: { code: "timeout", timeout_ms: 10_000 } } });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const result = runRemote(setup, ["--instance", "t", "pause"]);
    expect(result.status).toBe(124);
    expect(result.stderr).toContain("outcome unknown on t");
    expect(server.requests()).toHaveLength(1);
  } finally {
    server.stop();
  }
});

test("unknown instances fail with the registry path and make no request", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry(server.url));
    const result = runRemote(setup, ["--instance", "missing", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("~/.aiur/remote-instances.yaml");
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("malformed registry entries name their line", () => {
  const setup = setupRemoteLauncher(
    "version: 1\ninstances:\n  t:\n    url: https://x.ts.net\n    surprise: nope\n",
  );
  const result = runRemote(setup, ["--instance", "t", "status"]);
  expect(result.status).toBe(64);
  expect(result.stderr).toContain("remote-instances.yaml:5");
});
