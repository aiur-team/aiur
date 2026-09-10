#!/usr/bin/env python3
"""Fail when the two coverage-shard implementations can disagree.

The shard of a test file is computed twice in this repository:

  * `src/lib/aiur/test_shard.ex` - decides what each CI coverage job runs.
  * `scripts/rename_preflight.py` - reports the CI shard for every rename hit.

A preflight that names a different shard than CI actually uses is worse than no
preflight, so both suites assert the same golden table of path -> shard. This
guard checks that the two tables are in fact the same table, which the suites
themselves cannot see: each only knows its own copy.

It also recomputes the table from the documented rule -- SHA-256 of the
src/-relative path, first eight bytes big-endian, modulo the shard count -- so a
matching pair of *wrong* tables is caught too.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

SHARDS = 4
ROOT = Path(__file__).resolve().parent.parent
ELIXIR_TEST = ROOT / "src/test/aiur/test_shard_test.exs"
PYTHON_TEST = ROOT / "scripts/test_rename_preflight.py"

ELIXIR_ENTRY = re.compile(r'"(test/[^"]+)"\s*=>\s*(\d+)')
PYTHON_ENTRY = re.compile(r'"(test/[^"]+)":\s*(\d+)')


def golden(path: Path, pattern: re.Pattern[str], marker: str) -> dict[str, int]:
    text = path.read_text()
    start = text.index(marker)
    end = text.index("}", start)
    return {name: int(shard) for name, shard in pattern.findall(text[start:end])}


def expected(name: str) -> int:
    return int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "big") % SHARDS + 1


def main() -> int:
    elixir = golden(ELIXIR_TEST, ELIXIR_ENTRY, "@golden %{")
    python = golden(PYTHON_TEST, PYTHON_ENTRY, "GOLDEN = {")
    problems: list[str] = []

    if not elixir:
        problems.append(f"{ELIXIR_TEST}: no @golden entries found")
    if not python:
        problems.append(f"{PYTHON_TEST}: no GOLDEN entries found")

    if elixir != python:
        problems.append(
            "the golden shard tables disagree:\n"
            f"  {ELIXIR_TEST.relative_to(ROOT)}: {elixir}\n"
            f"  {PYTHON_TEST.relative_to(ROOT)}: {python}"
        )

    for name, shard in sorted({**python, **elixir}.items()):
        if shard != expected(name):
            problems.append(f"{name}: table says shard {shard}, documented rule says {expected(name)}")

    if problems:
        for problem in problems:
            print(f"check-test-shard-parity: {problem}", file=sys.stderr)
        return 1

    print(f"check-test-shard-parity: {len(elixir)} golden shard assignments agree across both implementations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
