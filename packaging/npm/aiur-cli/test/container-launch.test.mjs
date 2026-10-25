import { test, expect } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import {
  mkdirSync,
  readdirSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
  chmodSync,
  symlinkSync,
} from "node:fs";
import path from "node:path";
import { root, setupRealLauncher, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

test("container launch runs without tmux and exits cleanly on SIGTERM", async () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const shim = path.join(root, "bin", "aiur.js");
  mkdirSync(path.dirname(shim), { recursive: true });
  copyFileSync(new URL("../bin/aiur.js", import.meta.url), shim);
  mkdirSync(path.join(root, "share"), { recursive: true });
  writeFileSync(path.join(root, "share", "aiur.tmux.conf"), "# unused in container mode\n");

  const vsnDir = path.join(releaseDir, "releases", "0.1.1");
  const argvCapture = path.join(root, "argv.txt");
  const distributionCapture = path.join(root, "distribution.txt");
  const readyFile = path.join(root, "control-ready");
  const elixir = path.join(vsnDir, "elixir");
  writeFileSync(elixir, [
    "#!/usr/bin/env bash",
    'printf "%s\\n" "$(cat \"$AIUR_ARGV_FILE\")" >"$AIUR_TEST_ARGV_CAPTURE"',
    'printf "%s\\n" "$RELEASE_DISTRIBUTION|$RELEASE_NODE|$RELEASE_COOKIE|$ERL_AFLAGS|$ERL_EPMD_ADDRESS" >>"$AIUR_TEST_DISTRIBUTION_CAPTURE"',
    'touch "$AIUR_TEST_READY_FILE"',
    'echo "__AIUR_CONFIG_PATH__:/tmp/container-config"',
    'echo "container-release-output"',
    'trap \'rm -f "$AIUR_TEST_READY_FILE"; exit 0\' TERM INT HUP',
    "while sleep 0.05; do :; done",
    "",
  ].join("\n"));
  chmodSync(elixir, 0o755);
  writeFileSync(path.join(releaseDir, "bin", "aiur"), [
    "#!/usr/bin/env bash",
    'if [ -f "$AIUR_TEST_READY_FILE" ]; then echo __AIUR_CONTROL_READY__; else echo __AIUR_CONTROL_NOT_READY__; exit 1; fi',
    "",
  ].join("\n"));
  chmodSync(path.join(releaseDir, "bin", "aiur"), 0o755);
  const fakeEpmd = path.join(releaseDir, "erts-test", "bin", "epmd");
  mkdirSync(path.dirname(fakeEpmd), { recursive: true });
  writeFileSync(fakeEpmd, "#!/usr/bin/env bash\necho 'epmd: up and running on port 4369 with data:'\n");
  chmodSync(fakeEpmd, 0o755);

  const logsRoot = path.join(root, "logs");
  const pathWithoutTmux = path.join(root, "path-without-tmux");
  mkdirSync(pathWithoutTmux);
  for (const name of readdirSync("/usr/bin")) {
    if (name === "tmux") continue;
    try {
      symlinkSync(path.join("/usr/bin", name), path.join(pathWithoutTmux, name));
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
  }
  const launchEnv = {
    ...process.env,
    AIUR_RELEASE_DIR: releaseDir,
    AIUR_INSTANCE_KEY: path.basename(root),
    AIUR_RELEASE_NODE: "aiur-container-test@127.0.0.1",
    AIUR_ERLANG_COOKIE: "container-env-cookie-5939",
    AIUR_TEST_DISTRIBUTION_CAPTURE: distributionCapture,
    AIUR_TEST_READY_FILE: readyFile,
    AIUR_TEST_ARGV_CAPTURE: argvCapture,
    AIUR_BG_STATE_DIR: path.join(root, "state"),
    AIUR_COOKIE_FILE: path.join(root, "state", "cookie"),
    AIUR_LOGS_ROOT: logsRoot,
    AIUR_NODE_GRACE_TICKS: "100",
    XDG_RUNTIME_DIR: root,
    TMPDIR: root,
    PATH: pathWithoutTmux,
  };
  delete launchEnv.AIUR_SESSION_PREFIX;
  const child = spawn(process.execPath, [shim, "run", "--container"], {
    stdio: ["ignore", "pipe", "pipe"],
    env: launchEnv,
  });

  let output = "";
  let stubbornProcess = null;
  child.stdout.on("data", (chunk) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk) => { output += chunk.toString(); });
  const exited = new Promise((resolve) => child.once("exit", (code, signal) => resolve({ code, signal })));
  const deadline = Date.now() + 5000;
  while (!output.includes("container-release-output") && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  try {
    expect(output).toContain("container-release-output");
    expect(readFileSync(argvCapture, "utf8")).toContain("--headless");
    expect(readFileSync(argvCapture, "utf8")).not.toContain("--no-dashboard");
    const distribution = readFileSync(distributionCapture, "utf8");
    expect(distribution).toContain("name|aiur-container-test@127.0.0.1|container-env-cookie-5939|");
    expect(distribution).toContain("-kernel inet_dist_use_interface {127,0,0,1}|127.0.0.1");
    expect(existsSync(path.join(pathWithoutTmux, "tmux"))).toBe(false);
    child.kill("SIGTERM");
    const result = await Promise.race([
      exited,
      new Promise((resolve) => setTimeout(() => resolve(null), 3000)),
    ]);

    expect(result).toEqual({ code: 0, signal: null });
    expect(readFileSync(path.join(logsRoot, "log", "boot.out.log"), "utf8")).toContain("container-release-output");

    writeFileSync(path.join(root, "state", "cookie"), "container-volume-cookie-5939");
    writeFileSync(elixir, [
      "#!/usr/bin/env bash",
      'printf "%s\\n" "$RELEASE_DISTRIBUTION|$RELEASE_NODE|$RELEASE_COOKIE|$ERL_AFLAGS|$ERL_EPMD_ADDRESS" >>"$AIUR_TEST_DISTRIBUTION_CAPTURE"',
      'touch "$AIUR_TEST_READY_FILE"',
      'echo "$$" >"$AIUR_STUBBORN_PID_FILE"',
      'echo "stubborn-container-release-output"',
      "trap '' TERM",
      "while sleep 0.05; do :; done",
      "",
    ].join("\n"));
    stubbornProcess = spawn(process.execPath, [shim, "run", "--container"], {
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...launchEnv,
        AIUR_ERLANG_COOKIE: "",
        AIUR_CONTAINER_STOP_GRACE_TICKS: "2",
        AIUR_STUBBORN_PID_FILE: path.join(root, "stubborn-release.pid"),
      },
    });
    let stubbornOutput = "";
    stubbornProcess.stdout.on("data", (chunk) => { stubbornOutput += chunk.toString(); });
    stubbornProcess.stderr.on("data", (chunk) => { stubbornOutput += chunk.toString(); });
    const stubbornExited = new Promise((resolve) => stubbornProcess.once("exit", (code, signal) => resolve({ code, signal })));
    const stubbornStartDeadline = Date.now() + 5000;
    while (!stubbornOutput.includes("stubborn-container-release-output") && Date.now() < stubbornStartDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(stubbornOutput).toContain("stubborn-container-release-output");
    expect(readFileSync(distributionCapture, "utf8")).toContain("name|aiur-container-test@127.0.0.1|container-volume-cookie-5939|");
    stubbornProcess.kill("SIGTERM");
    const stubbornResult = await Promise.race([
      stubbornExited,
      new Promise((resolve) => setTimeout(() => resolve(null), 3000)),
    ]);
    if (stubbornResult === null) {
      const stubbornReleasePid = Number(readFileSync(path.join(root, "stubborn-release.pid"), "utf8"));
      process.kill(stubbornReleasePid, "SIGKILL");
      await stubbornExited;
    }
    expect(stubbornResult).not.toBeNull();
    expect(stubbornOutput).toContain("sending SIGKILL");

    rmSync(readyFile, { force: true });
    writeFileSync(elixir, "#!/usr/bin/env bash\nexit 7\n");
    const crashed = spawn(process.execPath, [shim, "run", "--container"], {
      stdio: ["ignore", "ignore", "ignore"],
      env: launchEnv,
    });
    const crashResult = await new Promise((resolve) => crashed.once("exit", (code, signal) => resolve({ code, signal })));
    expect(crashResult).toEqual({ code: 7, signal: null });
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    if (stubbornProcess && stubbornProcess.exitCode === null && stubbornProcess.signalCode === null) {
      const stubbornPidFile = path.join(root, "stubborn-release.pid");
      if (existsSync(stubbornPidFile)) {
        const stubbornReleasePid = Number(readFileSync(stubbornPidFile, "utf8"));
        process.kill(stubbornReleasePid, "SIGKILL");
      }
      stubbornProcess.kill("SIGTERM");
    }
    await exited;
  }
}, 60_000);

test("container launch refuses an existing or indeterminate distribution node", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const node = "aiur-container-safety-test@127.0.0.1";
  const launchMarker = path.join(root, "release-launched");
  const releaseElixir = path.join(releaseDir, "releases", "0.1.1", "elixir");
  writeFileSync(releaseElixir, `#!/usr/bin/env bash\ntouch ${launchMarker}\n`);
  chmodSync(releaseElixir, 0o755);
  writeFileSync(path.join(releaseDir, "bin", "aiur"), "#!/usr/bin/env bash\nexit 1\n");
  chmodSync(path.join(releaseDir, "bin", "aiur"), 0o755);

  const fakeEpmd = path.join(releaseDir, "erts-test", "bin", "epmd");
  mkdirSync(path.dirname(fakeEpmd), { recursive: true });
  writeFileSync(fakeEpmd, [
    "#!/usr/bin/env bash",
    'if [ "$AIUR_TEST_EPMD_STATE" = "unknown" ]; then exit 1; fi',
    `echo 'name ${node.split("@")[0]} at port 4369'`,
    "",
  ].join("\n"));
  chmodSync(fakeEpmd, 0o755);

  for (const state of ["up"]) {
    const result = spawnSync(launcher, ["run", "--container"], {
      encoding: "utf8",
      env: {
        ...process.env,
        AIUR_RELEASE_DIR: releaseDir,
        AIUR_RELEASE_NODE: node,
        AIUR_INSTANCE_KEY: path.basename(root),
        AIUR_ERLANG_COOKIE: "container-test-cookie-5939",
        AIUR_TEST_EPMD_STATE: state,
        AIUR_BG_STATE_DIR: path.join(root, "state"),
        AIUR_COOKIE_FILE: path.join(root, "state", "cookie"),
        AIUR_LOGS_ROOT: path.join(root, "logs"),
        AIUR_SESSION_PREFIX: "container-safety-test",
        XDG_RUNTIME_DIR: root,
        TMPDIR: root,
      },
    });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`is ${state}`);
    expect(existsSync(launchMarker)).toBe(false);
  }
});

