#!/usr/bin/env python3
"""Report rename hits that a joined-literal search would miss."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import re
import subprocess
from pathlib import Path


def git_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return sorted(path for path in result.stdout.decode().split("\0") if path)


def boundary(value: str) -> re.Pattern[str]:
    return re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(value) + r"(?![A-Za-z0-9_-])")


def shard_of(src_relative: str, total: int) -> int:
    """Mirror of `Aiur.TestShard.shard_of/2` (src/lib/aiur/test_shard.ex).

    The key is the src/-relative test path, hashed with SHA-256; the first 8
    bytes, big-endian, are taken modulo the shard count. Keep the two
    implementations byte-identical -- `scripts/check-test-shard-parity.py`
    fails CI when they disagree.
    """
    digest = hashlib.sha256(src_relative.encode()).digest()
    return int.from_bytes(digest[:8], "big") % total + 1


def partition_map(files: list[str], total: int) -> dict[str, int]:
    tests = sorted(path for path in files if path.startswith("src/test/") and fnmatch.fnmatch(path, "*_test.exs"))
    return {path: shard_of(path.removeprefix("src/"), total) for path in tests}


def partition_label(relative: str, partitions: dict[str, int]) -> str:
    if relative in partitions:
        return f"partition {partitions[relative]}"
    if relative.startswith("src/test/support/") or relative == "src/test/test_helper.exs":
        return "all test partitions"
    return "not a test partition"


def read_text(root: Path, relative: str) -> str | None:
    try:
        data = (root / relative).read_bytes()
    except OSError:
        return None
    if b"\0" in data:
        return None
    return data.decode("utf-8", errors="replace")


def scan_file(text: str, owner: str, name: str, slug: str) -> tuple[int, list[tuple[int, str]]]:
    owner_re = boundary(owner)
    name_re = boundary(name)
    separator_re = re.compile(re.escape(owner) + r"[-_]" + re.escape(name))
    interpolation_re = re.compile(
        r"#\{\s*(?:owner|org|organization)\s*\}\s*[/_-]\s*"
        r"#\{\s*(?:name|repo|repository|repo_name)\s*\}"
    )
    lines = text.splitlines()
    literal_count = sum(line.count(slug) for line in lines)
    hits: list[tuple[int, str]] = []

    for index, line in enumerate(lines):
        kinds = []
        if slug not in line:
            if separator_re.search(line):
                kinds.append("separator-variant")
            else:
                if owner_re.search(line):
                    kinds.append("owner-component")
                if name_re.search(line):
                    kinds.append("name-component")
            if interpolation_re.search(line):
                kinds.append("interpolation")
            if kinds:
                hits.append((index + 1, ", ".join(kinds)))

        if index + 1 >= len(lines):
            continue
        pair = line + "\n" + lines[index + 1]
        if slug not in pair and owner_re.search(line) and name_re.search(lines[index + 1]):
            hits.append((index + 1, "split-across-adjacent-lines"))

    return literal_count, hits


def parse_slug(value: str, option: str) -> tuple[str, str]:
    parts = value.split("/")
    if len(parts) != 2 or not all(parts):
        raise ValueError(f"{option} must be an owner/name pair")
    return parts[0], parts[1]


def run(root: Path, old: str, new: str, total: int) -> int:
    old_owner, old_name = parse_slug(old, "OLD")
    parse_slug(new, "NEW")
    if old == new:
        raise ValueError("OLD and NEW must differ")

    files = git_files(root)
    partitions = partition_map(files, total)
    literal_matches = 0
    hits: list[tuple[str, int, str]] = []

    for relative in files:
        text = read_text(root, relative)
        if text is None:
            continue
        count, file_hits = scan_file(text, old_owner, old_name, old)
        literal_matches += count
        hits.extend((relative, line, kind) for line, kind in file_hits)

    print(f"Rename preflight: {old} -> {new}")
    print(f"Repository root: {root}")
    print(f"Test partitions: {total} (src/test/**/*_test.exs, content-stable sha256(path) shards)")
    print(f"Literal joined-value matches: {literal_matches}")
    print(f"Potential literal-pass misses: {len(hits)}")
    if not hits:
        print("No component or near-miss hits require human judgement.")
        return 0

    print("\nHits (report-only; inspect before rewriting):")
    for relative, line, kind in hits:
        partition = partition_label(relative, partitions)
        print(f"{relative}:{line} [{partition}] {kind}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--old", required=True, help="old owner/name slug")
    parser.add_argument("--new", required=True, help="new owner/name slug")
    parser.add_argument("--partitions", type=int, default=4, help="Mix test partition count (default: 4)")
    args = parser.parse_args()
    if args.partitions < 1:
        parser.error("--partitions must be positive")
    try:
        return run(args.root.resolve(), args.old, args.new, args.partitions)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
