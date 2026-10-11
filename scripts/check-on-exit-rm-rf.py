#!/usr/bin/env python3
"""Reject a bare File.rm_rf / File.rm_rf! inside an on_exit callback in the test tree.

A cleanup that removes a directory a live writer still follows fails with
"file already exists" (#4176). Use Aiur.TestCleanup.rm_rf!/1 instead.
Pass --fix to rewrite the call sites in place. A line that must keep the raw
call has a `# on-exit-rm-rf: allow <why>` comment on the line above.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TEST_DIR = REPO_ROOT / "src/test"
ON_EXIT = re.compile(r"\bon_exit\(")
BARE = re.compile(r"(?<![\w.])File\.rm_rf\b!?")
ALLOW = "on-exit-rm-rf: allow"
HELPER = "Aiur.TestCleanup.rm_rf!"


def call_end(source: str, start: int) -> int:
    """Index just past the paren that closes the call opened before `start`."""
    # ponytail: counts parens only; a lone paren in a string or comment inside
    # an on_exit would mis-size the span. Swap for a real tokenizer if that bites.
    depth = 1
    i = start
    while i < len(source) and depth:
        depth += {"(": 1, ")": -1}.get(source[i], 0)
        i += 1
    return i


def bare_calls(source: str) -> list[tuple[int, int]]:
    """Spans of every bare File.rm_rf / File.rm_rf! inside an on_exit(...) call."""
    spans = set()
    for match in ON_EXIT.finditer(source):
        end = call_end(source, match.end())
        for found in BARE.finditer(source, match.end(), end):
            # mix format moves a trailing comment to the line above the call.
            above = source.rfind("\n", 0, max(source.rfind("\n", 0, found.start()), 0)) + 1
            if ALLOW not in source[above : found.start()]:
                spans.add(found.span())
    return sorted(spans)


def main() -> int:
    args = [arg for arg in sys.argv[1:] if arg != "--fix"]
    fix = len(args) != len(sys.argv) - 1
    test_dirs = [Path(arg).resolve() for arg in args] or [DEFAULT_TEST_DIR]
    test_files = sorted(p for d in test_dirs for ext in ("*.exs", "*.ex") for p in d.rglob(ext))
    if not test_files:
        print("check-on-exit-rm-rf: no test files found", file=sys.stderr)
        return 1

    issues = []
    for test_file in test_files:
        source = test_file.read_text(encoding="utf-8")
        spans = bare_calls(source)
        if fix and spans:
            for start, end in reversed(spans):
                source = source[:start] + HELPER + source[end:]
            test_file.write_text(source, encoding="utf-8")
            continue
        lines = source.splitlines()
        for offset, _end in spans:
            line_no = source.count("\n", 0, offset) + 1
            path = test_file.relative_to(REPO_ROOT) if test_file.is_relative_to(REPO_ROOT) else test_file
            issues.append((path, line_no, lines[line_no - 1].strip()))

    if issues:
        print(f"check-on-exit-rm-rf: bare File.rm_rf in on_exit; use {HELPER}/1:", file=sys.stderr)
        for path, line_no, line in issues[:30]:
            print(f"  {path}:{line_no}: {line[:120]}", file=sys.stderr)
        if len(issues) > 30:
            print(f"  ... and {len(issues) - 30} more", file=sys.stderr)
        return 1

    print(f"check-on-exit-rm-rf: OK ({len(test_files)} test files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
