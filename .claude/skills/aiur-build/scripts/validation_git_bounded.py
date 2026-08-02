"""Run authority-bearing Git reads with hard time and output bounds."""

from __future__ import annotations

import os
import selectors
import subprocess
import time
from pathlib import Path

from validation_common import git_no_replace_env


READ_CHUNK_BYTES = 64 * 1024
GIT_TIMEOUT_RETURN_CODE = 124
GIT_OUTPUT_LIMIT_RETURN_CODE = 125
GIT_OS_ERROR_RETURN_CODE = 126


def run_bounded_git(
    root: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
    text: bool = False,
    timeout_seconds: int = 30,
    stdout_limit: int = 64 * 1024,
    stderr_limit: int = 64 * 1024,
) -> subprocess.CompletedProcess:
    """Capture a Git command without allowing unbounded pipes or runtime."""
    command = ["git", "-C", str(root), *arguments]
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    returncode = GIT_OS_ERROR_RETURN_CODE
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment or git_no_replace_env(),
        )
        assert process.stdout is not None and process.stderr is not None
        selector.register(
            process.stdout, selectors.EVENT_READ, (stdout, stdout_limit),
        )
        selector.register(
            process.stderr, selectors.EVENT_READ, (stderr, stderr_limit),
        )
        returncode = _read_pipes(
            process, selector, command, timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        returncode = GIT_TIMEOUT_RETURN_CODE
        stderr.extend(str(exc).encode()[:stderr_limit])
    except OSError as exc:
        returncode = GIT_OS_ERROR_RETURN_CODE
        stderr.extend(str(exc).encode()[:stderr_limit])
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
    raw_stdout: bytes | str = bytes(stdout)
    raw_stderr: bytes | str = bytes(stderr)
    if text:
        raw_stdout = raw_stdout.decode("utf-8", errors="replace")
        raw_stderr = raw_stderr.decode("utf-8", errors="replace")
    return subprocess.CompletedProcess(
        command, returncode, raw_stdout, raw_stderr,
    )


def _read_pipes(
    process: subprocess.Popen[bytes],
    selector: selectors.BaseSelector,
    command: list[str],
    timeout_seconds: int,
) -> int:
    deadline = time.monotonic() + timeout_seconds
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
                continue
            target, limit = key.data
            remaining_bytes = max(0, limit - len(target))
            target.extend(chunk[:remaining_bytes])
            if len(chunk) > remaining_bytes:
                return GIT_OUTPUT_LIMIT_RETURN_CODE
    remaining = max(0.0, deadline - time.monotonic())
    return process.wait(timeout=remaining)
