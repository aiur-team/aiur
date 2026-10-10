import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const engine = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));

function exercise(mode) {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-supervisor-"));
  writeFileSync(path.join(root, "daemon"), `#!/usr/bin/env bash
if [ "\${1:-}" = rpc ]; then
  [ -f "$ROOT/recovered" ] || exit 1
  echo __AIUR_RECOVERED__
  exit 0
fi
printf '%s\\n' "$$" > "$ROOT/daemon-pid"
if [ -f "$ROOT/booted" ]; then
  touch "$ROOT/recovered"
else
  touch "$ROOT/booted"
  printf 'old dump\\n' > "$ERL_CRASH_DUMP"
fi
if [ "$MODE" = boot-failure ]; then exit 1; fi
if [ "$MODE" = normal ]; then exit 0; fi
exec sleep 120
`, { mode: 0o755 });
  const result = spawnSync("bash", ["-c", `
source "$ENGINE"
export AIUR_LOGS_ROOT="$ROOT/logs" ERL_CRASH_DUMP="$ROOT/erl_crash.dump"
export AIUR_ALERT_LEDGER_PATH_FILE="$ROOT/ledger-path" AIUR_AGENT_TMPFILE="$ROOT/agents"
export AIUR_WORKSPACE_ROOT_FILE="$ROOT/workspace-root" AIUR_TMUX_SOCKET="unused"
export AIUR_BG_STATE_DIR="$ROOT/state" AIUR_RELEASE_DIR="$ROOT/release" RELEASE_NODE=test
mkdir -p "$ROOT/release/bin" "$ROOT/state"
ln -s "$ROOT/daemon" "$ROOT/release/bin/aiur"
printf '%s' "$ROOT/ledger.ndjson" > "$ROOT/ledger-path"
: > "$ROOT/agents"
: > "$ROOT/workspace-root"
# No real tmux sessions are touched by this process-level test.
tmux() { :; }
export -f tmux
supervise_daemon "$ROOT/supervisor" "$ROOT/capture" "$ROOT/baseline" "$ROOT/daemon" &
supervisor=$!
trap 'kill "$supervisor" 2>/dev/null || true; if [ -f "$ROOT/daemon-pid" ]; then kill "$(cat "$ROOT/daemon-pid")" 2>/dev/null || true; fi' EXIT
if [ "$MODE" = normal ] || [ "$MODE" = boot-failure ]; then
  wait "$supervisor" || true
else
  for ((i=0;i<200;i++)); do [ -s "$ROOT/daemon-pid" ] && break; sleep 0.01; done
  printf 'ready\\n' >> "$ROOT/supervisor"
  old_pid="$(cat "$ROOT/daemon-pid")"
  if [ "$MODE" = stop ]; then touch "$(aiur_stop_sentinel_path)"; fi
  kill -KILL "$old_pid"
  if [ "$MODE" = crash ]; then
    for ((i=0;i<500;i++)); do
      grep -q system.daemon.restarted "$ROOT/ledger.ndjson" 2>/dev/null && break
      sleep 0.01
    done
    touch "$(aiur_stop_sentinel_path)"
    kill -TERM "$(cat "$ROOT/daemon-pid")" 2>/dev/null || true
  fi
  wait "$supervisor" || true
fi
`], {
    encoding: "utf8", timeout: 15000,
    env: { ...process.env, ROOT: root, ENGINE: engine, MODE: mode, TMPDIR: root },
  });
  return { root, result };
}

test("SIGKILL restarts the daemon and preserves its dump and outage alerts", () => {
  const { root, result } = exercise("crash");
  try {
    expect(result.status).toBe(0);
    expect(readFileSync(path.join(root, "recovered"), "utf8")).toBe("");
    const dumps = readdirSync(root).filter(name => name.startsWith("erl_crash.dump."));
    expect(dumps).toHaveLength(1);
    expect(readFileSync(path.join(root, dumps[0]), "utf8")).toBe("old dump\n");
    const alerts = readFileSync(path.join(root, "ledger.ndjson"), "utf8").trim().split("\n").map(JSON.parse);
    expect(alerts.map(alert => alert.name)).toEqual(["system.daemon.down", "system.daemon.restarted"]);
    expect(alerts[1].message).toBe("Daemon restarted after crash");
    expect(alerts[1].reason).toMatch(/^Daemon down since \d{4}-/);
    expect(readFileSync(path.join(root, "logs/log/aiur.recovery"), "utf8")).toContain("Daemon restarted after crash");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

for (const mode of ["normal", "stop", "boot-failure"]) {
  test(`${mode} does not restart the daemon`, () => {
    const { root, result } = exercise(mode);
    try {
      expect(result.status).toBe(0);
      expect(readdirSync(root)).not.toContain("recovered");
      expect(readdirSync(root)).not.toContain("ledger.ndjson");
    } finally { rmSync(root, { recursive: true, force: true }); }
  });
}
