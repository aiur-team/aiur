import { test, expect } from "bun:test";
import {
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  chmodSync,
  readdirSync,
  symlinkSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import { root, captureFile, setupPackage, runShim, HOST_TRIPLE, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

test("happy path: resolves platform package and execs launcher with args + env", () => {
  const { fakeBin } = setupPackage();
  const result = runShim({ args: ["--host", "127.0.0.1", "WORKFLOW.md"], fakeBin });

  expect(result.status).toBe(0);
  const capture = require("node:fs").readFileSync(captureFile, "utf8");
  expect(capture).toContain("ARGS:--host 127.0.0.1 WORKFLOW.md");
  expect(capture).toContain(
    `RELEASE_DIR:${realpathSync(path.join(root, "node_modules", `aiur-cli-${HOST_TRIPLE}`, "release"))}`,
  );
  expect(capture).toContain(`TMUX_CONF:${realpathSync(path.join(root, "share", "aiur.tmux.conf"))}`);
});

test("unknown platform triple fails without execing the launcher", () => {
  const { fakeBin } = setupPackage();
  const result = runShim({ fakeBin, platform: "sunos", arch: "x64" });

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("unsupported platform");
  expect(require("node:fs").existsSync(captureFile)).toBe(false);
});

test("known triple but platform package missing gives an actionable message, no stack trace", () => {
  const { fakeBin } = setupPackage({ withPlatformPkg: false });
  const result = runShim({ fakeBin });

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain(`aiur-cli-${HOST_TRIPLE}`);
  expect(result.stderr).toContain("not installed");
  expect(result.stderr).not.toContain("MODULE_NOT_FOUND");
  expect(result.stderr).not.toContain("at Object.");
});

test("launcher exit code propagates through the shim", () => {
  const { fakeBin } = setupPackage();
  const result = runShim({ fakeBin, env: { AIUR_TEST_EXIT: "3" } });
  expect(result.status).toBe(3);
});

test("tmux too old is fatal with an install hint", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: "2.9" });
  const result = runShim({ fakeBin });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("too old");
});

test("tmux absent is fatal", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: null });
  // Scope PATH to only the fakebin (no tmux) so the system tmux is not found.
  const result = runShim({ fakeBin, env: { PATH: fakeBin } });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("tmux is required");
});

test("container launch skips interactive tool preflight", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: null, withOpencode: false });
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
  const result = runShim({
    args: ["run", "--container"],
    fakeBin,
    env: { PATH: `${fakeBin}:${pathWithoutTmux}` },
  });
  expect(result.status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("ARGS:run --container");
  expect(result.stderr).not.toContain("tmux is required");
});

test("opencode absent warns but still runs the launcher", () => {
  const { fakeBin } = setupPackage({ withOpencode: false });
  // Scope PATH to fakebin (fake tmux) + coreutils so the real opencode on the
  // host PATH is not picked up, while bash/env stay available for the launcher.
  const result = runShim({ fakeBin, env: { PATH: `${fakeBin}:/usr/bin:/bin` } });
  expect(result.status).toBe(0);
  expect(result.stderr).toContain("opencode@1.17.10 is unavailable");
});

// bun/pnpm/yarn skip the npm postinstall, so the launcher must provision
// opencode itself on first run. A fake npm stands in for the real install:
// `npm install -g opencode-ai@…` drops an opencode that reports the pin.
test("provisions opencode on first run when missing", () => {
  const { fakeBin } = setupPackage({ withOpencode: false });
  const fakeNpm = path.join(fakeBin, "npm");
  const oc = path.join(fakeBin, "opencode");
  writeFileSync(
    fakeNpm,
    [
      "#!/usr/bin/env bash",
      'if [ "$1" = "install" ]; then',
      `  printf '#!/usr/bin/env bash\\necho 1.17.10\\n' > "${oc}"`,
      `  chmod +x "${oc}"`,
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(fakeNpm, 0o755);

  const result = runShim({
    fakeBin,
    env: { AIUR_SKIP_OPENCODE_INSTALL: "", PATH: `${fakeBin}:/usr/bin:/bin` },
  });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("provisioning opencode");
  // The post-install pin check passed, so the "not found" fallback never fires.
  expect(result.stderr).not.toContain("opencode was not found");
});

// A too-old fake tmux shadows any real tmux (fakeBin is first on PATH), so the
// same setup that is fatal for a bare run proves init/--version skip preflight.
test("init skips tmux preflight and still execs the launcher", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: "2.9" });
  const result = runShim({ args: ["init"], fakeBin, env: { PATH: `${fakeBin}:/usr/bin:/bin` } });
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("too old");
  const capture = require("node:fs").readFileSync(captureFile, "utf8");
  expect(capture).toContain("ARGS:init");
});

test("--version skips tmux preflight and still execs the launcher", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: "2.9" });
  const result = runShim({ args: ["--version"], fakeBin, env: { PATH: `${fakeBin}:/usr/bin:/bin` } });
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("too old");
  const capture = require("node:fs").readFileSync(captureFile, "utf8");
  expect(capture).toContain("ARGS:--version");
});

