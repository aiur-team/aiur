#!/usr/bin/env python3
"""Own a Linux build slot until a Mix process tree exits."""

import ctypes
import fcntl
import os
import signal
import subprocess
import sys
import time

# The library sits beside this script. `python -c` and `runpy` callers do not
# put the script directory on the path, and a read-only release tree must not
# be asked to cache bytecode.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_gate_holder_lib.files import (  # noqa: E402
    cleanup_paths,
    max_hold_deadline,
    read_regular,
    read_regular_bytes,
    remove_owned_metadata,
    retain_deadline,
    retain_seconds,
    scan_locks_manifest,
    write_hold_timeout_marker,
    write_reserved_regular,
)
# `proc_cpu_ns` is re-exported for callers that load this script by path.
from build_gate_holder_lib.process_tree import (  # noqa: E402,F401
    POLL_SECONDS,
    detach_standard_streams,
    pid_alive,
    proc_cpu_ns,
    process_group_alive,
    reap_exited_children,
    record_spawned_root,
    subtree_cpu_ns,
    terminate_process_tree,
)


# Absolute wall-clock backstop for a leased slot (#2349). A slot is a shared
# fleet resource; nothing may hold one indefinitely because of a bookkeeping
# bug — an externally-reaped command, a process-group kill, or a daemon
# reparented onto this subreaper that keeps `reap_remaining_children` from ever
# seeing ECHILD. When `AIUR_BUILD_GATE_MAX_HOLD_SECONDS` expires the holder
# releases the lease and leaves a durable `slot-N.hold-timeout` marker the
# daemon turns into a needs-attention alert naming the command (#2311).
HOLD_TIMEOUT_STATUS = 124
# Post-command retain tuning (#2398). The holder keeps the slot after the
# wrapped command exits only while a descendant is still consuming CPU — a
# genuine Mix child finishing the build's work. Adopted session daemons
# (dbus-daemon, gnome-keyring-daemon) reparent onto this subreaper and never
# exit, so the `waitpid` ECHILD early-exit is unreachable while either is
# alive; holding the full retain window for an idle daemon is what saturated
# the gate (every slot "held without a command" for 120s). The holder samples
# the descendant subtree's consumed CPU and releases as soon as the tree has
# been idle for a full window.
CPU_SAMPLE_SECONDS = 0.1
CPU_IDLE_WINDOW_SECONDS = 1.0
# CPU consumed by the whole descendant subtree across a full idle window that
# counts as "build work" rather than an idle daemon. 3ms/s is 0.3% of one
# core — far below a compiling Mix child, far above a dormant session daemon.
CPU_IDLE_BUSY_THRESHOLD_NS = 3_000_000
_cancel_signal = None
_hold_timeout_reason = None
_lease_fd = None
_lease_released = False
_started_monotonic = time.monotonic()


def main() -> int:
    (
        ready_path,
        started_path,
        command_pid_path,
        command_ready_path,
        status_path,
        status_ack_path,
        owner_path,
        token,
        parent_pid,
        agent_pgid,
        lease_fd,
        handshake_seconds,
        ack_seconds,
        *command,
    ) = sys.argv[1:]

    global _lease_fd, _started_monotonic

    parent_pid_int = int(parent_pid)
    agent_pgid_int = int(agent_pgid)
    _started_monotonic = time.monotonic()
    handshake_deadline = time.monotonic() + max(1, int(handshake_seconds))
    hold_deadline = max_hold_deadline()
    process = None
    _lease_fd = int(lease_fd)

    try:
        become_subreaper()
        install_signal_handlers()
        wait_start_delay()
        raise_if_cancelled()
        write_reserved_regular(started_path, "started\n")
        wait_until_ready(ready_path, "ready\n", parent_pid_int, handshake_deadline)

        command_environment = os.environ.copy()
        command_environment["AIUR_BUILD_GATE_LEASE_PATH"] = owner_path
        command_environment["AIUR_BUILD_GATE_LEASE_TOKEN"] = token
        process = subprocess.Popen(
            command,
            close_fds=True,
            start_new_session=True,
            env=command_environment,
        )
        record_spawned_root(process.pid)
        write_reserved_regular(command_pid_path, f"{process.pid}\n")

        wait_until_ready(command_ready_path, "ready\n", parent_pid_int, handshake_deadline)

        if os.environ.get("AIUR_BUILD_GATE_HOLDER_FAIL_AFTER_POPEN") == "1":
            raise RuntimeError("injected post-Popen holder failure")

        detach_standard_streams(int(lease_fd))

        result = wait_for_command(process, parent_pid_int, hold_deadline, owner_path, token)
        if result < 0:
            result = 128 - result

        retained = reap_exited_children()
        write_reserved_regular(status_path, f"{result} {int(retained)}\n")
        ack_deadline = time.monotonic() + max(1, int(ack_seconds))
        wait_for_status_ack(status_ack_path, token, parent_pid_int, ack_deadline)

        # A hold can end on its deadline inside `reap_remaining_children` (the
        # wrapped command already exited but adopted descendants kept the wait
        # alive) or inside `wait_for_command` (the command itself ran past the
        # absolute cap). Both paths record the timeout; write the durable
        # marker either way so the daemon can raise a needs-attention alert
        # naming the command.
        if _hold_timeout_reason is None:
            reap_remaining_children(
                retain_deadline(hold_deadline), owner_path, token, agent_pgid_int
            )

        if _hold_timeout_reason is not None:
            write_hold_timeout_marker(owner_path, command, held_for_seconds(), _hold_timeout_reason)

        remove_owned_metadata(owner_path, token)
        cleanup_paths(
            ready_path,
            started_path,
            command_pid_path,
            command_ready_path,
            status_path,
            status_ack_path,
        )
        return 0
    except BaseException:
        if process is not None:
            terminate_process_tree(process.pid)

        release_lease()

        remove_owned_metadata(owner_path, token)
        cleanup_paths(
            ready_path,
            started_path,
            command_pid_path,
            command_ready_path,
            status_path,
            status_ack_path,
        )
        return 125


