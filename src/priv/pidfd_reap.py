#!/usr/bin/env python3
"""Signal a verified provider without turning a recycled numeric PID into a target.

The caller supplies the process's procfs start-time and session captured when
the provider was registered.  This helper opens a pidfd before rechecking that
identity, then sends every signal through that pidfd.  Group and tree cleanup
first signals the verified root through its pidfd; the remaining members are
also bound to pidfds before they are signalled.
"""

import os
import select
import signal
import sys


def stat_fields(pid):
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as stat:
            tail = stat.read().rsplit(")", 1)[1].split()
        return {"ppid": int(tail[1]), "pgrp": int(tail[2]), "session": tail[3], "start": tail[19]}
    except (FileNotFoundError, IndexError, OSError, ValueError):
        return None


def identity_matches(pid, expected_start, expected_session):
    fields = stat_fields(pid)
    return fields is not None and fields["start"] == expected_start and fields["session"] == expected_session


def checked_pidfd(pid, expected_start=None, expected_session=None, group=None):
    try:
        fd = os.pidfd_open(pid, 0)
        fields = stat_fields(pid)

        if fields is None:
            os.close(fd)
            return None

        if expected_start is not None and (fields["start"], fields["session"]) != (expected_start, expected_session):
            os.close(fd)
            return None

        if group is not None and fields["pgrp"] != group:
            os.close(fd)
            return None

        signal.pidfd_send_signal(fd, 0)
        return fd
    except (AttributeError, OSError, ProcessLookupError):
        return None


def all_process_fields():
    entries = []
    try:
        names = os.listdir("/proc")
    except OSError:
        return entries

    for name in names:
        if name.isdigit():
            fields = stat_fields(int(name))
            if fields is not None:
                entries.append((int(name), fields))
    return entries


def group_members(group):
    return [pid for pid, fields in all_process_fields() if fields["pgrp"] == group]


def tree_members(root):
    children = {}
    for pid, fields in all_process_fields():
        children.setdefault(fields["ppid"], []).append(pid)

    pending = [root]
    members = []

    while pending:
        pid = pending.pop()
        members.append(pid)
        pending.extend(children.get(pid, []))

    return members


def signal_all(fds):
    active = []
    for fd in fds:
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
            active.append(fd)
        except (OSError, ProcessLookupError):
            pass

    if active:
        _, _, remaining = select.select([], [], active, 0)
        if not remaining:
            readable, _, _ = select.select(active, [], [], 5)
            active = [fd for fd in active if fd not in readable]

    for fd in active:
        try:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass


def reap(mode, root, expected_start, expected_session):
    root_fd = checked_pidfd(root, expected_start, expected_session)
    if root_fd is None:
        return False

    if mode == "group":
        members = group_members(root)
        fds = [checked_pidfd(pid, group=root) for pid in members if pid != root]
    elif mode == "tree":
        members = tree_members(root)
        fds = [checked_pidfd(pid) for pid in members if pid != root]
    else:
        fds = []

    fds = [fd for fd in fds if fd is not None]

    # The root's pidfd is the last ownership check before signalling. If it
    # exited meanwhile, do not target its former group or descendants.
    if not identity_matches(root, expected_start, expected_session):
        os.close(root_fd)
        for fd in fds:
            os.close(fd)
        return False

    try:
        signal.pidfd_send_signal(root_fd, 0)
        signal.pidfd_send_signal(root_fd, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        os.close(root_fd)
        for fd in fds:
            os.close(fd)
        return False

    signal_all([root_fd] + fds)

    for fd in [root_fd] + fds:
        os.close(fd)
    return True


def main():
    if len(sys.argv) != 5:
        return 2

    mode, root, expected_start, expected_session = sys.argv[1:]

    if mode not in ("group", "tree", "process"):
        return 2

    try:
        root = int(root)
    except ValueError:
        return 2

    return 0 if reap(mode, root, expected_start, expected_session) else 1


if __name__ == "__main__":
    raise SystemExit(main())
