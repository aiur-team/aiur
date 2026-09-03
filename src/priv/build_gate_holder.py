#!/usr/bin/env python3
"""Own a Linux build slot until a Mix process tree exits."""

import ctypes
import base64
import errno
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import time


POLL_SECONDS = 0.01
TERM_GRACE_SECONDS = 1.0
SCAN_CANDIDATE_LIMIT = 512
SCAN_DETAIL_LIMIT = 64
SCAN_ISSUE_LIMIT = 32
SCAN_METADATA_BUDGET = 64 * 1024
SCAN_MANIFEST_LIMIT = 16 * 1024
# Absolute wall-clock backstop for a leased slot (#2349). A slot is a shared
# fleet resource; nothing may hold one indefinitely because of a bookkeeping
# bug — an externally-reaped command, a process-group kill, or a daemon
# reparented onto this subreaper that keeps `reap_remaining_children` from ever
# seeing ECHILD. When `AIUR_BUILD_GATE_MAX_HOLD_SECONDS` expires the holder
# releases the lease and leaves a durable `slot-N.hold-timeout` marker the
# daemon turns into a needs-attention alert naming the command (#2311).
HOLD_TIMEOUT_STATUS = 124
# Bound on the *post-command* retain (#2381). Once the wrapped command exits,
# the holder keeps the slot only as a courtesy to descendants that are still
# doing the build's work. It cannot tell those apart from a session daemon
# reparented onto it — `dbus-daemon` and `gnome-keyring-daemon` autolaunched by
# a `git`/`gh` credential lookup both land here and never exit — so the
# courtesy is time-boxed well below the absolute cap. Four slots leaked for
# forty minutes waiting on daemons that were never going to exit. Since #2398
# the courtesy is CPU-gated (see the retain-tuning block below): an idle
# adopted daemon no longer holds the slot for the full window.
DEFAULT_RETAIN_SECONDS = 120
# Absolute bound on any descendant-cleanup loop (#2381). Cleanup is best
# effort: a descendant that will not die must never keep the holder spinning,
# because a wedged slot starves every queued build while a failed cleanup
# leaks one process.
CLEANUP_TIMEOUT_SECONDS = 10.0
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
# PIDs this holder directly spawned, recorded at spawn time. Containment
# signals ONLY these roots and their current descendants. A session daemon
# (dbus-daemon, gnome-keyring-daemon) that reparented onto this subreaper is
# never a spawned root, is never a descendant of one, and is deliberately
# never signalled: killing it takes the session keyring and with it the
# fleet's GitHub credentials (#2387).
_spawned_roots: set[int] = set()


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


def scan_locks_manifest(manifest_path: str) -> int:
    try:
        request = json.loads(read_bounded_regular_bytes(manifest_path, SCAN_MANIFEST_LIMIT))
        gate_dir = request["gate_dir"]
        lock_dir = request["lock_dir"]
        capacity = request["capacity"]
        if not isinstance(gate_dir, str) or not isinstance(lock_dir, str):
            return 125
        if not isinstance(capacity, int) or isinstance(capacity, bool) or capacity < 0:
            return 125
    except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError, OSError):
        return 125

    scan = {"active": 0, "queued": 0, "scanned": 0, "details": [], "issues": []}
    budget_reasons = set()
    metadata_bytes = 0

    def add_issue(reason: str, path: str, detail=None) -> None:
        if len(scan["issues"]) >= SCAN_ISSUE_LIMIT:
            budget_reasons.add("issue_budget")
            return
        issue = {"reason": reason, "path": path}
        if detail is not None:
            issue["detail"] = detail
        scan["issues"].append(issue)

    def inspect_candidate(kind: str, slot, lock_path: str, metadata_path: str) -> bool:
        nonlocal metadata_bytes
        if scan["scanned"] >= SCAN_CANDIDATE_LIMIT:
            budget_reasons.add("candidate_budget")
            return False

        scan["scanned"] += 1
        result = probe_lock(lock_path, metadata_path)
        state = result.get("state")

        if state == "locked":
            if kind == "slot":
                scan["active"] += 1
            elif kind == "queue":
                scan["queued"] += 1

            encoded = result.get("contents")
            encoded_bytes = len(encoded) if isinstance(encoded, str) else 0
            if len(scan["details"]) >= SCAN_DETAIL_LIMIT:
                budget_reasons.add("holder_detail_budget")
            elif metadata_bytes + encoded_bytes > SCAN_METADATA_BUDGET:
                budget_reasons.add("metadata_budget")
            else:
                metadata_bytes += encoded_bytes
                scan["details"].append(
                    {
                        "kind": kind,
                        "slot": slot,
                        "lock_path": lock_path,
                        "metadata_path": metadata_path,
                        "result": result,
                    }
                )
        elif state == "error":
            add_issue("lock_probe_failed", lock_path, result)

        return True

    for slot in range(1, capacity + 1):
        if not inspect_candidate(
            "slot",
            slot,
            os.path.join(lock_dir, f"slot-{slot}.lock"),
            os.path.join(gate_dir, f"slot-{slot}.owner"),
        ):
            break

    queue_dir = os.path.join(gate_dir, "queue")
    try:
        with os.scandir(queue_dir) as entries:
            for entry in entries:
                if entry.name.startswith("lease-v2-"):
                    path = os.path.join(queue_dir, entry.name)
                    if not inspect_candidate("queue", None, path, path):
                        break
    except FileNotFoundError:
        pass
    except OSError as error:
        add_issue("queue_unreadable", queue_dir, str(error.errno))

    phase_lock = os.path.join(lock_dir, "phase-start.lock")
    phase_metadata = os.path.join(gate_dir, "phase-start.owner")
    if os.path.exists(phase_lock) or os.path.exists(phase_metadata):
        inspect_candidate("phase", None, phase_lock, phase_metadata)

    for reason in sorted(budget_reasons):
        add_issue("scan_budget_exceeded", gate_dir, reason)

    scan["degraded"] = bool(scan["issues"])
    print(json.dumps(scan, separators=(",", ":")))
    return 0


