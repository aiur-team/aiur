import { test, expect } from "bun:test";
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
} from "node:fs";
import path from "node:path";
import { root, captureFile, setupRealLauncher, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

test("Claude login prepares a profile and hands its exact path to the interactive command", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const fakeBin = path.join(root, "login-bin");
  const profileDir = path.join(root, "accounts", "max");
  const receivedEnv = path.join(root, "claude-config-dir");
  mkdirSync(fakeBin, { recursive: true });
  const claude = path.join(fakeBin, "claude");
  writeFileSync(claude, '#!/usr/bin/env bash\nprintf "%s" "$CLAUDE_CONFIG_DIR" > "$AIUR_LOGIN_ENV_CAPTURE"\n');
  chmodSync(claude, 0o755);

  const result = spawnSync("bash", [launcher, "login", "claude", "max", "--dir", profileDir], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TEST_OUT: captureFile,
      AIUR_TEST_PROFILE: profileDir,
      AIUR_LOGIN_ENV_CAPTURE: receivedEnv,
      PATH: `${fakeBin}:${process.env.PATH}`,
    },
  });

  expect(result.status).toBe(0);
  expect(readFileSync(receivedEnv, "utf8")).toBe(profileDir);
  expect(readFileSync(captureFile, "utf8")).toContain(`__login_prepare\nclaude\nmax\n--dir\n${profileDir}`);
});

test("API-key login registers through the local CLI without starting an interactive harness", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const result = spawnSync("bash", [launcher, "login", "deepseek", "work"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TEST_OUT: captureFile,
      PATH: process.env.PATH,
    },
  });

  expect(result.status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain("ELIXIR_ARGS:");
  expect(readFileSync(captureFile, "utf8")).toContain("ARGV_FILE:login");
  expect(readFileSync(captureFile, "utf8")).toContain("DEEPSEEK_API_KEY:");
});

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

  const fakeErtsBin = path.join(releaseDir, "erts-test", "bin");
  mkdirSync(fakeErtsBin, { recursive: true });
  const fakeEpmd = path.join(fakeErtsBin, "epmd");
  writeFileSync(fakeEpmd, "#!/usr/bin/env bash\necho 'epmd: up and running on port 4369 with data:'\n");
  chmodSync(fakeEpmd, 0o755);

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

test("launcher dotenv keeps shell exports and prefers repo-local provider credentials", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const home = path.join(root, "home");
  const project = path.join(root, "project");
  const fakeBin = path.join(root, "fakebin");
  mkdirSync(path.join(home, ".aiur"), { recursive: true });
  mkdirSync(project, { recursive: true });
  mkdirSync(fakeBin, { recursive: true });
  writeFileSync(path.join(fakeBin, "tmux"), "#!/usr/bin/env bash\nexit 1\n");
  chmodSync(path.join(fakeBin, "tmux"), 0o755);
  const tmuxConf = path.join(root, "aiur.tmux.conf");
  writeFileSync(tmuxConf, "# test conf\n");

  writeFileSync(
    path.join(home, ".aiur", ".env"),
    "DEEPSEEK_API_KEY=global-deepseek\nMOONSHOT_API_KEY=global-moonshot\nOPENROUTER_MANAGEMENT_KEY=global-management\n",
  );
  writeFileSync(
    path.join(project, ".env"),
    "DEEPSEEK_API_KEY=repo-deepseek\nOPENROUTER_API_KEY=repo-openrouter\n",
  );

  const env = {
    ...process.env,
    HOME: home,
    PATH: `${fakeBin}:${process.env.PATH}`,
    AIUR_RELEASE_DIR: releaseDir,
    AIUR_TMUX_CONF: tmuxConf,
    AIUR_SESSION_PREFIX: "aiur-test",
    MOONSHOT_API_KEY: "shell-moonshot",
  };
  delete env.DEEPSEEK_API_KEY;
  delete env.OPENROUTER_API_KEY;
  delete env.OPENROUTER_MANAGEMENT_KEY;

  const result = spawnSync("bash", [
    "-c",
    [
      'source "$1"',
      'aiur_resolve_identity() { :; }',
      'prepare_distribution() { :; }',
      'aiur_launch_lock_path() { printf "%s\\n" "$HOME/launch.lock"; }',
      'acquire_aiur_launch_lock() { :; }',
      'scrub_run_only_env() { printf "%s\\n" "$DEEPSEEK_API_KEY" "$OPENROUTER_API_KEY" "$MOONSHOT_API_KEY" "$OPENROUTER_MANAGEMENT_KEY"; exit 0; }',
      'run_session background',
    ].join("\n"),
    "bash",
    launcher,
  ], {
    cwd: project,
    encoding: "utf8",
    env,
  });

  expect(result.status).toBe(0);
  expect(result.stdout.trim().split("\n")).toEqual([
    "repo-deepseek",
    "repo-openrouter",
    "shell-moonshot",
    "global-management",
  ]);
});

test("background start is idempotent when the existing tmux session has a live control plane", () => {
  const { result } = runBackgroundLauncher({ existingSession: true, controlReady: true });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("already running in the background");
  expect(result.stderr).toContain("Attach with: aiur");
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
}, 15000);

test("background start records its headless surface when no tmux session exists", () => {
  const { result, stateDir } = runBackgroundLauncher({ existingSession: false, controlReady: true });

  expect(result.status).toBe(0);
  expect(result.stderr).toContain("aiur started in the background");

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("has-session");
  expect(capture).toContain("new-session");
  expect(capture).not.toContain("found stale tmux session");

  const [recordName] = readdirSync(path.join(stateDir, "instances"));
  const record = readFileSync(path.join(stateDir, "instances", recordName), "utf8");
  expect(record).toContain("AIUR_RECORD_SURFACE_MODE=headless");
});
