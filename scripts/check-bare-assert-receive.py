#!/usr/bin/env python3
"""Check for bare assert_receive/refute_receive without explicit timeout.

ExUnit defaults to 100ms timeout for assert_receive, which is too tight for
tests that wait on handshakes with registry writes, state persists, telemetry
emits, and process spawns. All calls must have explicit timeouts.

Usage: scripts/check-bare-assert-receive.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEST_DIR = REPO_ROOT / "src/test"


def check_file(path: Path) -> list[tuple[int, str]]:
    """Check a test file for bare assert_receive/refute_receive.

    Returns list of (line_number, line_content) tuples.
    """
    issues = []
    content = path.read_text(encoding="utf-8")
    lines = content.split("\n")

    for line_no, line in enumerate(lines, 1):
        # Match bare calls ending with } without a timeout argument
        # Patterns:
        #   assert_receive {:msg}         <- BARE
        #   assert_receive {:msg}, 1000   <- OK
        #   refute_receive :msg}          <- BARE (malformed but we catch it)

        match = re.search(r'\b(assert_receive|refute_receive)\b.*\}\s*$', line)
        if match:
            # Check if there's a comma and timeout before the closing brace
            # Look for comma followed by number
            if not re.search(r',\s*\d+\s*$', line):
                issues.append((line_no, line.rstrip()))

    return issues


def main() -> int:
    if not TEST_DIR.exists():
        print(f"check-bare-assert-receive: test directory not found: {TEST_DIR}", file=sys.stderr)
        return 1

    test_files = sorted(TEST_DIR.glob("**/*_test.exs"))

    all_issues = []
    for test_file in test_files:
        issues = check_file(test_file)
        for line_no, line_content in issues:
            rel_path = test_file.relative_to(REPO_ROOT)
            all_issues.append((rel_path, line_no, line_content))

    if all_issues:
        print("check-bare-assert-receive: bare assert_receive/refute_receive found:", file=sys.stderr)
        print(file=sys.stderr)
        for path, line_no, line_content in all_issues[:30]:
            print(f"  {path}:{line_no}", file=sys.stderr)
            if len(line_content) > 80:
                line_content = line_content[:77] + "..."
            print(f"    {line_content}", file=sys.stderr)

        if len(all_issues) > 30:
            print(f"  ... and {len(all_issues) - 30} more", file=sys.stderr)

        print(file=sys.stderr)
        print(
            "assert_receive and refute_receive require explicit timeout.\n"
            "ExUnit's 100ms default is too tight for tests waiting on handshakes\n"
            "with registry writes, state persists, and process spawns.\n\n"
            "Fix:\n"
            "  assert_receive {:msg}, 1000\n"
            "  refute_receive {:msg}, 0\n\n"
            "See issue #2796.",
            file=sys.stderr,
        )
        return 1

    print(f"check-bare-assert-receive: OK ({len(test_files)} test files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
