#!/usr/bin/env python3
"""Reject assert_receive/refute_receive calls without explicit timeouts."""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TEST_DIR = REPO_ROOT / "src/test"
CALL = re.compile(r"\b(assert_receive|refute_receive)\b")


def scan_call(source: str, start: int) -> tuple[bool, int]:
    """Return (has_timeout, insertion_point) for a receive macro call."""
    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    quote: str | None = None
    escaped = False
    top_level_comma = False
    i = start
    while i < len(source) and source[i].isspace() and source[i] != "\n":
        i += 1
    parenthesized = i < len(source) and source[i] == "("
    if parenthesized:
        stack.append("(")
        i += 1
    base_depth = len(stack)
    while i < len(source):
        char = source[i]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            i += 1
            continue
        if char in ("\"", "'"):
            quote = char
        elif char == "#":
            newline = source.find("\n", i)
            if newline < 0:
                return top_level_comma, len(source)
            if len(stack) == base_depth and not parenthesized:
                return top_level_comma, i
            i = newline
        elif char in "([{":
            stack.append(char)
        elif char in ")]}":
            if stack and stack[-1] == pairs[char]:
                stack.pop()
                if parenthesized and not stack:
                    return top_level_comma, i
        elif char == "," and len(stack) == base_depth:
            top_level_comma = True
        elif char == "\n" and len(stack) == base_depth and not parenthesized:
            return top_level_comma, i
        i += 1
    return top_level_comma, i


def check_file(path: Path) -> list[tuple[int, str]]:
    source = path.read_text(encoding="utf-8")
    issues = []
    for match in CALL.finditer(source):
        has_timeout, _ = scan_call(source, match.end())
        if not has_timeout:
            line_no = source.count("\n", 0, match.start()) + 1
            line = source.splitlines()[line_no - 1].rstrip()
            issues.append((line_no, line))
    return issues


def main() -> int:
    test_dirs = [Path(arg).resolve() for arg in sys.argv[1:]] or [DEFAULT_TEST_DIR]
    test_files = sorted(path for directory in test_dirs for path in directory.rglob("*_test.exs"))
    if not test_files:
        print("check-bare-assert-receive: no test files found", file=sys.stderr)
        return 1

    issues = []
    for test_file in test_files:
        for line_no, line in check_file(test_file):
            try:
                display_path = test_file.relative_to(REPO_ROOT)
            except ValueError:
                display_path = test_file
            issues.append((display_path, line_no, line))

    if issues:
        print("check-bare-assert-receive: calls without explicit timeouts:", file=sys.stderr)
        for path, line_no, line in issues[:30]:
            print(f"  {path}:{line_no}: {line[:120]}", file=sys.stderr)
        if len(issues) > 30:
            print(f"  ... and {len(issues) - 30} more", file=sys.stderr)
        return 1

    print(f"check-bare-assert-receive: OK ({len(test_files)} test files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
