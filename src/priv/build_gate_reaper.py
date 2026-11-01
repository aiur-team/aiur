#!/usr/bin/env python3
"""Remove abandoned build-gate publication files without touching live writers."""

import fcntl
import os
import re
import stat
import sys
import time


OWNER_PREFIX = ".owner-v2."
HANDSHAKE_PREFIXES = (
    ".command-ready-v2.",
    ".holder-started-v2.",
    ".holder-ready-v2.",
    ".command-v2.",
    ".status-v2.",
    ".status-ack-v2.",
)
GRACE_SECONDS = 300


def process_snapshot(gate_dir):
    """Return open file identities and process identities; fail closed on /proc errors."""
    open_files = set()
    namespaces = {}
    processes = {}
    active_paths = set()

    try:
        process_entries = list(os.scandir("/proc"))
    except OSError:
        return None

    for process in process_entries:
        if not process.name.isdecimal():
            continue
        pid = int(process.name)
        process_path = f"/proc/{pid}"
        try:
            process_stat = os.stat(process_path)
            if process_stat.st_uid != os.geteuid():
                continue
            namespace = os.readlink(f"{process_path}/ns/pid")
            with open(f"{process_path}/stat", encoding="ascii") as stat_file:
                stat = stat_file.read().rsplit(")", 1)[1].split()
            process_group = int(stat[2])
        except (OSError, ValueError, IndexError):
            # Processes exiting during the scan are harmless. If one remains,
            # do not reap against an incomplete process snapshot.
            if os.path.exists(process_path):
                return None
            continue

        namespaces.setdefault(namespace, set()).add(pid)
        processes[pid] = (namespace, process_group)
        try:
            with open(f"{process_path}/cmdline", "rb") as command_file:
                arguments = command_file.read().split(b"\0")
            for argument in arguments:
                candidate = os.fsdecode(argument)
                if os.path.dirname(candidate) == gate_dir and os.path.basename(candidate).startswith(
                    (OWNER_PREFIX,) + HANDSHAKE_PREFIXES
                ):
                    active_paths.add(candidate)
        except OSError:
            pass
        try:
            descriptors = os.scandir(f"{process_path}/fd")
        except OSError:
            if os.path.exists(process_path):
                return None
            continue
        with descriptors:
            for descriptor in descriptors:
                try:
                    opened = os.stat(descriptor.path)
                except OSError:
                    if os.path.exists(descriptor.path):
                        return None
                    continue
                open_files.add((opened.st_dev, opened.st_ino))

    return open_files, namespaces, processes, active_paths


def read_record(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as record_file:
            return dict(line.rstrip("\n").split("=", 1) for line in record_file if "=" in line)
    except OSError:
        return {}


def owner_is_live(record, namespaces, processes):
    namespace = record.get("command_pid_namespace", "")
    pids = {int(record.get(key, "0")) for key in ("pid", "holder_pid") if record.get(key, "0").isdecimal()}
    groups = {int(record.get(key, "0")) for key in ("pgid", "command_pgid") if record.get(key, "0").isdecimal()}
    pids.discard(0)
    groups.discard(0)

    if namespace:
        namespace_pids = namespaces.get(namespace, set())
        return bool(pids & namespace_pids) or any(processes[pid][1] in groups for pid in namespace_pids)
    return bool(pids & processes.keys()) or any(group == process_group for _, process_group in processes.values() for group in groups)


def active_acquisition_starts(entries, lock_dir):
    starts = []
    if not lock_dir:
        return starts

    for entry in entries:
        if not entry.name.startswith("slot-") or not entry.name.endswith(".owner"):
            continue
        match = re.fullmatch(r"slot-([1-9][0-9]*)\.owner", entry.name)
        if match is None:
            continue
        lock_path = os.path.join(lock_dir, f"slot-{match.group(1)}.lock")
        try:
            with open(lock_path, "rb") as lock_file:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock_file, fcntl.LOCK_UN)
        except BlockingIOError:
            pass
        except FileNotFoundError:
            continue
        except OSError:
            starts.append(0)
            continue
        else:
            continue
        record = read_record(entry.path)
        try:
            started_at = int(record.get("started_at", ""))
        except ValueError:
            continue
        starts.append(started_at)
    return starts


def candidate_is_dead(path, name, snapshot, now, active_starts):
    open_files, namespaces, processes, active_paths = snapshot
    if path in active_paths:
        return False
    try:
        file_stat = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    if not stat.S_ISREG(file_stat.st_mode) or (file_stat.st_dev, file_stat.st_ino) in open_files:
        return False
    if now - file_stat.st_mtime < GRACE_SECONDS:
        return False

    if name.startswith(OWNER_PREFIX):
        record = read_record(path)
        return not owner_is_live(record, namespaces, processes)

    # Handshake files contain protocol values, not reliable writer PIDs. The
    # age grace plus the open-descriptor check distinguishes a crash from the
    # live acquisition windows that create and then fill these files.
    return name.startswith(HANDSHAKE_PREFIXES) and not any(
        file_stat.st_mtime >= started_at for started_at in active_starts
    )


def reap(gate_dir, lock_dir):
    now = time.time()
    owners = 0
    handshakes = 0
    try:
        entries = list(os.scandir(gate_dir))
    except OSError:
        return 0, 0

    candidates = []
    for entry in entries:
        if not (entry.name.startswith(OWNER_PREFIX) or entry.name.startswith(HANDSHAKE_PREFIXES)):
            continue
        try:
            file_stat = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISREG(file_stat.st_mode) and now - file_stat.st_mtime >= GRACE_SECONDS:
            candidates.append(entry)
    if not candidates:
        return 0, 0

    snapshot = process_snapshot(gate_dir)
    if snapshot is None:
        return 0, 0
    active_starts = active_acquisition_starts(entries, lock_dir)

    for entry in candidates:
        if not candidate_is_dead(entry.path, entry.name, snapshot, now, active_starts):
            continue
        try:
            os.unlink(entry.path)
        except OSError:
            continue
        if entry.name.startswith(OWNER_PREFIX):
            owners += 1
        else:
            handshakes += 1
    return owners, handshakes


if __name__ == "__main__":
    owner_count, handshake_count = reap(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    if owner_count or handshake_count:
        print(f"aiur_build_gate orphan_files_reaped owners={owner_count} handshakes={handshake_count}", file=sys.stderr)
