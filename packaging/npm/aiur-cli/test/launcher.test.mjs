import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
  chmodSync,
  copyFileSync,
  realpathSync,
} from "node:fs";
import { tmpdir } from "node:os";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realShim = fileURLToPath(new URL("../bin/aiur.js", import.meta.url));

const HOST_TRIPLE = {
  "darwin arm64": "darwin-arm64",
  "darwin x64": "darwin-x64",
  "linux arm64": "linux-arm64",
  "linux x64": "linux-x64",
}[`${process.platform} ${process.arch}`];
const NODE_EXEC = spawnSync("which", ["node"], { encoding: "utf8" }).stdout.trim() || "node";

let root;
let captureFile;

// Builds an isolated package layout: a copy of the shim, a fake bash launcher
// that records its argv + env, the bundled conf, and (optionally) a fake
// platform package. PATH is scoped to a temp bin dir holding fake tmux/opencode.
function setupPackage({
  withPlatformPkg = true,
  tmuxVersion = "3.4",
  withOpencode = true,
  version = "0.0.0",
} = {}) {
  mkdirSync(path.join(root, "bin"), { recursive: true });
  mkdirSync(path.join(root, "libexec"), { recursive: true });
  mkdirSync(path.join(root, "share"), { recursive: true });
  const fakeBin = path.join(root, "fakebin");
  mkdirSync(fakeBin, { recursive: true });

  copyFileSync(realShim, path.join(root, "bin", "aiur.js"));
  // The shim reads its pinned opencode version from this package.json.
  writeFileSync(
    path.join(root, "package.json"),
    JSON.stringify({ name: "aiur-cli", version, opencodeVersion: "1.17.10" }),
  );
  writeFileSync(path.join(root, "share", "aiur.tmux.conf"), "# test conf\n");

  const launcher = path.join(root, "libexec", "aiur-engine.sh");
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
    // Report the pinned version so the shim's pin check is satisfied.
    writeFileSync(oc, '#!/usr/bin/env bash\necho "1.17.10"\n');
    chmodSync(oc, 0o755);
  }

  return { shim: path.join(root, "bin", "aiur.js"), fakeBin };
}