const nonLaunchCommands = [
  "__identity", "help", "-h", "-help", "--h", "--help", "--version", "--todo", "--only",
  "init", "pr", "findings", "ask", "asks", "status", "usage", "agents", "commands", "units",
  "build-orders", "queue", "analytics", "experiments", "github-cost", "github-usage", "alerts", "watch", "set",
  "upgrade", "pause", "resume", "reset-budget", "message", "cleanup-stale", "stop",
  "executor-answer", "executor-escalate", "executor-reclassify", "executor-moot", "listen", "executor-listen", "executor-wait",
  "executor-emit", "executor-subscribe", "executor-unsubscribe", "executor-subscriptions",
  "executor-roster", "executor-fast-forward", "executor-claim", "executor-release", "executor-revoke",
];

for (const command of nonLaunchCommands) {
  // init and --version already bypassed preflight; retain them as future guards.
  const guard = ["init", "--version"].includes(command) ? " (future-regression guard)" : "";
  test(`non-launch ${command} never probes or provisions interactive tools${guard}`, () => {
    const { fakeBin } = setupPackage();
    if (command === "experiments") mkdirSync(path.join(root, command));
    for (const tool of ["tmux", "opencode", "npm"]) {
      const executable = path.join(fakeBin, tool);
      writeFileSync(executable, `#!/bin/bash\necho '${tool}:$*' >>"$AIUR_TEST_OUT"\nexit 1\n`);
      chmodSync(executable, 0o755);
    }
    // A local path must not turn the standalone PR command into a launch.
    if (command === "pr") mkdirSync(path.join(root, "pr"));
    const result = runShim({
      args: [command, "--format", "records"], fakeBin,
      env: { PATH: `${fakeBin}:/usr/bin:/bin`, AIUR_SKIP_TMUX_INSTALL: "", AIUR_SKIP_OPENCODE_INSTALL: "" },
    });
    expect(result.status).toBe(0);
    const capture = readFileSync(captureFile, "utf8");
    expect(capture).toContain(`ARGS:${command} --format records`);
    for (const tool of ["tmux", "opencode", "npm"]) expect(capture).not.toContain(`${tool}:`);
  });
}

// Deliberate future-regression guard: these launch forms already preflight on main.
for (const args of [[], ["run"], ["restart"], ["--bg"], ["--host", "localhost"], ["--pause"]]) {
  test(`launch ${JSON.stringify(args)} retains interactive tool preflight`, () => {
    const { fakeBin } = setupPackage({ tmuxVersion: "2.9" });
    const result = runShim({ args, fakeBin });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("too old");
    expect(existsSync(captureFile)).toBe(false);
  });
}

test("existing config path retains preflight (future-regression guard)", () => {
  const { fakeBin } = setupPackage({ tmuxVersion: "2.9" });
  const config = path.join(root, "config.yaml");
  writeFileSync(config, "");
  const result = runShim({ args: [config], fakeBin });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("too old");
});

function setupShadowedPin({ installed = false, installFails = false } = {}) {
  const { fakeBin } = setupPackage();
  writeFileSync(path.join(fakeBin, "opencode"), '#!/bin/bash\necho "9.9.9"\n');
  const prefix = path.join(root, "npm global prefix");
  const globalBin = path.join(prefix, "bin");
  mkdirSync(globalBin, { recursive: true });
  const pinned = path.join(globalBin, "opencode");
  if (installed) {
    writeFileSync(pinned, '#!/bin/bash\necho "1.17.10"\n');
    chmodSync(pinned, 0o755);
  }
  const npm = path.join(fakeBin, "npm");
  writeFileSync(npm, [
    "#!/bin/bash",
    'echo "NPM:$*" >>"$AIUR_TEST_OUT"',
    `if [ "$1" = prefix ]; then printf '%s\\n' '${prefix}'; exit 0; fi`,
    `if [ "$1" = install ]; then`,
    installFails ? "  exit 1" : `  printf '#!/bin/bash\\necho 1.17.10\\n' > '${pinned}'`,
    installFails ? "" : `  chmod +x '${pinned}'`,
    "  exit 0",
    "fi",
    "exit 1",
  ].join("\n"));
  chmodSync(npm, 0o755);
  return { fakeBin, globalBin };
}

for (const installed of [false, true]) {
  test(`selects shadowed npm-global pin ${installed ? "without reinstalling" : "after installing"}`, () => {
    const { fakeBin } = setupShadowedPin({ installed });
    const result = runShim({
      fakeBin,
      env: { PATH: `${fakeBin}:/usr/bin:/bin`, AIUR_SKIP_OPENCODE_INSTALL: "", AIUR_TEST_CAPTURE_OPENCODE: "1" },
    });
    expect(result.status).toBe(0);
    const capture = readFileSync(captureFile, "utf8");
    expect(capture).toContain("OPENCODE_VERSION:1.17.10");
    if (installed) expect(capture).not.toContain("NPM:install");
    else expect(capture).toContain("NPM:install -g opencode-ai@1.17.10");
    expect(result.stderr).not.toContain("feature needs");
  });
}

test("failed pin install remains non-fatal with an accurate pinned manual hint", () => {
  const { fakeBin } = setupShadowedPin({ installFails: true });
  const result = runShim({
    fakeBin,
    env: { PATH: `${fakeBin}:/usr/bin:/bin`, AIUR_SKIP_OPENCODE_INSTALL: "" },
  });
  expect(result.status).toBe(0);
  expect(result.stderr).toContain("opencode@1.17.10 is unavailable");
  expect(result.stderr).toContain("npm install -g opencode-ai@1.17.10");
  expect(result.stderr).toContain("PATH");
  expect(result.stderr).not.toContain("opencode was not found");
});

// Builds a fake OTP release recording argv to exercise the real launcher routing.
