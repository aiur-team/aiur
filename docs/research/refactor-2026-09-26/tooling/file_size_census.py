#!/usr/bin/env python3
"""Count physical lines in every tracked file of a frozen Git revision."""

import argparse
import json
import subprocess
from collections import Counter
from pathlib import Path


def tracked_paths(repository: Path, revision: str) -> list[str]:
    output = subprocess.check_output(
        ["git", "-C", str(repository), "ls-tree", "-r", "--name-only", "-z", revision]
    )
    return [path.decode("utf-8", "surrogateescape") for path in output.split(b"\0") if path]


def line_count(content: bytes) -> int:
    return content.count(b"\n") + int(bool(content) and not content.endswith(b"\n"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="Git revision whose tracked paths are counted")
    parser.add_argument("snapshot", type=Path, help="complete extraction of that revision")
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    args = parser.parse_args()

    rows = []
    missing = []
    binary = []
    symlinks = []
    for name in tracked_paths(args.repository, args.revision):
        path = args.snapshot / name
        if path.is_symlink():
            symlinks.append(name)
            continue
        if not path.exists() or not path.is_file():
            missing.append(name)
            continue
        content = path.read_bytes()
        if b"\0" in content:
            binary.append(name)
            continue
        rows.append({"path": name, "lines": line_count(content)})

    oversized = sorted((row for row in rows if row["lines"] > 500), key=lambda row: (-row["lines"], row["path"]))
    preferred = sum(row["lines"] > 200 for row in rows)
    areas = Counter(row["path"].split("/", 1)[0] for row in oversized)
    report = {
        "revision": args.revision,
        "counting_rule": "bytes separated by LF; a nonempty unterminated final line counts as one; NUL-containing files are binary; symlinks are listed but targets are not double-counted",
        "tracked_paths": len(rows) + len(binary) + len(symlinks) + len(missing),
        "text_files": len(rows),
        "binary_files": len(binary),
        "symlinks": symlinks,
        "missing_paths": missing,
        "above_200": preferred,
        "above_500": len(oversized),
        "above_500_by_top_level": dict(sorted(areas.items())),
        "oversized": oversized,
    }
    print(json.dumps(report, indent=2))
    if missing:
        raise SystemExit(f"snapshot is missing {len(missing)} tracked paths")


if __name__ == "__main__":
    main()
