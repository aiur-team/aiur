"""Materialize an exact regular-file planning pack from one Git commit."""

from __future__ import annotations

import subprocess
from pathlib import Path, PurePosixPath

from validation_common import SHA, Report, git_no_replace_env


REGULAR_MODES = {b"100644", b"100755"}


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
    for path, executable in entries:
        raw = _git(
            source_root, "show", f"{receipt_commit}:{path}", capture_output=True,
        )
        if raw.returncode:
            report.error(f"receipt pack file is unreadable at {path}")
            continue
        target = destination.joinpath(*PurePosixPath(path).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw.stdout)
        if executable:
            target.chmod(0o755)
    return not report.errors


def _clone(source: Path, destination: Path, report: Report) -> bool:
    result = _git(
        source,
        "clone", "--quiet", "--shared", "--no-checkout", "--",
        str(source), str(destination),
        capture_output=True,
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
    result = _git(
        root, "ls-tree", "-r", "-z", commit, "--", prefix,
        capture_output=True,
    )
    if result.returncode:
        report.error("receipt commit or planning pack cannot be read")
        return None
    entries: list[tuple[str, bool]] = []
    seen: set[str] = set()
    for raw in (item for item in result.stdout.split(b"\0") if item):
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
        path = encoded_path.decode("utf-8")
    except UnicodeDecodeError:
        report.error("receipt planning pack paths must be UTF-8")
        return None
    if not _within_pack(path, prefix) or path.casefold() in seen:
        report.error(f"receipt planning pack path is unsafe or duplicated: {path}")
        return None
    seen.add(path.casefold())
    if len(fields) != 3 or fields[0] not in REGULAR_MODES or fields[1] != b"blob":
        report.error(f"receipt planning pack entry must be a regular file: {path}")
        return None
    return path, fields[0] == b"100755"


def _safe_pack_path(value: str, report: Report) -> str | None:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        report.error("receipt planning pack must be a safe repository-relative path")
        return None
    if not value or value == "." or any(part.casefold() == ".git" for part in path.parts):
        report.error("receipt planning pack path is not allowed")
        return None
    return value


def _within_pack(value: str, prefix: str) -> bool:
    path = PurePosixPath(value)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == value
        and tuple(path.parts[:len(PurePosixPath(prefix).parts)])
        == PurePosixPath(prefix).parts
        and all(part.casefold() != ".git" for part in path.parts)
    )


def _git(root: Path, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=False,
        env=git_no_replace_env(),
        **kwargs,
    )
