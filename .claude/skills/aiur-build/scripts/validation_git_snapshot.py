"""Materialize an exact regular-file planning pack from one Git commit."""

from __future__ import annotations

import subprocess
from pathlib import Path, PurePosixPath

from validation_common import (
    SHA,
    Report,
    git_no_replace_env,
    repository_relative_path,
)


REGULAR_MODES = {b"100644", b"100755"}
MAX_PACK_FILES = 512
MAX_PACK_FILE_BYTES = 2 * 1024 * 1024
MAX_PACK_BYTES = 32 * 1024 * 1024
GIT_SNAPSHOT_TIMEOUT_SECONDS = 30


def materialize_receipt_pack(
    source_root: Path,
    receipt_commit: object,
    pack_path: str,
    destination: Path,
    report: Report,
) -> bool:
    if not isinstance(receipt_commit, str) or not SHA.fullmatch(receipt_commit):
        report.error("receipt_commit must be a 40-character Git SHA")
        return False
    if not _clone(source_root, destination, report):
        return False
    entries = _entries(source_root, receipt_commit, pack_path, report)
    if entries is None:
        return False
    total_bytes = 0
    for path, executable in entries:
        size = _blob_size(source_root, receipt_commit, path, report)
        if size is None:
            continue
        total_bytes += size
        if size > MAX_PACK_FILE_BYTES:
            report.error(f"receipt pack file exceeds byte bound: {path}")
            continue
        if total_bytes > MAX_PACK_BYTES:
            report.error("receipt planning pack exceeds aggregate byte bound")
            break
        target = destination.joinpath(*PurePosixPath(path).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not _write_blob(source_root, receipt_commit, path, target, report):
            continue
        if executable:
            target.chmod(0o755)
    return not report.errors


def _clone(source: Path, destination: Path, report: Report) -> bool:
    result = _git(
        source,
        "clone", "--quiet", "--shared", "--no-checkout", "--",
        str(source), str(destination),
        text=True,
    )
    if result.returncode:
        report.error("cannot create receipt validation snapshot")
        return False
    return True


def _entries(
    root: Path, commit: str, pack_path: str, report: Report,
) -> list[tuple[str, bool]] | None:
    prefix = _safe_pack_path(pack_path, report)
    if prefix is None:
        return None
    result = _git(root, "ls-tree", "-r", "-z", commit, "--", prefix)
    if result.returncode:
        report.error("receipt commit or planning pack cannot be read")
        return None
    entries: list[tuple[str, bool]] = []
    seen: set[str] = set()
    for raw in (item for item in result.stdout.split(b"\0") if item):
        if len(entries) >= MAX_PACK_FILES:
            report.error("receipt planning pack exceeds file-count bound")
            break
        parsed = _entry(raw, prefix, seen, report)
        if parsed is not None:
            entries.append(parsed)
    if not entries:
        report.error(f"receipt commit contains no planning pack at {prefix}")
    return entries


def _entry(
    raw: bytes, prefix: str, seen: set[str], report: Report,
) -> tuple[str, bool] | None:
    if b"\t" not in raw:
        report.error("receipt planning pack contains a malformed tree entry")
        return None
    metadata, encoded_path = raw.split(b"\t", 1)
    fields = metadata.split()
    try:
        raw_path = encoded_path.decode("utf-8")
    except UnicodeDecodeError:
        report.error("receipt planning pack paths must be UTF-8")
        return None
    path = repository_relative_path(
        raw_path, "receipt planning pack path", report,
    )
    prefix_parts = PurePosixPath(prefix).parts
    if (
        path is None
        or PurePosixPath(path).parts[:len(prefix_parts)] != prefix_parts
        or path.casefold() in seen
    ):
        report.error(f"receipt planning pack path is unsafe or duplicated: {raw_path}")
        return None
    seen.add(path.casefold())
    if len(fields) != 3 or fields[0] not in REGULAR_MODES or fields[1] != b"blob":
        report.error(f"receipt planning pack entry must be a regular file: {path}")
        return None
    return path, fields[0] == b"100755"


def _safe_pack_path(value: str, report: Report) -> str | None:
    return repository_relative_path(value, "receipt planning pack", report)


def _blob_size(
    root: Path, commit: str, path: str, report: Report,
) -> int | None:
    result = _git(root, "cat-file", "-s", f"{commit}:{path}", text=True)
    try:
        size = int(result.stdout.strip()) if result.returncode == 0 else -1
    except ValueError:
        size = -1
    if size < 0:
        report.error(f"receipt pack file size is unreadable at {path}")
        return None
    return size


def _write_blob(
    root: Path, commit: str, path: str, target: Path, report: Report,
) -> bool:
    try:
        with target.open("wb") as stream:
            result = subprocess.run(
                ["git", "-C", str(root), "show", f"{commit}:{path}"],
                check=False, stdout=stream, stderr=subprocess.PIPE,
                env=git_no_replace_env(), timeout=GIT_SNAPSHOT_TIMEOUT_SECONDS,
            )
    except (OSError, subprocess.TimeoutExpired) as exc:
        report.error(f"receipt pack file read failed at {path}: {exc}")
        return False
    if result.returncode:
        report.error(f"receipt pack file is unreadable at {path}")
        return False
    return True


def _git(
    root: Path, *arguments: str, text: bool = False,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *arguments], check=False,
            capture_output=True, text=text, env=git_no_replace_env(),
            timeout=GIT_SNAPSHOT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(
            ["git", *arguments], 124, "" if text else b"",
            str(exc) if text else str(exc).encode(),
        )
