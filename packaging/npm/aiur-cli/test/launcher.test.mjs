import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realShim = fileURLToPath(new URL("../bin/aiur.js", import.meta.url));

const HOST_TRIPLE = {
  "darwin arm64": "darwin-arm64",
  "darwin x64": "darwin-x64",
  "linux arm64": "linux-arm64",
  "linux x64": "linux-x64",
}[`${process.platform} ${process.arch}`];

let root;
let captureFile;

// Builds an isolated package layout: a copy of the shim, a fake bash launcher
// that records its argv + env, the bundled conf, and (optionally) a fake
// platform package. PATH is scoped to a temp bin dir holding fake tmux/opencode.
function setupPackage({ withPlatformPkg = true, tmuxVersion = "3.4", withOpencode = true } = {}) {
  mkdirSync(path.join(root, "bin"), { recursive: true });
  mkdirSync(path.join(root, "libexec"), { recursive: true });
  mkdirSync(path.join(root, "share"), { recursive: true });
  const fakeBin = path.join(root, "fakebin");
  mkdirSync(fakeBin, { recursive: true });

  copyFileSync(realShim, path.join(root, "bin", "aiur.js"));
  writeFileSync(path.join(root, "share", "aiur.tmux.conf"), "# test conf\n");

  const launcher = path.join(root, "libexec", "aiur-launch.sh");
  writeFileSync(
    launcher,
    [
      "#!/usr/bin/env bash",
      'echo "ARGS:$*" >>"$AIUR_TEST_OUT"',
      'echo "RELEASE_DIR:$AIUR_RELEASE_DIR" >>"$AIUR_TEST_OUT"',
      'echo "TMUX_CONF:$AIUR_TMUX_CONF" >>"$AIUR_TEST_OUT"',
      'exit "${AIUR_TEST_EXIT:-0}"',
      "",
    ].join("\n"),
  );
  chmodSync(launcher, 0o755);

  if (withPlatformPkg) {
    const pkgDir = path.join(root, "node_modules", `aiur-cli-${HOST_TRIPLE}`);
    mkdirSync(path.join(pkgDir, "release"), { recursive: true });
    writeFileSync(
      path.join(pkgDir, "package.json"),
      JSON.stringify({ name: `aiur-cli-${HOST_TRIPLE}`, version: "0.0.0" }),
    );
  }

  if (tmuxVersion) {
    const tmux = path.join(fakeBin, "tmux");
    writeFileSync(tmux, `#!/usr/bin/env bash\necho "tmux ${tmuxVersion}"\n`);
    chmodSync(tmux, 0o755);
  }
  if (withOpencode) {
    const oc = path.join(fakeBin, "opencode");
    writeFileSync(oc, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(oc, 0o755);
  }

  return { shim: path.join(root, "bin", "aiur.js"), fakeBin };
}

function runShim({ args = [], fakeBin, platform, arch, env = {} } = {}) {
  const fullEnv = {
    ...process.env,
    AIUR_TEST_OUT: captureFile,
    PATH: `${fakeBin}:${process.env.PATH}`,
    ...env,
  };
  // Override platform/arch in a child wrapper when a test needs a foreign host.
  const nodeArgs =
    platform || arch
      ? [
          "-e",
          `if(${JSON.stringify(!!platform)})process.platform=${JSON.stringify(platform)};` +
            `if(${JSON.stringify(!!arch)})process.arch=${JSON.stringify(arch)};` +
            `process.argv=[process.argv[0],${JSON.stringify(path.join(root, "bin", "aiur.js"))},${args
              .map((a) => JSON.stringify(a))
              .join(",")}];` +
            `require(${JSON.stringify(path.join(root, "bin", "aiur.js"))});`,
        ]
      : [path.join(root, "bin", "aiur.js"), ...args];
  return spawnSync(process.execPath, nodeArgs, { encoding: "utf8", env: fullEnv });
}

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), "aiur-shim-"));
  captureFile = path.join(root, "capture.txt");
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

test("happy path: resolves platform package and execs launcher with args + env", () => {
  const { fakeBin } = setupPackage();
  const result = runShim({ args: ["--host", "127.0.0.1", "WORKFLOW.md"], fakeBin });

  expect(result.status).toBe(0);
  const capture = require("node:fs").readFileSync(captureFile, "utf8");
  expect(capture).toContain("ARGS:--host 127.0.0.1 WORKFLOW.md");
  expect(capture).toContain(`RELEASE_DIR:${path.join(root, "node_modules", `aiur-cli-${HOST_TRIPLE}`, "release")}`);
  expect(capture).toContain(`TMUX_CONF:${path.join(root, "share", "aiur.tmux.conf")}`);
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

test("opencode absent warns but still runs the launcher", () => {
  const { fakeBin } = setupPackage({ withOpencode: false });
  // Scope PATH to fakebin (fake tmux) + coreutils so the real opencode on the
  // host PATH is not picked up, while bash/env stay available for the launcher.
  const result = runShim({ fakeBin, env: { PATH: `${fakeBin}:/usr/bin:/bin` } });
  expect(result.status).toBe(0);
  expect(result.stderr).toContain("opencode was not found");
});
