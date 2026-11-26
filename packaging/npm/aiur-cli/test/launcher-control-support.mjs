import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { captureFile, root, setupRealLauncher } from "./launcher-support.mjs";

const CONTROL_NODE = "aiur-test@127.0.0.1";
const CONTROL_SHORT = CONTROL_NODE.split("@")[0];

export function setupControlRpc() {
  const { launcher, releaseDir } = setupRealLauncher();

  const binAiur = path.join(releaseDir, "bin", "aiur");
  mkdirSync(path.dirname(binAiur), { recursive: true });
  writeFileSync(
    binAiur,
    [
      "#!/usr/bin/env bash",
      'if [ "$1" = "rpc" ]; then',
      '  expr="${*:2}"',
      '  echo "RPC_EXPR:$expr" >>"$AIUR_TEST_OUT"',
      '  echo "RPC_TIMEOUT:${AIUR_CONTROL_RPC_TIMEOUT_SECONDS:-10}" >>"$AIUR_TEST_OUT"',
      '  case "${AIUR_FAKE_RPC_MODE:-ok}" in',
      '    ok) echo ":ok"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    set_success) echo "aiur: max-agents set to 3 (2 active)"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    set_draining) echo "aiur: max-agents set to 1 (2 active, draining)"; echo "__AIUR_CONTROL_EXIT__:0"; exit 0 ;;',
      '    appfail) echo "__AIUR_CONTROL_EXIT__:7"; exit 0 ;;',
      '    missing_marker) echo ":ok"; echo "remote diagnostic"; exit 0 ;;',
      '    missing_marker_empty) exit 0 ;;',
      '    hang) trap \'echo cleaned >"$AIUR_FAKE_RPC_CLEANUP"; exit 143\' TERM; echo "partial reply"; while :; do sleep 1; done ;;',
      '    hang_descendant) setsid bash -c \'trap "" TERM; while :; do sleep 1; done\' & child=$!; echo "$child" >"$AIUR_FAKE_RPC_CHILD"; wait "$child" ;;',
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

export function runControl(launcher, releaseDir, env, args = ["pause", "--all"]) {
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