test("container launch starts when EPMD is unreachable and no process holds the node name", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const node = "aiur-container-epmd-unreachable-test@127.0.0.1";
  const launchMarker = path.join(root, "release-launched");
  const releaseElixir = path.join(releaseDir, "releases", "0.1.1", "elixir");
  writeFileSync(releaseElixir, `#!/usr/bin/env bash\ntouch ${launchMarker}\nsleep 0.2\n`);
  chmodSync(releaseElixir, 0o755);
  const controlProbeMarker = path.join(root, "control-probe-ran");
  writeFileSync(path.join(releaseDir, "bin", "aiur"), [
    "#!/usr/bin/env bash",
    `if [ ! -e ${controlProbeMarker} ]; then touch ${controlProbeMarker}; echo __AIUR_CONTROL_NOT_READY__; exit 1; fi`,
    "echo __AIUR_CONTROL_READY__",
    "",
  ].join("\n"));
  chmodSync(path.join(releaseDir, "bin", "aiur"), 0o755);
  const fakeEpmd = path.join(releaseDir, "erts-test", "bin", "epmd");
  mkdirSync(path.dirname(fakeEpmd), { recursive: true });
  writeFileSync(fakeEpmd, "#!/usr/bin/env bash\necho 'epmd: Cannot connect to local epmd' >&2\nexit 1\n");
  chmodSync(fakeEpmd, 0o755);

  const result = spawnSync(launcher, ["run", "--container"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_RELEASE_NODE: node,
      AIUR_INSTANCE_KEY: path.basename(root),
      AIUR_ERLANG_COOKIE: "container-test-cookie-5939",
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_COOKIE_FILE: path.join(root, "state", "cookie"),
      AIUR_LOGS_ROOT: path.join(root, "logs"),
      AIUR_SESSION_PREFIX: "container-epmd-test",
      XDG_RUNTIME_DIR: root,
      TMPDIR: root,
    },
  });

  expect(result.status).toBe(0);
  expect(existsSync(launchMarker)).toBe(true);
});

