import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
  chmodSync,
} from "node:fs";
import path from "node:path";
import { root, captureFile, setupRealLauncher, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

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

test("workspace-recover safely encodes the ticket and validates its generation", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const env = { AIUR_FAKE_RPC_MODE: "ok", AIUR_FAKE_EPMD_REGISTERED: "1" };

  const recovered = runControl(launcher, releaseDir, env, ["workspace-recover", "org/repo#44", "7"]);
  expect(recovered.status).toBe(0);
  expect(readFileSync(captureFile, "utf8")).toContain(
    'RPC_EXPR:Aiur.AgentControlCLI.recover_workspace(Base.decode64!("b3JnL3JlcG8jNDQ="), 7)',
  );

  for (const args of [
    ["workspace-recover", "org/repo#44"],
    ["workspace-recover", "org/repo#44", "0"],
    ["workspace-recover", "org/repo#44", "7;System.halt()"],
  ]) {
    rmSync(captureFile, { force: true });
    const result = runControl(launcher, releaseDir, env, args);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("workspace-recover");
    expect(existsSync(captureFile)).toBe(false);
  }
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

test("github-cost fails clearly instead of reading an empty local meter when the daemon is down", () => {
  const { launcher, releaseDir } = setupControlRpc();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "noconnection",
      AIUR_FAKE_EPMD_REGISTERED: "0",
    },
    ["github-cost"],
  );

  expect(result.status).not.toBe(0);
  expect(result.stdout).toBe("");
  expect(result.stderr.trim()).toBe(
    "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.",
  );
  expect(readFileSync(captureFile, "utf8")).toContain(
    'RPC_EXPR:Aiur.AgentControlCLI.github_cost([budget: "graphql"])',
  );
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
  expect(capture).toContain('Aiur.AgentControlCLI.alerts(argv: ["--needs-attention"])');
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

test("control rpc timeouts terminate stuck helpers and report an unknown outcome", () => {
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
    expect(result.stderr).toContain(`${command} to aiur-test@127.0.0.1 timed out after 1s`);
    expect(result.stderr).toContain("outcome is unknown; partial output was discarded");
    expect(readFileSync(cleanup, "utf8")).toContain("cleaned");
  }

  const capture = readFileSync(captureFile, "utf8");
  expect(capture).toContain("Aiur.AgentControlCLI.status()");
  expect(capture).toContain("Aiur.AgentControlCLI.agents()");
  expect(capture).toContain("Aiur.AgentControlCLI.pause(:all)");
}, 15000);

// The timeout budget must be a ceiling, never a floor. A watchdog that holds the
// caller's stdout keeps the pipe open for its whole sleep, so a capturing caller
// blocks past a reply that already arrived — the failure looks like a slow
// daemon and is invisible when output goes to a terminal instead of a pipe.
test("a fast control rpc reply returns immediately instead of waiting out the timeout budget", () => {
  const { launcher, releaseDir } = setupControlRpc();

  for (const command of ["status", "agents", "alerts"]) {
    const started = Date.now();
    // spawnSync captures stdout through a pipe and reads it to EOF, which is
    // exactly the caller shape the leaked watchdog descriptor stalls.
    const result = runControl(
      launcher,
      releaseDir,
      {
        AIUR_FAKE_RPC_MODE: "ok",
        AIUR_FAKE_EPMD_REGISTERED: "1",
        AIUR_CONTROL_RPC_TIMEOUT_SECONDS: "20",
      },
      [command],
    );
    const elapsedMs = Date.now() - started;

    expect(result.status).toBe(0);
    // Far below the 20s budget: any dependence on the budget fails here.
    expect(elapsedMs).toBeLessThan(5000);
  }
});

// A cancelled watchdog must leave nothing behind. The `sleep` is a separate
// process from the subshell that spawned it, so signalling the subshell alone
// orphans a live sleeper that still holds every descriptor it inherited.
test("a cancelled timeout watchdog leaves no sleeping process behind", () => {
  const { launcher, releaseDir } = setupControlRpc();

  const before = sleeperPids();
  const result = runControl(
    launcher,
    releaseDir,
    {
      AIUR_FAKE_RPC_MODE: "ok",
      AIUR_FAKE_EPMD_REGISTERED: "1",
      AIUR_CONTROL_RPC_TIMEOUT_SECONDS: "37",
    },
    ["status"],
  );

  expect(result.status).toBe(0);
  const leaked = sleeperPids("37").filter((pid) => !before.includes(pid));
  expect(leaked).toEqual([]);
});

// PIDs of `sleep <seconds>` processes owned by this user; the distinctive budget
// used above keeps the match specific to the watchdog under test.
function sleeperPids(seconds = "37") {
  const ps = spawnSync("ps", ["-eo", "pid=,args="], { encoding: "utf8" });
  return (ps.stdout || "")
    .split("\n")
    .filter((line) => new RegExp(`\\bsleep ${seconds}\\b`).test(line))
    .map((line) => Number.parseInt(line.trim().split(/\s+/)[0], 10))
    .filter((pid) => Number.isInteger(pid));
}

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