function runShim({ args = [], fakeBin, platform, arch, env = {}, forceTTY = false } = {}) {
  const fullEnv = {
    ...process.env,
    AIUR_TEST_OUT: captureFile,
    PATH: `${fakeBin}:${process.env.PATH}`,
    // Hermetic by default: don't fire real brew/npm during preflight tests.
    // Provisioning tests opt back in by overriding these to "".
    AIUR_SKIP_TMUX_INSTALL: "1",
    AIUR_SKIP_OPENCODE_INSTALL: "1",
    ...env,
  };
  delete fullEnv.AIUR_RELEASE_DIR;
  // Use a child wrapper to override platform/arch for a foreign host, or to fake
  // a TTY on stderr (spawnSync pipes stderr, so the update notice is otherwise
  // suppressed by the launcher's interactive gate).
  const nodeArgs =
    platform || arch || forceTTY
      ? [
          "-e",
          `if(${JSON.stringify(forceTTY)})Object.defineProperty(process.stderr,"isTTY",{value:true,configurable:true});` +
            `if(${JSON.stringify(!!platform)})Object.defineProperty(process,"platform",{value:${JSON.stringify(platform)}});` +
            `if(${JSON.stringify(!!arch)})Object.defineProperty(process,"arch",{value:${JSON.stringify(arch)}});` +
            `process.argv=[process.argv[0],${JSON.stringify(path.join(root, "bin", "aiur.js"))},${args
              .map((a) => JSON.stringify(a))
              .join(",")}];` +
            `require(${JSON.stringify(path.join(root, "bin", "aiur.js"))});`,
        ]
      : [path.join(root, "bin", "aiur.js"), ...args];
  return spawnSync(NODE_EXEC, nodeArgs, { encoding: "utf8", env: fullEnv });
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

test("opencode absent warns but still runs the launcher", () => {
  const { fakeBin } = setupPackage({ withOpencode: false });
  // Scope PATH to fakebin (fake tmux) + coreutils so the real opencode on the
  // host PATH is not picked up, while bash/env stay available for the launcher.
  const result = runShim({ fakeBin, env: { PATH: `${fakeBin}:/usr/bin:/bin` } });
  expect(result.status).toBe(0);
  expect(result.stderr).toContain("opencode was not found");
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

// Builds a minimal fake OTP release whose `elixir` records its argv, so the
// REAL launcher's init routing can be exercised end to end.
function setupRealLauncher() {
  const launcherSrc = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));
  mkdirSync(path.join(root, "libexec"), { recursive: true });
  const launcher = path.join(root, "libexec", "aiur-engine.sh");
  copyFileSync(launcherSrc, launcher);

  const releaseDir = path.join(root, "release");
  const vsn = "0.1.1";
  const vsnDir = path.join(releaseDir, "releases", vsn);
  mkdirSync(vsnDir, { recursive: true });
  mkdirSync(path.join(releaseDir, "lib"), { recursive: true });
  writeFileSync(path.join(releaseDir, "releases", "start_erl.data"), `1 ${vsn}\n`);
  writeFileSync(path.join(vsnDir, "vm.args"), "");
  writeFileSync(path.join(vsnDir, "sys.config"), "");

  const elixir = path.join(vsnDir, "elixir");
  writeFileSync(
    elixir,
    [
      "#!/usr/bin/env bash",
      'echo "ELIXIR_ARGS:$*" >>"$AIUR_TEST_OUT"',
      'echo "ARGV_FILE:$(cat "$AIUR_ARGV_FILE")" >>"$AIUR_TEST_OUT"',
      'echo "DEEPSEEK_API_KEY:${DEEPSEEK_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      'echo "OPENROUTER_API_KEY:${OPENROUTER_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      'echo "MOONSHOT_API_KEY:${MOONSHOT_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(elixir, 0o755);

  return { launcher, releaseDir };
}

function setupBackgroundLauncher() {
  const { launcher, releaseDir } = setupRealLauncher();
  mkdirSync(path.join(root, "share"), { recursive: true });
  writeFileSync(path.join(root, "share", "aiur.tmux.conf"), "# test conf\n");

  const binAiur = path.join(releaseDir, "bin", "aiur");
  mkdirSync(path.dirname(binAiur), { recursive: true });
  writeFileSync(
    binAiur,
    [
      "#!/usr/bin/env bash",
      'echo "BIN_AIUR:$*" >>"$AIUR_TEST_OUT"',
      'if [ "$1" = "rpc" ]; then',
      '  if [ -f "${AIUR_FAKE_CONTROL_STATE:?}" ] && grep -q ready "$AIUR_FAKE_CONTROL_STATE"; then',
      '    echo "__AIUR_CONTROL_READY__"',
      "    exit 0",
      "  fi",
      '  echo "__AIUR_CONTROL_NOT_READY__"',
      "  exit 1",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(binAiur, 0o755);

  const fakeBin = mkdtempSync(path.join(root, "fakebin-"));
  const fakePgrep = path.join(fakeBin, "pgrep");
  writeFileSync(
    fakePgrep,
    [
      "#!/usr/bin/env bash",
      'if [ -n "${AIUR_FAKE_BEAM_ALIVE:-}" ] && [ -f "$AIUR_FAKE_BEAM_ALIVE" ]; then exit 0; fi',
      'exec /usr/bin/pgrep "$@"',
      "",
    ].join("\n"),
  );
  chmodSync(fakePgrep, 0o755);

  const fakeSleep = path.join(fakeBin, "sleep");
  writeFileSync(
    fakeSleep,
    [
      "#!/usr/bin/env bash",
      'while [ -n "${AIUR_FAKE_BEAM_ALIVE:-}" ] && [ -f "$AIUR_FAKE_BEAM_ALIVE" ]; do /usr/bin/sleep 0.01; done',
      'exec /usr/bin/sleep "$@"',
      "",
    ].join("\n"),
  );
  chmodSync(fakeSleep, 0o755);

  const fakeTmux = path.join(fakeBin, "tmux");
  writeFileSync(
    fakeTmux,
    [
      "#!/usr/bin/env bash",
      'echo "TMUX:$*" >>"$AIUR_TEST_OUT"',
      'state="${AIUR_FAKE_TMUX_STATE:?}"',
      "args=()",
      'while [ "$#" -gt 0 ]; do',
      '  case "$1" in',
      "    -L|-f|-t|-s|-x|-y|-T) shift 2 ;;",
      "    -d) shift ;;",
      '    *) args+=("$1"); shift ;;',
      "  esac",
      "done",
      'cmd="${args[0]:-}"',
      'case "$cmd" in',
      "  has-session)",
      '    [ -f "$state" ] && exit 0 || exit 1',
      "    ;;",
      "  new-session)",
      '    touch "$state"',
      '    echo ready >"${AIUR_FAKE_CONTROL_STATE:?}"',
      "    exit 0",
      "    ;;",
      "  kill-session|kill-server)",
      '    rm -f "$state"',
      '    : >"${AIUR_FAKE_WATCHDOG_REAPED:?}"',
      "    exit 0",
      "    ;;",
      "  select-pane)",
      "    exit 0",
      "    ;;",
      "esac",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(fakeTmux, 0o755);

  return { launcher, releaseDir, fakeBin, tmuxState: path.join(root, "tmux-session") };
}

function runBackgroundLauncher({ existingSession = false, controlReady = true, keepWatchdogAlive = false } = {}) {
  const { launcher, releaseDir, fakeBin, tmuxState } = setupBackgroundLauncher();
  if (existingSession) writeFileSync(tmuxState, "present\n");
  const controlState = path.join(root, "control-state");
  const fakeBeamAlive = path.join(root, "fake-beam-alive");
  const watchdogReaped = path.join(root, "watchdog-reaped");
  if (keepWatchdogAlive) writeFileSync(fakeBeamAlive, "alive\n");
  writeFileSync(controlState, controlReady ? "ready\n" : "down\n");

  const result = spawnSync(launcher, ["--bg"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TEST_OUT: captureFile,
      AIUR_FAKE_TMUX_STATE: tmuxState,
      AIUR_FAKE_CONTROL_STATE: controlState,
      AIUR_FAKE_BEAM_ALIVE: fakeBeamAlive,
      AIUR_FAKE_WATCHDOG_REAPED: watchdogReaped,
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_COOKIE_FILE: path.join(root, "state", "cookie"),
      XDG_RUNTIME_DIR: root,
      PATH: `${fakeBin}:/usr/bin:/bin`,
    },
  });

  return { result, tmuxState, stateDir: path.join(root, "state"), fakeBeamAlive, watchdogReaped };
}

test("launcher routes init to a distribution-free foreground exec", () => {
  const { launcher, releaseDir } = setupRealLauncher();

  const result = spawnSync(launcher, ["init", "--force"], {
    encoding: "utf8",
    env: { ...process.env, AIUR_RELEASE_DIR: releaseDir, AIUR_TEST_OUT: captureFile },
  });

  expect(result.status).toBe(0);
  const capture = require("node:fs").readFileSync(captureFile, "utf8");
  // Interactive --eval boot (not `bin/aiur eval`), and never opens a tmux session.
  expect(capture).toContain("--eval");
  expect(capture).toContain("Aiur.CLI.main(Aiur.CLI.argv_from_file())");
  // Distribution-free: no named node / cookie that would collide with a live TUI.
  expect(capture).not.toContain("--name");
  expect(capture).not.toContain("--cookie");
  // Argv crossed into the BEAM via the argv file.
  expect(capture).toContain("ARGV_FILE:init");
});

test("launcher loads global provider credentials before repo-local dotenv", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const home = path.join(root, "home");
  const project = path.join(root, "project");
  mkdirSync(path.join(home, ".aiur"), { recursive: true });
  mkdirSync(project, { recursive: true });

  writeFileSync(
    path.join(home, ".aiur", ".env"),
    "DEEPSEEK_API_KEY=global-deepseek\nMOONSHOT_API_KEY=global-moonshot\n",
  );
  writeFileSync(
    path.join(project, ".env"),
    "DEEPSEEK_API_KEY=repo-deepseek\nOPENROUTER_API_KEY=repo-openrouter\n",
  );

  const result = spawnSync(launcher, ["--todo", "1440"], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TEST_OUT: captureFile,
      MOONSHOT_API_KEY: "shell-moonshot",
    },
  });

  expect(result.status).toBe(0);
  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("DEEPSEEK_API_KEY:global-deepseek");
  expect(capture).toContain("OPENROUTER_API_KEY:repo-openrouter");
  expect(capture).toContain("MOONSHOT_API_KEY:shell-moonshot");
  expect(capture).not.toContain("repo-deepseek");
});

test("background start is idempotent when the existing tmux session has a live control plane", () => {
  const { result } = runBackgroundLauncher({ existingSession: true, controlReady: true });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("already running in the background");
  expect(result.stderr).toContain("aiur status");
  expect(result.stderr).toContain("aiur stop");

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("TMUX:-L");
  expect(capture).toContain("has-session");
  expect(capture).toContain("BIN_AIUR:rpc");
  expect(capture).not.toContain("new-session");
});

test("idempotent background start preserves the live workspace handoff for degraded stop", async () => {
  const first = runBackgroundLauncher({ keepWatchdogAlive: true });
  expect(first.result.status).toBe(0);

  const instancesDir = path.join(first.stateDir, "instances");
  const [recordName] = readdirSync(instancesDir);
  const recordPath = path.join(instancesDir, recordName);
  const originalRecord = readFileSync(recordPath, "utf8");
  const [, handoffPath] = originalRecord.match(/^AIUR_RECORD_WORKSPACE_ROOT_FILE=(.+)$/m) ?? [];
  expect(handoffPath).toBeTruthy();

  const workspaceRoot = path.join(root, "live-workspace-root");
  mkdirSync(workspaceRoot);
  writeFileSync(handoffPath, `${workspaceRoot}\n`);

  const second = runBackgroundLauncher({ existingSession: true, controlReady: true });
  expect(second.result.status).toBe(0);
  expect(second.result.stderr).toContain("already running in the background");
  expect(readFileSync(recordPath, "utf8")).toBe(originalRecord);
  expect(readFileSync(handoffPath, "utf8")).toBe(`${workspaceRoot}\n`);

  rmSync(first.fakeBeamAlive);
  const watchdogDeadline = Date.now() + 2000;
  while (!existsSync(first.watchdogReaped) && Date.now() < watchdogDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  expect(existsSync(first.watchdogReaped)).toBe(true);
});

test("background start reclaims stale tmux session state before creating a new session", () => {
  const { result } = runBackgroundLauncher({ existingSession: true, controlReady: false });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("found stale tmux session");
  expect(result.stderr).toContain("aiur started in the background");

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("has-session");
  expect(capture).toContain("kill-server");
  expect(capture).toContain("new-session");
});

test("background start still creates a fresh session when no tmux session exists", () => {
  const { result } = runBackgroundLauncher({ existingSession: false, controlReady: true });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("aiur started in the background");

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("has-session");
  expect(capture).toContain("new-session");
  expect(capture).not.toContain("found stale tmux session");
});

// --- Control RPC error reporting -------------------------------------------

// Builds on setupRealLauncher with the two binaries run_control_rpc shells out
// to: the release `bin/aiur` (its `rpc` subcommand) and the bundled epmd
// (`-names`). Behaviour is env-driven so one layout exercises every branch:
//   AIUR_FAKE_RPC_MODE        ok | appfail | noconnection | hang
//   AIUR_FAKE_EPMD_REGISTERED "1" lists our node (up); "error" => -names exits
//                             non-zero (unreachable epmd => unknown); else absent (down)
const CONTROL_NODE = "aiur-test@127.0.0.1";
const CONTROL_SHORT = CONTROL_NODE.split("@")[0];

function setupControlRpc() {
  const { launcher, releaseDir } = setupRealLauncher();

  const binAiur = path.join(releaseDir, "bin", "aiur");
  mkdirSync(path.dirname(binAiur), { recursive: true });
  writeFileSync(
    binAiur,
    [
      "#!/usr/bin/env bash",
      // Only the `rpc <expr>` form is modelled — the one run_control_rpc uses.
      'if [ "$1" = "rpc" ]; then',
      '  expr="${*:2}"',
      '  echo "RPC_EXPR:$expr" >>"$AIUR_TEST_OUT"',
      '  case "${AIUR_FAKE_RPC_MODE:-ok}" in',
      // Transport succeeds; the control CLI prints output + the exit marker.
      '    ok) echo ":ok"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    set_success) echo "aiur: max-agents set to 3 (2 active)"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    set_draining) echo "aiur: max-agents set to 1 (2 active, draining)"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    appfail) echo "__AIUR_CONTROL_EXIT__:7"; exit 0 ;;',
      '    missing_marker) echo ":ok"; echo "remote diagnostic"; exit 0 ;;',
      '    missing_marker_empty) exit 0 ;;',
      '    hang) trap \'echo cleaned >"$AIUR_FAKE_RPC_CLEANUP"; exit 143\' TERM; while :; do sleep 1; done ;;',
      '    hang_descendant) setsid bash -c \'trap "" TERM; while :; do sleep 1; done\' & child=$!; echo "$child" >"$AIUR_FAKE_RPC_CHILD"; wait "$child" ;;',
      // Transport fails the way Elixir --rpc-eval does for an unreachable node.
      '    noconnection) echo "--rpc-eval : RPC failed with reason :noconnection" >&2; exit 1 ;;',
      "  esac",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(binAiur, 0o755);

  const epmd = path.join(releaseDir, "erts-15.0", "bin", "epmd");
  mkdirSync(path.dirname(epmd), { recursive: true });
  writeFileSync(
    epmd,
    [
      "#!/usr/bin/env bash",
      'if [ "$1" = "-names" ]; then',
      // "error" models an unreachable epmd daemon: -names itself exits non-zero.
      '  if [ "${AIUR_FAKE_EPMD_REGISTERED:-0}" = "error" ]; then exit 1; fi',
      '  if [ "${AIUR_FAKE_EPMD_REGISTERED:-0}" = "1" ]; then',
      '    echo "epmd: up and running on port 4369 with data:"',
      `    echo "name ${CONTROL_SHORT} at port 12345"`,
      "  fi",
      "  exit 0",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(epmd, 0o755);

  return { launcher, releaseDir };
}

function runControl(launcher, releaseDir, env, args = ["pause", "--all"]) {
  return spawnSync(launcher, args, {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_RELEASE_NODE: CONTROL_NODE,
      AIUR_BG_STATE_DIR: path.join(root, "state"),
      AIUR_TEST_OUT: captureFile,
      ...env,
    },
  });
}

test("bare pause/resume flip the global switch; targeted forms stay per-agent", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };

  expect(runControl(launcher, releaseDir, env, ["pause"]).status).toBe(0);
  expect(runControl(launcher, releaseDir, env, ["resume"]).status).toBe(0);
  expect(runControl(launcher, releaseDir, env, ["pause", "--all"]).status).toBe(0);
  expect(runControl(launcher, releaseDir, env, ["resume", "44"]).status).toBe(0);

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("Aiur.AgentControlCLI.pause_global()");
  expect(capture).toContain("Aiur.AgentControlCLI.resume_global()");
  expect(capture).toContain("Aiur.AgentControlCLI.pause(:all)");
  expect(capture).toContain('Aiur.AgentControlCLI.resume(["44"])');
});

test("control rpc surfaces the real error when the node is up but the rpc fails", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "noconnection",
    AIUR_FAKE_EPMD_REGISTERED: "1",
  });

  expect(result.status).not.toBe(0);
  // The actual rpc stderr is shown, not masked.
  expect(result.stderr).toContain(":noconnection");
  // The live-node branch fires its own explanatory line...
  expect(result.stderr).toContain("node is running");
  // ...and the misleading "not running" hint is suppressed.
  expect(result.stderr).not.toContain("no running aiur node");
});

test("control rpc surfaces the real error when the node's epmd is unreachable", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "noconnection",
    AIUR_FAKE_EPMD_REGISTERED: "error",
  });

  expect(result.status).not.toBe(0);
  // Indeterminate node state must NOT be assumed "down": surfacing the real
  // error rather than the friendly hint is the regression guard against
  // re-masking a live node whose epmd we simply couldn't reach.
  expect(result.stderr).toContain(":noconnection");
  expect(result.stderr).toContain("could not query epmd to confirm node state");
  expect(result.stderr).not.toContain("no running aiur node");
});