def become_subreaper() -> None:
    libc = ctypes.CDLL(None, use_errno=True)

    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER) failed")


def install_signal_handlers() -> None:
    for signal_number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signal_number, record_cancel_signal)


def record_cancel_signal(signal_number, _frame) -> None:
    global _cancel_signal
    _cancel_signal = signal_number


def raise_if_cancelled() -> None:
    if _cancel_signal is not None:
        raise InterruptedError(f"lease holder cancelled by signal {_cancel_signal}")


def wait_start_delay() -> None:
    value = os.environ.get("AIUR_BUILD_GATE_HOLDER_START_DELAY_SECONDS", "0")

    try:
        delay = max(0.0, float(value))
    except ValueError:
        delay = 0.0

    deadline = time.monotonic() + delay
    while time.monotonic() < deadline:
        raise_if_cancelled()
        time.sleep(min(POLL_SECONDS, deadline - time.monotonic()))


def wait_until_ready(path: str, expected: str, parent_pid: int, deadline: float) -> None:
    expected_bytes = expected.encode("utf-8")
    while True:
        raise_if_cancelled()

        if not pid_alive(parent_pid):
            raise SystemExit(125)

        if time.monotonic() >= deadline:
            raise TimeoutError("build-gate handshake deadline expired")

        if read_regular_bytes(path) == expected_bytes:
            return

        time.sleep(POLL_SECONDS)


def wait_for_command(
    process: subprocess.Popen,
    parent_pid: int,
    hold_deadline: float | None,
    owner_path: str,
    token: str,
) -> int:
    while True:
        result = process.poll()
        if result is not None:
            return result

        if _cancel_signal is not None or not pid_alive(parent_pid):
            terminate_process_tree(process.pid)
            result = process.poll()
            return 125 if result is None else result

        if hold_deadline is not None and time.monotonic() >= hold_deadline:
            # The wrapped command has run past the absolute slot cap (#2349).
            # Hand the slot back first (#2381): capacity must return even if
            # terminating this command turns out to be slow or impossible.
            # Then terminate it rather than let a single serialised run
            # (`--trace`, #2311) starve the fleet, and report the timeout.
            record_hold_timeout("running")
            release_slot(owner_path, token)
            terminate_process_tree(process.pid)
            return HOLD_TIMEOUT_STATUS

        time.sleep(POLL_SECONDS)


def release_lease() -> None:
    """Drop the slot flock, immediately and irreversibly.

    The lease lives in a single inherited descriptor; the wrapper closed its
    own copy once the handshake completed, so closing this one frees the slot
    for the next build. Releasing is idempotent and never raises: a slot that
    cannot be released is the failure this module exists to prevent.
    """
    global _lease_released

    if _lease_released or _lease_fd is None:
        return

    _lease_released = True

    try:
        fcntl.flock(_lease_fd, fcntl.LOCK_UN)
    except OSError:
        pass

    try:
        os.close(_lease_fd)
    except OSError:
        pass


def release_slot(owner_path: str, token: str) -> None:
    """Free the slot completely: the flock and the owner record together.

    Called *before* cleanup, never after it. Cleanup failing is survivable; a
    slot wedged inside cleanup starves every queued build (#2381).
    """
    release_lease()
    remove_owned_metadata(owner_path, token)


