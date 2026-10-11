"""Process tree containment, reaping and CPU accounting for the build-gate lease holder."""

import os
import signal
import time


POLL_SECONDS = 0.01
TERM_GRACE_SECONDS = 1.0
# Absolute bound on any descendant-cleanup loop (#2381). Cleanup is best
# effort: a descendant that will not die must never keep the holder spinning,
# because a wedged slot starves every queued build while a failed cleanup
# leaks one process.
CLEANUP_TIMEOUT_SECONDS = 10.0
# PIDs this holder directly spawned, recorded at spawn time. Containment
# signals ONLY these roots and their current descendants. A session daemon
# (dbus-daemon, gnome-keyring-daemon) that reparented onto this subreaper is
# never a spawned root, is never a descendant of one, and is deliberately
# never signalled: killing it takes the session keyring and with it the
# fleet's GitHub credentials (#2387).
_spawned_roots: set[int] = set()


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
