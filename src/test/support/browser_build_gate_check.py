"""Exercise installed Node admission with real locks and a cheap fake browser."""

from pathlib import Path
import os
import selectors
import signal
import shutil
import subprocess
import sys


root, hook = map(Path, sys.argv[1:])
wrapper = root / ".aiur-runtime/build-bin/node"
assert wrapper.is_file(), "Node admission wrapper was not installed"
real_bin = root / "real-bin"
real_bin.mkdir()
node = real_bin / "node"
node.write_text("""#!/usr/bin/python3
import os, subprocess, sys, time
if sys.argv[-1] == 'nested':
    sys.exit(subprocess.call(['node', '/pkg/playwright/cli.js', 'child']))
if sys.argv[-1] == 'orphan':
    child = os.fork()
    if child == 0:
        os.setsid()  # A Chromium-like child that outlives a crashed run with every inherited fd.
        time.sleep(60)
        os._exit(0)
    print('pids', os.getpid(), child, flush=True)
print('started', flush=True)
if sys.argv[-1] in ('hold', 'orphan'):
    sys.stdin.read(1)
""")
node.chmod(0o755)
gate = root / "gate"
locks = root / "gate.locks"
gate.mkdir()
locks.mkdir()
for slot in (1, 2):
    (locks / f"slot-{slot}.lock").touch()

environment = {
    "PATH": f"{wrapper.parent}:{real_bin}:/usr/bin:/bin",
    "BASH_ENV": str(hook),
    "AIUR_BUILD_GATE_BIN": str(wrapper.parent),
    "AIUR_BUILD_GATE_DIR": str(gate),
    "AIUR_BUILD_GATE_LOCK_DIR": str(locks),
    "AIUR_BUILD_GATE_SLOTS": "2",
    "AIUR_BUILD_GATE_TIMEOUT_SECONDS": "10",
    "AIUR_BUILD_GATE_MAX_HOLD_SECONDS": "20",
    "AIUR_BUILD_GATE_RETAIN_SECONDS": "0",
}
processes = []
orphans = []


def start(script="/pkg/playwright/cli.js", action="hold", env=None):
    process = subprocess.Popen(
        [str(wrapper if env is None else Path(env["AIUR_BUILD_GATE_BIN"]) / "node"), script, action],
        env=environment if env is None else env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
    )
    processes.append(process)
    return process


def line(stream):
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        assert selector.select(15), "admission handshake timed out"
    return stream.readline().decode()


def wait_log(process, text):
    while True:
        value = line(process.stderr)
        assert value, f"command exited before {text}"
        if text in value:
            return


def release(process):
    process.stdin.write(b"x")
    process.stdin.flush()
    assert process.wait(timeout=15) == 0, process.stderr.read().decode()


try:
    first = start()
    assert line(first.stdout) == "started\n"
    expired = start(action="exit", env=dict(environment, AIUR_BUILD_GATE_TIMEOUT_SECONDS="0"))
    assert expired.wait(timeout=15) == 124, expired.stderr.read().decode()
    assert b"browser_workspace_timeout" in expired.stderr.read()
    assert expired.stdout.read() == b""
    second = start("/pkg/node_modules/.bin/playwright")
    wait_log(second, "browser_workspace_wait")
    with selectors.DefaultSelector() as selector:
        selector.register(second.stdout, selectors.EVENT_READ)
        assert not selector.select(0), "second browser started before first exited"
    release(first)
    assert line(second.stdout) == "started\n"
    release(second)

    other = root / "other/.aiur-runtime/build-bin"
    other.mkdir(parents=True)
    shutil.copyfile(wrapper, other / "node")
    (other / "node").chmod(0o755)
    capped = dict(environment, AIUR_BUILD_GATE_SLOTS="1")
    first = start(env=capped)
    assert line(first.stdout) == "started\n"
    second_env = dict(capped, AIUR_BUILD_GATE_BIN=str(other), PATH=f"{other}:{real_bin}:/usr/bin:/bin")
    second = start(env=second_env)
    wait_log(second, "queued slots=1")
    with selectors.DefaultSelector() as selector:
        selector.register(second.stdout, selectors.EVENT_READ)
        assert not selector.select(0), "host cap was bypassed"
    release(first)
    assert line(second.stdout) == "started\n"
    release(second)

    for script in ("/pkg/@playwright/test/cli.js", "/pkg/playwright-core/cli.js", "/pkg/node_modules/.bin/playwright"):
        cli = start(script=script, action="exit")
        assert line(cli.stdout) == "started\n"
        assert cli.wait(timeout=15) == 0
        assert b"acquired" in cli.stderr.read(), f"CLI bypassed admission: {script}"

    # Crash a run (admitted, then inside a live Mix lease) and leave its browser child alive.
    lease = gate / "outer-mix.lease"
    lease.write_text("token=outer-mix\n")
    leased = dict(environment, AIUR_BUILD_GATE_LEASE_PATH=str(lease), AIUR_BUILD_GATE_LEASE_TOKEN="outer-mix")
    for crash_env in (environment, leased):
        crashed = start(action="orphan", env=crash_env)
        _, node_pid, orphan_pid = line(crashed.stdout).split()
        orphans.append(int(orphan_pid))
        assert line(crashed.stdout) == "started\n"
        crashed.kill()
        os.kill(int(node_pid), signal.SIGKILL)
        crashed.wait(timeout=15)
        after_crash = start(action="exit", env=dict(environment, AIUR_BUILD_GATE_TIMEOUT_SECONDS="5"))
        assert after_crash.wait(timeout=15) == 0, "surviving browser child kept the workspace lock"

    nested = start(action="nested")
    assert line(nested.stdout) == "started\n"
    assert nested.wait(timeout=15) == 0
    cheap = start(script="tool.mjs", action="exit")
    assert line(cheap.stdout) == "started\n"
    assert cheap.wait(timeout=15) == 0
    assert b"acquired" not in cheap.stderr.read()
    print("workspace serialization, host cap, crash release, nested lease, passthrough: passed")
finally:
    for pid in orphans:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for process in processes:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=15)