test("control rpc keeps the friendly hint when the node is genuinely down", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "noconnection",
    AIUR_FAKE_EPMD_REGISTERED: "0",
  });

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain(
    "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.",
  );
  // A down node gets the clean hint, not the cryptic transport error.
  expect(result.stderr).not.toContain(":noconnection");
});

test("todo reports a stopped daemon without leaking a GenServer stacktrace", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "noconnection",
      AIUR_FAKE_EPMD_REGISTERED: "0",
    },
    ["--todo", "123"],
  );

  expect(result.status).not.toBe(0);
  expect(result.stderr.trim()).toBe(
    "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.",
  );
  expect(result.stderr).not.toContain("GenServer");
});

test("control rpc propagates the control CLI exit code on a successful rpc", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "appfail",
    AIUR_FAKE_EPMD_REGISTERED: "1",
  });

  // Transport succeeded; the marker's application-level code (7) is the exit,
  // and none of the transport-failure messaging fires.
  expect(result.status).toBe(7);
  expect(result.stderr).not.toContain("no running aiur node");
  expect(result.stderr).not.toContain("rpc to");
});

test("set max-agents succeeds through the control rpc path", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "set_success",
      AIUR_FAKE_EPMD_REGISTERED: "1",
    },
    ["set", "max-agents", "3"],
  );

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("aiur: max-agents set to 3 (2 active)");
  expect(result.stderr).toBe("");

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("Aiur.AgentControlCLI.set_max_agents(3)");
});

