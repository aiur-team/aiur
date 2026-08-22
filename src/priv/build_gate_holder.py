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
_cancel_signal = None


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

        result = wait_for_command(process, parent_pid_int)
        if result < 0:
            result = 128 - result

        retained = reap_exited_children()
        write_reserved_regular(status_path, f"{result} {int(retained)}\n")
        ack_deadline = time.monotonic() + max(1, int(ack_seconds))
        wait_for_status_ack(status_ack_path, token, parent_pid_int, ack_deadline)
        reap_remaining_children(agent_pgid_int)
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


def wait_for_command(process: subprocess.Popen, parent_pid: int) -> int:
    while True:
        result = process.poll()
        if result is not None:
            return result

        if _cancel_signal is not None or not pid_alive(parent_pid):
            terminate_process_tree(process.pid)
            result = process.poll()
            return 125 if result is None else result

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


def reap_remaining_children(agent_pgid: int) -> None:
    while True:
        raise_if_cancelled()

        if not process_group_alive(agent_pgid):
            raise InterruptedError("agent process group exited while descendants retained the lease")

        try:
            child_pid, _child_status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return

        if child_pid == 0:
            time.sleep(POLL_SECONDS)


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
