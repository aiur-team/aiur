#!/usr/bin/env python3
"""Own a Linux build slot until a Mix process tree exits."""

import ctypes
import errno
import os
import signal
import stat
import subprocess
import sys
import time


POLL_SECONDS = 0.01
TERM_GRACE_SECONDS = 1.0
# Absolute wall-clock backstop for a leased slot (#2349). A slot is a shared
# fleet resource; nothing may hold one indefinitely because of a bookkeeping
# bug — an externally-reaped command, a process-group kill, or a daemon
# reparented onto this subreaper that keeps `reap_remaining_children` from ever
# seeing ECHILD. When `AIUR_BUILD_GATE_MAX_HOLD_SECONDS` expires the holder
# releases the lease and leaves a durable `slot-N.hold-timeout` marker the
# daemon turns into a needs-attention alert naming the command (#2311).
HOLD_TIMEOUT_STATUS = 124
_cancel_signal = None
_hold_timeout_reason = None


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

    parent_pid_int = int(parent_pid)
    agent_pgid_int = int(agent_pgid)
    handshake_deadline = time.monotonic() + max(1, int(handshake_seconds))
    hold_deadline = max_hold_deadline()
    process = None

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
        write_reserved_regular(command_pid_path, f"{process.pid}\n")

        wait_until_ready(command_ready_path, "ready\n", parent_pid_int, handshake_deadline)

        if os.environ.get("AIUR_BUILD_GATE_HOLDER_FAIL_AFTER_POPEN") == "1":
            raise RuntimeError("injected post-Popen holder failure")

        detach_standard_streams(int(lease_fd))

        result = wait_for_command(process, parent_pid_int, hold_deadline)
        if result < 0:
            result = 128 - result

        retained = reap_exited_children()
        write_reserved_regular(status_path, f"{result} {int(retained)}\n")
        ack_deadline = time.monotonic() + max(1, int(ack_seconds))
        wait_for_status_ack(status_ack_path, token, parent_pid_int, ack_deadline)

        # The absolute hold cap can fire inside `reap_remaining_children` (the
        # wrapped command already exited but adopted descendants kept the wait
        # alive) or inside `wait_for_command` (the command itself ran past the
        # cap). Both paths record the timeout; write the durable marker either
        # way so the daemon can raise a needs-attention alert naming the
        # command.
        if _hold_timeout_reason is None:
            reap_remaining_children(agent_pgid_int, hold_deadline, process.pid)

        if _hold_timeout_reason is not None:
            write_hold_timeout_marker(owner_path, command, max_hold_seconds(), _hold_timeout_reason)

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


def read_regular(path: str) -> int:
    descriptor = None

    try:
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return 125

        contents = os.read(descriptor, 4096)
        if len(contents) == 4096:
            return 125

        sys.stdout.buffer.write(contents)
        return 0
    except FileNotFoundError:
        return 1
    except OSError:
        return 125
    finally:
        if descriptor is not None:
            os.close(descriptor)


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


def open_regular(path: str, flags: int) -> int:
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    descriptor = os.open(path, flags | os.O_NONBLOCK)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise OSError(errno.EINVAL, "build-gate metadata is not a regular file")

    return descriptor


def read_regular_bytes(path: str) -> bytes:
    descriptor = open_regular(path, os.O_RDONLY)
    try:
        contents = os.read(descriptor, 4096)
        if len(contents) == 4096:
            raise OSError(errno.EFBIG, "build-gate metadata is too large")
        return contents
    finally:
        os.close(descriptor)