test("set max-agents reports below-active caps as draining", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "set_draining",
      AIUR_FAKE_EPMD_REGISTERED: "1",
    },
    ["set", "max-agents", "1"],
  );

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("aiur: max-agents set to 1 (2 active, draining)");
  expect(result.stderr).not.toContain("no running aiur node");
  expect(result.stderr).not.toContain("rpc to");
});

test("alerts supports needs-attention control rpc filter", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "ok",
      AIUR_FAKE_EPMD_REGISTERED: "1",
    },
    ["alerts", "--needs-attention"],
  );

  expect(result.status).toBe(0);

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("Aiur.AgentControlCLI.alerts(needs_attention: true)");
});

test("set max-agents rejects invalid values before rpc", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "set_success",
      AIUR_FAKE_EPMD_REGISTERED: "1",
    },
    ["set", "max-agents", "0"],
  );

  expect(result.status).toBe(64);
  expect(result.stderr).toContain("expects a positive integer");
  expect(existsSync(captureFile)).toBe(false);
});

test("control rpc reports output when the exit marker is missing", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "missing_marker",
    AIUR_FAKE_EPMD_REGISTERED: "1",
  });

  expect(result.status).toBe(1);
  expect(result.stdout).toContain("remote diagnostic");
  expect(result.stderr).toContain("returned no exit marker");
});

