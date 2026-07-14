#!/usr/bin/env python3
"""Own a Linux build slot until a Mix process tree exits."""

import ctypes
import os
import subprocess
import sys
import time


def main() -> int:
    (
        ready_path,
        started_path,
        command_pid_path,
        status_path,
        owner_path,
        token,
        parent_pid,
        lease_fd,
        *command,
    ) = sys.argv[1:]

    become_subreaper()
    touch_exclusive(started_path)
    wait_until_ready(ready_path, int(parent_pid))

    process = subprocess.Popen(command, close_fds=True, start_new_session=True)
    write_exclusive(command_pid_path, f"{process.pid}\n")
    detach_standard_streams(int(lease_fd))

    result = process.wait()
    if result < 0:
        result = 128 - result

    retained = reap_exited_children()
    write_atomic(status_path, f"{result} {int(retained)}\n")
    reap_remaining_children()
    remove_owned_metadata(owner_path, token)
    wait_for_status_ack(status_path)

    for path in (ready_path, started_path, command_pid_path, status_path):
        remove_if_present(path)

    return 0


def become_subreaper() -> None:
    libc = ctypes.CDLL(None, use_errno=True)

    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER) failed")


def touch_exclusive(path: str) -> None:
    with open(path, "x", encoding="utf-8"):
        pass


def write_exclusive(path: str, contents: str) -> None:
    with open(path, "x", encoding="utf-8") as file:
        file.write(contents)


def wait_until_ready(path: str, parent_pid: int) -> None:
    while not os.path.exists(path):
        try:
            os.kill(parent_pid, 0)
        except ProcessLookupError:
            raise SystemExit(125) from None

        time.sleep(0.01)


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
    while True:
        try:
            child_pid, _child_status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return False

        if child_pid == 0:
            return True


def write_atomic(path: str, contents: str) -> None:
    candidate = f"{path}.{os.getpid()}"
    write_exclusive(candidate, contents)
    os.replace(candidate, path)


def reap_remaining_children() -> None:
    while True:
        try:
            os.wait()
        except InterruptedError:
            continue
        except ChildProcessError:
            return


def remove_owned_metadata(path: str, token: str) -> None:
    try:
        with open(path, encoding="utf-8") as file:
            owns_metadata = f"token={token}\n" in file.read()
    except OSError:
        owns_metadata = False

    if owns_metadata:
        remove_if_present(path)


def wait_for_status_ack(path: str) -> None:
    for _ in range(100):
        if not os.path.exists(path):
            return

        time.sleep(0.01)


def remove_if_present(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    sys.exit(main())