test("container launch refuses an EPMD-unreachable node held by a process and leaves it alone", async () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const node = "aiur-container-epmd-holder-test@127.0.0.1";
  const launchMarker = path.join(root, "release-launched");
  const releaseElixir = path.join(releaseDir, "releases", "0.1.1", "elixir");
  writeFileSync(releaseElixir, `#!/usr/bin/env bash\ntouch ${launchMarker}\n`);
  chmodSync(releaseElixir, 0o755);
  const fakeEpmd = path.join(releaseDir, "erts-test", "bin", "epmd");
  mkdirSync(path.dirname(fakeEpmd), { recursive: true });
  writeFileSync(fakeEpmd, "#!/usr/bin/env bash\necho 'epmd: Cannot connect to local epmd' >&2\nexit 1\n");
  chmodSync(fakeEpmd, 0o755);
  const decoy = spawn("bash", ["-c", 'exec -a "$1" /usr/bin/sleep 60', "container-node-holder", `beam.smp -name ${node}`], { stdio: "ignore" });

  try {
    await new Promise((resolve) => setTimeout(resolve, 50));
    const result = spawnSync(launcher, ["run", "--container"], {
      encoding: "utf8",
      env: {
        ...process.env,
        AIUR_RELEASE_DIR: releaseDir,
        AIUR_RELEASE_NODE: node,
        AIUR_INSTANCE_KEY: path.basename(root),
        AIUR_ERLANG_COOKIE: "container-test-cookie-5939",
        AIUR_BG_STATE_DIR: path.join(root, "state"),
        AIUR_COOKIE_FILE: path.join(root, "state", "cookie"),
        AIUR_LOGS_ROOT: path.join(root, "logs"),
        AIUR_SESSION_PREFIX: "container-holder-test",
        XDG_RUNTIME_DIR: root,
        TMPDIR: root,
      },
    });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain("is unknown");
    expect(result.stderr).toContain("a process still holds its name");
    expect(result.stderr).toContain("leaving it untouched");
    expect(existsSync(launchMarker)).toBe(false);
    expect(decoy.exitCode).toBeNull();
    expect(decoy.signalCode).toBeNull();
  } finally {
    decoy.kill("SIGTERM");
  }
});