test("control rpc is not silent when the exit marker and output are missing", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "missing_marker_empty",
    AIUR_FAKE_EPMD_REGISTERED: "1",
  });

  expect(result.status).toBe(1);
  expect(result.stdout).toBe("");
  expect(result.stderr).toContain("returned no exit marker");
});

test("control rpc timeouts terminate stuck helpers and describe the degraded stop path", () => {
  const { launcher, releaseDir } = setupControlRpc();

  for (const command of ["status", "agents", "pause"]) {
    const cleanup = path.join(root, `rpc-cleanup-${command}`);
    const started = Date.now();
    const result = runControl(
      launcher,
      releaseDir,
      {
        AIUR_FAKE_RPC_MODE: "hang",
        AIUR_FAKE_RPC_CLEANUP: cleanup,
        AIUR_CONTROL_RPC_TIMEOUT_SECONDS: "1",
      },
      command === "pause" ? ["pause", "--all"] : [command],
    );
    const elapsedMs = Date.now() - started;

    expect(result.status).toBe(124);
    expect(elapsedMs).toBeLessThan(5000);
    expect(result.stderr).toContain("control rpc to aiur-test@127.0.0.1 timed out after 1s");
    expect(result.stderr).toContain("for example, 'aiurdev stop'");
    expect(readFileSync(cleanup, "utf8")).toContain("cleaned");
  }

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("Aiur.AgentControlCLI.status()");
  expect(capture).toContain("Aiur.AgentControlCLI.agents()");
  expect(capture).toContain("Aiur.AgentControlCLI.pause(:all)");
});