def reap_remaining_children(
    retain_until: float | None, owner_path: str, token: str, agent_pgid: int
) -> None:
    """Keep the slot only while a descendant is still doing the build's work.

    After the wrapped command exits the holder has no way to tell a genuine
    Mix descendant from a session daemon reparented onto this subreaper
    (`dbus-daemon`, `gnome-keyring-daemon` — the `waitpid` ECHILD early-exit
    is unreachable while either is alive). Retaining the full window for an
    idle daemon held every slot for 120s after every build (#2398), so the
    courtesy is now CPU-gated: a tree that has consumed no CPU for a full
    idle window is not compiling, and the slot is released immediately.
    Nothing is ever signalled — the keyring daemon holds the fleet's GitHub
    credential.
    """
    # A `0` retain window disables the courtesy entirely: the wrapped command
    # has already exited, so the slot is handed straight back.
    if retain_seconds() == 0:
        return

    # Reap anything that exited while the command's status was being handed
    # off. A tree with no live descendants has nothing to protect.
    if not reap_exited_children():
        return

    last_sample = time.monotonic()
    window_start = last_sample
    window_cpu = subtree_cpu_ns()

    while True:
        raise_if_cancelled()

        if not process_group_alive(agent_pgid):
            raise InterruptedError("agent process group exited while descendants retained the lease")

        # Backstop (#2349, bounded properly in #2381, CPU-gated in #2398):
        # after the wrapped command exits, the holder keeps the lease only to
        # protect descendants still consuming CPU. A daemon reparented onto
        # this subreaper keeps `waitpid(-1)` from ever reaching ECHILD, so the
        # deadline is the guaranteed release for a busy descendant.
        #
        # On expiry: give the slot back and stop. Nothing is signalled. The
        # holder cannot distinguish a stuck build descendant from a session
        # daemon that a `git`/`gh` credential lookup autolaunched under the
        # build, and killing the latter takes the keyring — and with it the
        # fleet's GitHub access — down. A leaked process is a smaller failure
        # than a wedged slot or a broken credential store, and the marker
        # written by the caller names the command for a needs-attention alert.
        if retain_until is not None and time.monotonic() >= retain_until:
            record_hold_timeout("retained")
            release_slot(owner_path, token)
            return

        try:
            child_pid, _child_status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return

        if child_pid == 0:
            now = time.monotonic()

            if now - last_sample >= CPU_SAMPLE_SECONDS:
                last_sample = now
                current_cpu = subtree_cpu_ns()

                if current_cpu is not None:
                    if window_cpu is None:
                        window_cpu = current_cpu
                        window_start = now
                    elif current_cpu - window_cpu > CPU_IDLE_BUSY_THRESHOLD_NS:
                        # The tree is consuming CPU — a genuine Mix child is
                        # still compiling. Keep the lease and restart the idle
                        # window.
                        window_cpu = current_cpu
                        window_start = now
                    elif now - window_start >= CPU_IDLE_WINDOW_SECONDS:
                        # No descendant has consumed CPU for a full idle
                        # window: they are adopted session daemons, not build
                        # work. Give the slot back immediately, without
                        # signalling anything.
                        release_slot(owner_path, token)
                        return

                # Measurement unavailable for every live descendant (all raced
                # exit, or /proc is not readable): keep the slot
                # conservatively — the waitpid reaping either confirms the
                # tree is gone or measurement recovers.

            time.sleep(POLL_SECONDS)


def held_for_seconds() -> int:
    return max(0, int(time.monotonic() - _started_monotonic))


def record_hold_timeout(reason: str) -> None:
    global _hold_timeout_reason
    _hold_timeout_reason = reason
    print(
        f"aiur_build_gate hold_timeout reason={reason}",
        file=sys.stderr,
        flush=True,
    )


def wait_for_status_ack(path: str, token: str, parent_pid: int, deadline: float) -> None:
    expected = f"ack={token}\n".encode("utf-8")

    while True:
        raise_if_cancelled()

        if read_regular_bytes(path) == expected:
            return

        if not pid_alive(parent_pid):
            raise SystemExit(125)

        if time.monotonic() >= deadline:
            raise TimeoutError("build-gate status acknowledgement deadline expired")

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--read-regular":
        sys.exit(read_regular(sys.argv[2]))

    if len(sys.argv) == 4 and sys.argv[1] == "--write-reserved-regular":
        try:
            write_reserved_regular(sys.argv[2], sys.argv[3] + "\n")
            sys.exit(0)
        except OSError:
            sys.exit(125)

    if len(sys.argv) == 3 and sys.argv[1] == "--scan-locks-manifest":
        sys.exit(scan_locks_manifest(sys.argv[2]))

    sys.exit(main())
