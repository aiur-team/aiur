#!/usr/bin/env python3
"""Automatically add timeouts to bare assert_receive/refute_receive calls.

This script adds:
- 1000ms timeout to assert_receive calls (allows for handshake overhead)
- 0ms timeout to refute_receive calls (immediate check, no delay)

Run this to fix all bare calls, then run tests to verify behavior.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEST_DIR = REPO_ROOT / "src/test"


def fix_file(path: Path) -> int:
    """Fix bare assert_receive/refute_receive in a single file.

    Returns number of fixes made.
    """
    content = path.read_text(encoding="utf-8")
    original = content
    lines = content.split("\n")
    result_lines = []

    i = 0
    while i < len(lines):
        line = lines[i]

        # Check if line has assert_receive or refute_receive
        if "assert_receive" in line or "refute_receive" in line:
            # Check if this line ends a call (ends with } and no timeout)
            if line.rstrip().endswith("}"):
                # Check if there's already a timeout argument
                if not re.search(r',\s*\d+\s*$', line):
                    # Determine which function and what timeout
                    if "assert_receive" in line:
                        # Add 1000ms timeout
                        line = line.rstrip() + ", 1000"
                    elif "refute_receive" in line:
                        # Add 0ms timeout
                        line = line.rstrip() + ", 0"

        result_lines.append(line)
        i += 1

    new_content = "\n".join(result_lines)

    if new_content != original:
        path.write_text(new_content, encoding="utf-8")
        return 1

    return 0


def main() -> int:
    if not TEST_DIR.exists():
        print(f"fix-bare-assert-receive: test directory not found: {TEST_DIR}", file=sys.stderr)
        return 1

    test_files = sorted(TEST_DIR.glob("**/*_test.exs"))

    total_fixes = 0
    for test_file in test_files:
        if fix_file(test_file):
            print(f"Fixed: {test_file.relative_to(REPO_ROOT)}")
            total_fixes += 1

    print(f"\nFixed {total_fixes} test files")
    print("Note: Run tests to verify the timeouts are appropriate")
    print("Adjust timeouts in specific tests if 1000ms is too tight or too loose")
    return 0


if __name__ == "__main__":
    sys.exit(main())
