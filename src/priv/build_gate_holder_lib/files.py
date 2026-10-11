"""Lock scan, bounded regular-file IO, hold deadlines and lease metadata for the build-gate lease holder."""

import base64
import errno
import fcntl
import json
import os
import stat
import sys
import time


SCAN_CANDIDATE_LIMIT = 512
SCAN_DETAIL_LIMIT = 64
SCAN_ISSUE_LIMIT = 32
SCAN_METADATA_BUDGET = 64 * 1024
SCAN_MANIFEST_LIMIT = 16 * 1024
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


def cleanup_paths(*paths: str) -> None:
    for path in paths:
        remove_if_present(path)


def remove_if_present(path: str) -> None:
    try:
        os.unlink(path)
    except (FileNotFoundError, IsADirectoryError):
        pass