test("control rpc timeouts reap descendants that escape the wrapper process group", () => {
  if (spawnSync("which", ["setsid"], { encoding: "utf8" }).status !== 0) return;

  const { launcher, releaseDir } = setupControlRpc();
  const childFile = path.join(root, "rpc-child-pid");
  const result = runControl(launcher, releaseDir, {
    AIUR_FAKE_RPC_MODE: "hang_descendant",
    AIUR_FAKE_RPC_CHILD: childFile,
    AIUR_CONTROL_RPC_TIMEOUT_SECONDS: "1",
  });

  expect(result.status).toBe(124);
  const childPid = Number.parseInt(readFileSync(childFile, "utf8"), 10);
  expect(() => process.kill(childPid, 0)).toThrow();
});

// --- Update notifier -------------------------------------------------------

// Seeds the cache the launcher reads. A fresh lastCheck keeps it non-stale so
// the notice tests never spawn a real background fetch.
function seedCache({ latest, lastCheck = Date.now() } = {}) {
  const dir = path.join(root, "aiur");
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "update-check.json"), JSON.stringify({ lastCheck, latest }));
}

// XDG_CACHE_HOME points cache resolution at the temp root; the worker is the
// only thing that ever touches the network, and only via AIUR_REGISTRY_URL.
const notifierEnv = () => ({ XDG_CACHE_HOME: root, PATH: `${root}/fakebin:/usr/bin:/bin` });

