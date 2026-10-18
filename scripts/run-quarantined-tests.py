#!/usr/bin/env python3
"""Run only tests named by src/test/quarantine.txt; `--check` only validates the list."""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "src/test/quarantine.txt"
TESTS = ROOT / "src/test"

STRING = r'"((?:[^"\\]|\\.)*)"'
MODULE_PATTERN = re.compile(r"^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do\b")
DESCRIBE_PATTERN = re.compile(r"^\s*describe\s+" + STRING)
TEST_PATTERN = re.compile(r"^\s*test\s+" + STRING)


def entries(path=LIST):
    result = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not fields[0].startswith(("Aiur.", "AiurWeb.")) or not fields[1] or not re.fullmatch(r"#?[1-9][0-9]*", fields[2]):
            raise ValueError(f"invalid quarantine entry at {path}:{number}")
        result.append(tuple(fields))
    return result


def decode(literal):
    return bytes(literal, "utf-8").decode("unicode_escape")


def scan(tests_root=TESTS):
    """Yield (module, name, path, line) per literal test; name is ExUnit's, describe prefix included."""
    for path in sorted(tests_root.rglob("*_test.exs")):
        # Formatted code closes a block with `end` at the block's own indent.
        stack = []
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip())
            while stack and indent <= stack[-1][0]:
                stack.pop()
            module = next((name for _, kind, name in reversed(stack) if kind == "module"), None)
            if match := MODULE_PATTERN.match(line):
                stack.append((indent, "module", f"{module}.{match.group(1)}" if module else match.group(1)))
            elif match := DESCRIBE_PATTERN.match(line):
                stack.append((indent, "describe", decode(match.group(1))))
            elif (match := TEST_PATTERN.match(line)) and module:
                describe = next((name for _, kind, name in reversed(stack) if kind == "describe"), None)
                name = decode(match.group(1))
                yield module, f"{describe} {name}" if describe else name, path, line_number


def selectors(tests_root=TESTS, listed=None):
    """Resolve every entry to focused test locations; an entry that is not exactly one test fails."""
    listed = entries() if listed is None else listed
    tests = list(scan(tests_root))
    problems = []
    selected = set()
    for module, name, _ticket in listed:
        if name == "*":
            found = [(path, line) for test_module, _, path, line in tests if test_module == module]
            if not found:
                problems.append(f"{module} :: * matches no test")
        else:
            # The blocking run excludes by ExUnit test name alone, so the name must be unique suite-wide.
            named = [(test_module, path, line) for test_module, test_name, path, line in tests if test_name == name]
            found = [(path, line) for test_module, path, line in named if test_module == module]
            if len(found) != 1 or len(named) != 1:
                problems.append(f"{module} :: {name} matches {len(found)} test(s) in its module and {len(named)} suite-wide")
        selected.update(f"{path.relative_to(tests_root.parent).as_posix()}:{line}" for path, line in found)
    if problems:
        raise ValueError("each entry must name exactly one test by its full ExUnit name, describe prefix included: " + "; ".join(problems))
    return sorted(selected)


def main():
    try:
        selected = selectors()
    except (OSError, ValueError) as error:
        print(f"quarantine selection failed: {error}", file=sys.stderr)
        return 2
    if not selected:
        print("quarantine list selected no tests", file=sys.stderr)
        return 2
    if "--check" in sys.argv[1:]:
        print(f"quarantine list ok: {len(selected)} test location(s)")
        return 0
    print("Quarantined tests selected:")
    print("\n".join(f"- {item}" for item in selected))
    return subprocess.run(["mix", "test", *selected, "--max-cases", "4"], cwd=ROOT / "src", check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