def write_reserved_regular(path: str, contents: str) -> None:
    descriptor = open_regular(path, os.O_WRONLY)
    try:
        encoded = contents.encode("utf-8")
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        while encoded:
            written = os.write(descriptor, encoded)
            encoded = encoded[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


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


def wait_for_command(process: subprocess.Popen, parent_pid: int, hold_deadline: float | None) -> int:
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
            # The command is still alive, so terminate it rather than let a
            # single serialised run (`--trace`, #2311) starve the fleet, then
            # report the timeout to the wrapper.
            record_hold_timeout("running")
            terminate_process_tree(process.pid)
            return HOLD_TIMEOUT_STATUS

        time.sleep(POLL_SECONDS)


def terminate_process_tree(root_pid: int) -> None:
    signal_tree(root_pid, signal.SIGTERM)
    deadline = time.monotonic() + TERM_GRACE_SECONDS

    while process_tree_alive(root_pid) and time.monotonic() < deadline:
        reap_exited_children()
        time.sleep(POLL_SECONDS)

    if process_tree_alive(root_pid):
        signal_tree(root_pid, signal.SIGKILL)

    while process_tree_alive(root_pid):
        reap_exited_children()
        time.sleep(POLL_SECONDS)

    reap_exited_children()


def signal_tree(root_pid: int, signal_number: int) -> None:
    pids = descendants_of(root_pid)
    pids.add(root_pid)

    # Once the direct command exits, daemonized descendants are reparented to
    # this subreaper and no longer appear below root_pid in /proc. Every child
    # of the holder still belongs to this one leased command tree.
    for child in proc_children(os.getpid()):
        pids.add(child)
        pids.update(descendants_of(child))

    own_group = os.getpgrp()
    groups = set()

    for pid in pids:
        try:
            group = os.getpgid(pid)
        except ProcessLookupError:
            continue

        if group != own_group:
            groups.add(group)

    for group in groups:
        try:
            os.killpg(group, signal_number)
        except ProcessLookupError:
            pass

    for pid in pids:
        try:
            os.kill(pid, signal_number)
        except ProcessLookupError:
            pass


def descendants_of(root_pid: int) -> set[int]:
    descendants = set()
    pending = [root_pid]

    while pending:
        parent = pending.pop()
        for child in proc_children(parent):
            if child not in descendants:
                descendants.add(child)
                pending.append(child)

    return descendants


def proc_children(pid: int) -> list[int]:
    path = f"/proc/{pid}/task/{pid}/children"

    try:
        with open(path, encoding="utf-8") as file:
            return [int(value) for value in file.read().split()]
    except (FileNotFoundError, ProcessLookupError):
        return []


def process_tree_alive(root_pid: int) -> bool:
    return pid_alive(root_pid) or bool(descendants_of(root_pid)) or bool(proc_children(os.getpid()))


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_group_alive(pgid: int) -> bool:
    if pgid <= 0:
        return True

    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def detach_standard_streams(lease_fd: int) -> None:
    devnull = os.open(os.devnull, os.O_RDWR)

    for standard_fd in (0, 1, 2):
        os.dup2(devnull, standard_fd)

    if devnull > 2:
        os.close(devnull)

    for fd_name in os.listdir("/proc/self/fd"):
        fd = int(fd_name)

        if fd > 2 and fd != lease_fd:
            try:
                os.close(fd)
            except OSError:
                pass


def reap_exited_children() -> bool:
    retained = False

    while True:
        try:
            child_pid, _child_status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return retained

        if child_pid == 0:
            return True


def reap_remaining_children(
    agent_pgid: int, hold_deadline: float | None, command_pid: int
) -> None:
    while True:
        raise_if_cancelled()

        if not process_group_alive(agent_pgid):
            raise InterruptedError("agent process group exited while descendants retained the lease")

        # Backstop (#2349): after the wrapped command exits, the holder keeps
        # the lease only to protect genuine Mix descendants. A daemon
        # reparented onto this subreaper (dbus, keyring, ...) can keep
        # `waitpid(-1)` returning non-ECHILD forever while the agent group
        # lives — the observed >1h leak. When the cap expires, terminate the
        # adopted descendants so the release is clean and log a marker the
        # daemon surfaces as a needs-attention alert.
        if hold_deadline is not None and time.monotonic() >= hold_deadline:
            record_hold_timeout("retained")
            terminate_process_tree(command_pid)
            return

        try:
            child_pid, _child_status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return

        if child_pid == 0:
            time.sleep(POLL_SECONDS)


def max_hold_seconds() -> int:
    value = os.environ.get("AIUR_BUILD_GATE_MAX_HOLD_SECONDS", "0")

    try:
        hold = max(0, int(value))
    except ValueError:
        hold = 0

    return hold


def max_hold_deadline() -> float | None:
    hold = max_hold_seconds()
    return time.monotonic() + hold if hold > 0 else None


def record_hold_timeout(reason: str) -> None:
    global _hold_timeout_reason
    _hold_timeout_reason = reason
    print(
        f"aiur_build_gate hold_timeout reason={reason}",
        file=sys.stderr,
        flush=True,
    )


def hold_timeout_marker_path(owner_path: str) -> str:
    if owner_path.endswith(".owner"):
        return owner_path[: -len(".owner")] + ".hold-timeout"
    return owner_path + ".hold-timeout"


def write_hold_timeout_marker(
    owner_path: str, command: list[str], held_for_seconds: int, reason: str
) -> None:
    """Leave the durable record the daemon's BuildGateHoldMonitor consumes.

    Best effort only: a marker that cannot be written must not prevent the
    slot release — the holder's own log line is the fallback signal. The
    marker path is new (unlike the bash-mktemp'd handshake files), so it is
    created explicitly and published atomically via a temp + rename so a
    polling reader never sees a partial record.
    """
    try:
        marker_path = hold_timeout_marker_path(owner_path)
        temp_path = marker_path + ".tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        descriptor = os.open(temp_path, flags, 0o644)
        try:
            encoded = (
                "version=2\n"
                f"command={' '.join(command)}\n"
                f"held_for_seconds={int(held_for_seconds)}\n"
                f"reason={reason}\n"
            ).encode("utf-8")
            while encoded:
                written = os.write(descriptor, encoded)
                encoded = encoded[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        os.rename(temp_path, marker_path)
    except OSError:
        pass


def remove_owned_metadata(path: str, token: str) -> None:
    descriptor = None

    try:
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return

        contents = os.read(descriptor, 64 * 1024).decode("utf-8", errors="replace")
        if f"token={token}\n" in contents:
            remove_if_present(path)
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ELOOP, errno.ENXIO):
            pass
    finally:
        if descriptor is not None:
            os.close(descriptor)


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


def cleanup_paths(*paths: str) -> None:
    for path in paths:
        remove_if_present(path)


def remove_if_present(path: str) -> None:
    try:
        os.unlink(path)
    except (FileNotFoundError, IsADirectoryError):
        pass


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--read-regular":
        sys.exit(read_regular(sys.argv[2]))

    if len(sys.argv) == 4 and sys.argv[1] == "--write-reserved-regular":
        try:
            write_reserved_regular(sys.argv[2], sys.argv[3] + "\n")
            sys.exit(0)
        except OSError:
            sys.exit(125)

    sys.exit(main())
