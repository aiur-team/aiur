"""Stream a bounded prefix of one Git tree without buffering all output."""

from __future__ import annotations

import os
import selectors
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

from validation_common import Report, git_no_replace_env


READ_CHUNK_BYTES = 64 * 1024
MAX_TREE_ENTRY_BYTES = 64 * 1024
MAX_STDERR_BYTES = 64 * 1024


def bounded_tree_records(
    root: Path,
    commit: str,
    prefix: str,
    maximum: int,
    timeout_seconds: int,
    report: Report,
) -> list[bytes] | None:
    """Return at most ``maximum`` NUL-delimited ls-tree records."""
    records: list[bytes] = []
    buffered = bytearray()
    chunks = _tree_chunks(root, commit, prefix, timeout_seconds, report)
    try:
        for chunk in chunks:
            buffered.extend(chunk)
            while b"\0" in buffered:
                raw, _, remainder = buffered.partition(b"\0")
                buffered = bytearray(remainder)
                if len(raw) > MAX_TREE_ENTRY_BYTES:
                    report.error("receipt planning pack contains an oversized tree entry")
                    return None
                if len(records) >= maximum:
                    report.error("receipt planning pack exceeds file-count bound")
                    return records
                records.append(bytes(raw))
            if len(buffered) > MAX_TREE_ENTRY_BYTES:
                report.error("receipt planning pack contains an oversized tree entry")
                return None
    finally:
        close = getattr(chunks, "close", None)
        if close is not None:
            close()
    if buffered:
        report.error("receipt planning pack contains a malformed tree entry")
        return None
    return records


def _tree_chunks(
    root: Path,
    commit: str,
    prefix: str,
    timeout_seconds: int,
    report: Report,
) -> Iterator[bytes]:
    command = ["git", "-C", str(root), "ls-tree", "-r", "-z", commit, "--", prefix]
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    stderr = bytearray()
    deadline = time.monotonic() + timeout_seconds
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=git_no_replace_env(),
        )
        assert process.stdout is not None and process.stderr is not None
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout_seconds)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(command, timeout_seconds)
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), READ_CHUNK_BYTES)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.data == "stdout":
                    yield chunk
                elif len(stderr) < MAX_STDERR_BYTES:
                    stderr.extend(chunk[: MAX_STDERR_BYTES - len(stderr)])
        remaining = max(0.0, deadline - time.monotonic())
        if process.wait(timeout=remaining):
            report.error("receipt commit or planning pack cannot be read")
    except (OSError, subprocess.TimeoutExpired) as exc:
        report.error(f"receipt planning pack tree read failed: {exc}")
    finally:
        selector.close()
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        if process is not None:
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