const cacheFilePath = () => path.join(root, "aiur", "update-check.json");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A detached background worker writes the cache after the parent exits, so poll
// until it lands (or time out).
async function waitForCache(predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const cache = JSON.parse(readFileSync(cacheFilePath(), "utf8"));
      if (predicate(cache)) return cache;
    } catch (_) {
      // not written yet, or mid-rename
    }
    await sleep(50);
  }
  return null;
}

// Listens, captures the assigned port, then closes — a deterministic
// guaranteed-refused target (vs. assuming nothing listens on a fixed port).
async function refusedUrl() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return `http://127.0.0.1:${port}/aiur-cli/latest`;
}

test("prints an update notice from cache when a newer version is published", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  seedCache({ latest: "2.0.0" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("a new version is available — 1.0.0 → 2.0.0");
  expect(result.stderr).toContain("npm install -g aiur-cli@latest");
});

test("uses semver, not string, comparison (1.2.10 > 1.2.3)", () => {
  const { fakeBin } = setupPackage({ version: "1.2.3" });
  seedCache({ latest: "1.2.10" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });
  expect(result.stderr).toContain("1.2.3 → 1.2.10");
});

test("no notice when the cached latest is not strictly newer", () => {
  const { fakeBin } = setupPackage({ version: "2.0.0" });
  seedCache({ latest: "2.0.0" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("new version is available");
});

test("AIUR_NO_UPDATE_NOTIFIER=1 suppresses the notice", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  seedCache({ latest: "2.0.0" });
  const result = runShim({
    fakeBin,
    forceTTY: true,
    env: { ...notifierEnv(), AIUR_NO_UPDATE_NOTIFIER: "1" },
  });
  expect(result.stderr).not.toContain("new version is available");
});

test("CI=true suppresses the notice", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  seedCache({ latest: "2.0.0" });
  const result = runShim({
    fakeBin,
    forceTTY: true,
    env: { ...notifierEnv(), CI: "true" },
  });
  expect(result.stderr).not.toContain("new version is available");
});

test("dev sentinel version (0.0.0) never notifies", () => {
  const { fakeBin } = setupPackage({ version: "0.0.0" });
  seedCache({ latest: "9.9.9" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });
  expect(result.stderr).not.toContain("new version is available");
});

test("non-interactive (no TTY on stderr) stays quiet", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  seedCache({ latest: "2.0.0" });
  // No forceTTY: spawnSync pipes stderr, so the interactive gate suppresses it.
  const result = runShim({ fakeBin, env: notifierEnv() });
  expect(result.stderr).not.toContain("new version is available");
});

test("background worker fetches latest and writes the cache", async () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ name: "aiur-cli", version: "9.9.9" }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const result = runShim({
    fakeBin,
    env: {
      ...notifierEnv(),
      AIUR_UPDATE_NOTIFIER_WORKER: "1",
      AIUR_REGISTRY_URL: `http://127.0.0.1:${port}/aiur-cli/latest`,
    },
  });
  await new Promise((resolve) => server.close(resolve));

  expect(result.status).toBe(0);
  const cachePath = path.join(root, "aiur", "update-check.json");
  expect(existsSync(cachePath)).toBe(true);
  const cache = JSON.parse(readFileSync(cachePath, "utf8"));
  expect(cache.latest).toBe("9.9.9");
  expect(typeof cache.lastCheck).toBe("number");
});

test("background worker writes the cache even when the registry is unreachable", async () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  const result = runShim({
    fakeBin,
    env: {
      ...notifierEnv(),
      AIUR_UPDATE_NOTIFIER_WORKER: "1",
      AIUR_REGISTRY_URL: await refusedUrl(),
    },
  });
  expect(result.status).toBe(0);
  const cache = JSON.parse(readFileSync(cacheFilePath(), "utf8"));
  expect(cache.latest).toBe(null);
  expect(typeof cache.lastCheck).toBe("number");
});