test("container launch requires its own cookie instead of using the release cookie", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const launchMarker = path.join(root, "release-launched");
  const releaseElixir = path.join(releaseDir, "releases", "0.1.1", "elixir");
  writeFileSync(releaseElixir, `#!/usr/bin/env bash\ntouch ${launchMarker}\n`);
  chmodSync(releaseElixir, 0o755);
  writeFileSync(path.join(releaseDir, "releases", "COOKIE"), "baked-release-cookie-should-not-be-used");

  const result = spawnSync(launcher, ["run", "--container"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_INSTANCE_KEY: path.basename(root),
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_COOKIE_FILE: path.join(root, "missing-volume", "cookie"),
      AIUR_ERLANG_COOKIE: "",
      XDG_RUNTIME_DIR: root,
      TMPDIR: root,
    },
  });

  expect(result.status).toBe(1);
  expect(result.stderr).toContain("requires AIUR_ERLANG_COOKIE or a readable AIUR_COOKIE_FILE volume");
  expect(existsSync(launchMarker)).toBe(false);
});

test("control commands reuse the environment cookie without creating a state cookie", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const receivedCookie = path.join(root, "received-cookie");
  const cookieFile = path.join(root, "state", "cookie");
  writeFileSync(path.join(releaseDir, "bin", "aiur"), [
    "#!/usr/bin/env bash",
    'printf "%s" "$RELEASE_COOKIE" >"$AIUR_TEST_RECEIVED_COOKIE"',
    'echo __AIUR_CONTROL_EXIT__:0',
    "",
  ].join("\n"));
  chmodSync(path.join(releaseDir, "bin", "aiur"), 0o755);

  const result = spawnSync(launcher, ["status"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_INSTANCE_KEY: path.basename(root),
      AIUR_RELEASE_NODE: "aiur-container-control-test@127.0.0.1",
      AIUR_ERLANG_COOKIE: "control-env-cookie-5939",
      AIUR_TEST_RECEIVED_COOKIE: receivedCookie,
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_COOKIE_FILE: cookieFile,
      XDG_RUNTIME_DIR: root,
      TMPDIR: root,
    },
  });

  expect(result.status).toBe(0);
  expect(readFileSync(receivedCookie, "utf8")).toBe("control-env-cookie-5939");
  expect(existsSync(cookieFile)).toBe(false);
});
