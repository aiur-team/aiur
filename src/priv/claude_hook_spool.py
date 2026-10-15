#!/usr/bin/env python3
"""Persist Claude's hook payload before forwarding the same JSON to curl."""

import fcntl
import json
import os
import sys
import tempfile
import uuid

MAX_BYTES = 16 * 1024 * 1024
EVENT_FIELDS = {
    "hook_event_name", "session_id", "cwd", "prompt", "last_assistant_message",
    "tool_name", "transcript_path", "timestamp", "transcript_offset",
}


def append(path, payload, reset=False, clear=False):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if clear:
            if os.path.exists(path):
                os.unlink(path)
            return
        size = os.path.getsize(path) if os.path.exists(path) else 0
        if reset or size + len(payload) > MAX_BYTES:
            if not reset:
                print("Claude hook spool rotated at 16 MiB; oldest events discarded", file=sys.stderr)
            # A new inode lets replay reset its byte cursor after bounded rotation.
            fd, replacement = tempfile.mkstemp(dir=os.path.dirname(path))
            try:
                with os.fdopen(fd, "wb") as spool:
                    spool.write(payload)
                    spool.flush()
                    os.fsync(spool.fileno())
                os.replace(replacement, path)
            finally:
                if os.path.exists(replacement):
                    os.unlink(replacement)
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "ab") as spool:
                spool.write(payload)
                spool.flush()
                os.fsync(spool.fileno())


def main():
    if len(sys.argv) == 3 and sys.argv[1] in {"--reset", "--clear"}:
        append(sys.argv[2], b"", reset=True, clear=sys.argv[1] == "--clear")
        return

    event = {key: value for key, value in json.load(sys.stdin).items() if key in EVENT_FIELDS}
    event["aiur_hook_id"] = uuid.uuid4().hex
    payload = (json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
    try:
        if len(payload) > MAX_BYTES:
            raise ValueError("Claude hook exceeds spool capacity")
        append(sys.argv[1], payload)
    except (OSError, ValueError):
        # Without durable replay, use the legacy direct-POST delivery path.
        del event["aiur_hook_id"]
        payload = (json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        print("Claude hook spool unavailable; forwarding live event", file=sys.stderr)
    sys.stdout.buffer.write(payload)


if __name__ == "__main__":
    main()