test("background worker preserves the last known latest when the fetch fails", async () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  // A stale cache from a prior successful check; the failing fetch must not drop it.
  seedCache({ latest: "5.0.0", lastCheck: 0 });
  const result = runShim({
    fakeBin,
    env: {
      ...notifierEnv(),
      AIUR_UPDATE_NOTIFIER_WORKER: "1",
      AIUR_REGISTRY_URL: await refusedUrl(),
    },
  });
  expect(result.status).toBe(0);
  const cache = JSON.parse(readFileSync(cacheFilePath(), "utf8"));
  expect(cache.latest).toBe("5.0.0");
  expect(cache.lastCheck).toBeGreaterThan(0); // refreshed, so the next run is rate-limited
});

test("background worker does not hang on an over-large response", async () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  // A complete response well over the 1MB cap: the worker must trip the cap (or
  // fail to parse the junk) and exit promptly, never hanging on the read.
  const big = '{"version":"9.9.9","junk":"' + "x".repeat(1_500_000) + '"}';
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(big);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const result = runShim({
    fakeBin,
    env: {
      ...notifierEnv(),
      AIUR_UPDATE_NOTIFIER_WORKER: "1",
      AIUR_REGISTRY_URL: `http://127.0.0.1:${port}/aiur-cli/latest`,
    },
  });
  await new Promise((resolve) => server.close(resolve));

  // The worker exited (didn't hang) and stamped lastCheck so it won't respawn.
  expect(result.status).toBe(0);
  const cache = JSON.parse(readFileSync(cacheFilePath(), "utf8"));
  expect(typeof cache.lastCheck).toBe("number");
});

test("a stale cache triggers a detached background refresh", async () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  // Stale cache (lastCheck:0): the run should detach a worker that refreshes it
  // to the live 3.0.0. (The cached notice itself is covered by the fresh-cache
  // test above; here we exercise the stale → spawn → refresh path.)
  seedCache({ latest: "2.0.0", lastCheck: 0 });

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ version: "3.0.0" }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const result = runShim({
    fakeBin,
    env: {
      ...notifierEnv(),
      AIUR_REGISTRY_URL: `http://127.0.0.1:${port}/aiur-cli/latest`,
    },
  });

  expect(result.status).toBe(0);
  const refreshed = await waitForCache((c) => c.latest === "3.0.0");
  await new Promise((resolve) => server.close(resolve));
  expect(refreshed).not.toBeNull(); // the detached worker refreshed the cache
});

test("rejects a version string with trailing junk (no terminal injection)", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  // A valid core followed by control bytes must not parse as newer and must
  // never reach the notice printer verbatim.
  seedCache({ latest: "999.0.0 [2Jpwned" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("new version is available");
  expect(result.stderr).not.toContain("pwned");
});

test("release outranks a same-core prerelease; the reverse does not notify", () => {
  // current is a prerelease, latest is the matching release → notify.
  const a = setupPackage({ version: "1.0.0-rc.1" });
  seedCache({ latest: "1.0.0" });
  const up = runShim({ fakeBin: a.fakeBin, forceTTY: true, env: notifierEnv() });
  expect(up.stderr).toContain("1.0.0-rc.1 → 1.0.0");
});

test("a prerelease is not advertised as an upgrade over the matching release", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  seedCache({ latest: "1.0.0-rc.1" });
  const result = runShim({ fakeBin, forceTTY: true, env: notifierEnv() });
  expect(result.stderr).not.toContain("new version is available");
});

test("a corrupt cache file is ignored (no crash, no notice)", () => {
  const { fakeBin } = setupPackage({ version: "1.0.0" });
  const dir = path.join(root, "aiur");
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "update-check.json"), "{not valid json");
  // No registry server: the worker spawned for the (missing-data) stale cache
  // will fail its fetch quickly and exit; we only assert the launch is unharmed.
  const result = runShim({
    fakeBin,
    forceTTY: true,
    env: { ...notifierEnv(), AIUR_REGISTRY_URL: "http://127.0.0.1:0/none" },
  });
  expect(result.status).toBe(0);
  expect(result.stderr).not.toContain("new version is available");
});
