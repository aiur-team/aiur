import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const engineDir = fileURLToPath(new URL("../libexec/engine/", import.meta.url));

test("launch lock release stays atomic when TERM arrives after the rename", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-lock-release-"));
  const lock = path.join(root, "node.launch");
  const script = String.raw`
set -euo pipefail
source "$1/instance.sh"
lock="$2"
mkdir -p "$lock"
printf '%s\n' "$$" >"$lock/owner"
rm() {
  command rm "$@"
  for arg in "$@"; do
    if [ "$arg" = "$lock/owner" ]; then kill -TERM "$$"; fi
  done
}
mv() {
  command mv "$@"
  if [ "$1" = "$lock" ]; then kill -TERM "$$"; fi
}
trap 'exit 0' TERM
release_aiur_launch_lock "$lock"
exit 99
`;

  try {
    const result = spawnSync("/bin/bash", ["-c", script, "lock-release-test", engineDir, lock], {
      encoding: "utf8",
    });
    expect(result.status).toBe(0);
    expect(result.error).toBeUndefined();
    expect(existsSync(lock)).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("stale launch lock takeover stays recoverable when TERM interrupts cleanup", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-lock-takeover-"));
  const lock = path.join(root, "node.launch");
  const interruptTakeover = String.raw`
set -euo pipefail
source "$1/instance.sh"
lock="$2"
mkdir -p "$lock"
printf '%s\n' 99999999 >"$lock/owner"
rm() {
  command rm "$@"
  for arg in "$@"; do
    if [ "$arg" = "$lock/owner" ]; then kill -TERM "$$"; fi
  done
}
mv() {
  command mv "$@"
  if [ "$1" = "$lock" ]; then kill -TERM "$$"; fi
}
sleep() { :; }
trap 'exit 0' TERM
AIUR_LAUNCH_LOCK_TICKS=2 acquire_aiur_launch_lock "$lock"
exit 99
`;
  const retryTakeover = String.raw`
set -euo pipefail
source "$1/instance.sh"
sleep() { :; }
AIUR_LAUNCH_LOCK_TICKS=2 AIUR_OWNERLESS_LOCK_STALE_SECONDS=0 \
  acquire_aiur_launch_lock "$2"
`;

  try {
    const interrupted = spawnSync(
      "/bin/bash",
      ["-c", interruptTakeover, "lock-takeover-test", engineDir, lock],
      { encoding: "utf8" },
    );
    expect(interrupted.status, interrupted.stderr).toBe(0);

    const retry = spawnSync(
      "/bin/bash",
      ["-c", retryTakeover, "lock-takeover-retry-test", engineDir, lock],
      { encoding: "utf8" },
    );
    expect(retry.status, retry.stderr).toBe(0);
    expect(retry.error).toBeUndefined();
    expect(existsSync(`${lock}.recovery`)).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a shutdown request before child assignment is honored after launch", () => {
  const script = String.raw`
set -euo pipefail
source "$1/container.sh"
child=""
observed_pid=""
release_cmd=(sleep 30)
_container_shutdown_requested=0
AIUR_CONTAINER_STOP_GRACE_TICKS=1
container_shutdown() {
  observed_pid="$child"
  [ -n "$child" ] || exit 41
  wait_container_child_shutdown "$child" || true
  child=""
}
request_container_shutdown
launch_container_child
[ -z "$child" ] || exit 42
if kill -0 "$observed_pid" 2>/dev/null; then exit 43; fi
exit 0
`;

  const result = spawnSync("/bin/bash", ["-c", script, "deferred-shutdown-test", engineDir], {
    encoding: "utf8",
  });

  expect(result.status, result.stderr).toBe(0);
  expect(result.stderr).toContain("sending SIGKILL");
  expect(result.error).toBeUndefined();
});