def probe_lock(lock_path: str, cleanup_path: str) -> dict:
    descriptor = None
    try:
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        descriptor = os.open(lock_path, flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return {"state": "error", "reason": "not_regular", "type": file_type(metadata.st_mode)}

        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result = {"state": "locked"}
            try:
                contents = read_regular_bytes(cleanup_path)
                result["contents"] = base64.b64encode(contents).decode("ascii")
            except FileNotFoundError:
                pass
            except OSError as error:
                result["metadata_error"] = "not_regular" if error.errno in (errno.ELOOP, errno.EINVAL) else str(error.errno)
            return result

        try:
            os.unlink(cleanup_path)
        except FileNotFoundError:
            pass
        return {"state": "unlocked"}
    except FileNotFoundError:
        return {"state": "error", "reason": "missing"}
    except OSError as error:
        reason = "not_regular" if error.errno in (errno.ELOOP, errno.EINVAL, errno.ENXIO) else str(error.errno)
        return {"state": "error", "reason": reason, "type": "other"}
    finally:
        if descriptor is not None:
            os.close(descriptor)


def file_type(mode: int) -> str:
    if stat.S_ISFIFO(mode):
        return "other"
    if stat.S_ISDIR(mode):
        return "directory"
    return "other"


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


def read_bounded_regular_bytes(path: str, limit: int) -> str:
    descriptor = open_regular(path, os.O_RDONLY)
    try:
        contents = os.read(descriptor, limit + 1)
        if len(contents) > limit:
            raise OSError(errno.EFBIG, "bounded input is too large")
        return contents.decode("utf-8")
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


def terminate_process_tree(root_pid: int, deadline: float | None = None) -> None:
    if deadline is None:
        deadline = time.monotonic() + CLEANUP_TIMEOUT_SECONDS

    signal_tree(signal.SIGTERM)
    grace_deadline = min(time.monotonic() + TERM_GRACE_SECONDS, deadline)

    while process_tree_alive(root_pid) and time.monotonic() < grace_deadline:
        reap_exited_children()
        time.sleep(POLL_SECONDS)

    if process_tree_alive(root_pid):
        signal_tree(signal.SIGKILL)

    # Bounded (#2381). A descendant that survives SIGKILL — uninterruptible in
    # the kernel, or one this holder may not signal — used to spin here
    # forever while the flock stayed held.
    while process_tree_alive(root_pid) and time.monotonic() < deadline:
        reap_exited_children()
        time.sleep(POLL_SECONDS)

    reap_exited_children()


def signal_tree(signal_number: int) -> None:
    # Containment signals ONLY what this holder directly spawned and their
    # descendants. The old code also swept every child of this subreaper
    # (`proc_children(os.getpid())`), which is where an adopted session daemon
    # lands when its original parent exits — sweeping it and `killpg`-ing its
    # session took down the GNOME keyring and broke `gh` auth for the whole
    # fleet (#2387).
    pids = owned_process_ids()

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


def record_spawned_root(pid: int) -> None:
    """Track a process the holder directly spawned (#2387)."""
    if pid > 0:
        _spawned_roots.add(pid)


def owned_process_ids() -> set[int]:
    """PIDs this holder may signal: directly-spawned roots plus their descendants.

    Roots are recorded explicitly at spawn time. A session daemon
    (dbus-daemon, gnome-keyring-daemon) that reparented onto this subreaper is
    not a spawned root and is not a descendant of one, so it is never in this
    set and never signalled.
    """
    pids: set[int] = set()

    for root in _spawned_roots:
        pids.add(root)
        pids.update(descendants_of(root))

    return pids


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
    if pid_alive(root_pid, unsignalable_is_alive=False):
        return True

    # Only what the holder directly spawned counts as "the tree". An adopted
    # session daemon is never owned, so it must not keep the bounded cleanup
    # loops spinning either (#2387).
    return any(
        pid_alive(pid, unsignalable_is_alive=False)
        for pid in owned_process_ids()
    )


def pid_alive(pid: int, unsignalable_is_alive: bool = True) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # A process this holder may not signal is one it can never kill or
        # reap. Callers waiting for descendants to die must treat it as gone —
        # counting it as live is how the cleanup loop wedged while holding the
        # flock (#2381). Callers watching the wrapper's own liveness stay
        # conservative: there, the safe answer is "still there".
        return unsignalable_is_alive


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


def subtree_cpu_ns() -> int | None:
    """Total CPU nanoseconds consumed by the holder's live descendants.

    `None` means a live descendant tree exists but none of its processes could
    be read (measurement unavailable), so the caller keeps the slot
    conservatively instead of guessing. `0` means the tree is empty.
    """
    pids = descendants_of(os.getpid())

    if not pids:
        return 0

    total = 0
    measured = 0

    for pid in pids:
        value = proc_cpu_ns(pid)

        if value is not None:
            total += value
            measured += 1

    if measured == 0:
        return None

    return total


def proc_cpu_ns(pid: int) -> int | None:
    """CPU nanoseconds consumed by one process, via the scheduler runtime.

    `/proc/<pid>/schedstat`'s first field (`sum_exec_runtime`) is the
    high-resolution CPU time in nanoseconds and is world-readable. When
    schedstat is unavailable (`CONFIG_SCHEDSTATS=n`) this returns `None` — the
    caller's conservative "measurement unavailable" hold — rather than falling
    back to `/proc/<pid>/stat` utime+stime ticks. That fallback resolves to
    10ms granularity (`SC_CLK_TCK` is 100) against a 3ms idle threshold, so a
    genuinely compiling child in the 3-10ms/window band reads as a delta of
    exactly 0 and the slot would be released out from under it (#2386). A host
    without schedstat cannot run the CPU gate; the safe answer there is to
    keep the slot to the retain deadline, not to guess from a coarse number.
    """
    # Test-only injection point: redirects the schedstat read to a path that
    # does not exist so the unavailable path is exercised deterministically
    # and the "no coarse fallback" property is pinned by the suite. An empty
    # value means "read the real /proc path".
    schedstat_path = os.environ.get("AIUR_BUILD_GATE_HOLDER_SCHEDSTAT_PATH", "")

    if schedstat_path == "":
        schedstat_path = f"/proc/{pid}/schedstat"

    try:
        with open(schedstat_path, encoding="utf-8") as file:
            parts = file.read().split()
            if parts:
                return int(parts[0])
    except (FileNotFoundError, ProcessLookupError, OSError, ValueError):
        pass

    return None


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


def retain_seconds() -> int:
    value = os.environ.get("AIUR_BUILD_GATE_RETAIN_SECONDS", "")

    try:
        retain = int(value)
    except ValueError:
        return DEFAULT_RETAIN_SECONDS

    return max(0, retain)


def retain_deadline(hold_deadline: float | None) -> float:
    """When the post-command courtesy retain ends.

    The absolute cap still applies, but it is an hour by default and a slot
    unavailable for an hour is indistinguishable from a lost slot. The retain
    window is the tighter of the two (#2381).
    """
    retain_until = time.monotonic() + retain_seconds()

    if hold_deadline is None:
        return retain_until

    return min(retain_until, hold_deadline)


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

    if len(sys.argv) == 3 and sys.argv[1] == "--scan-locks-manifest":
        sys.exit(scan_locks_manifest(sys.argv[2]))

    sys.exit(main())
