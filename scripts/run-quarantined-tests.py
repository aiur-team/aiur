#!/usr/bin/env python3
"""Run only tests named by src/test/quarantine.txt; `--check` only validates the list."""

from pathlib import Path
import re
import subprocess
import sys
from datetime import date, timedelta


ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "src/test/quarantine.txt"
TESTS = ROOT / "src/test"

STRING = r'"((?:[^"\\]|\\.)*)"'
MODULE_PATTERN = re.compile(r"^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do\b")
DESCRIBE_PATTERN = re.compile(r"^\s*describe\s+" + STRING)
TEST_PATTERN = re.compile(r"^\s*test\s+" + STRING)


def entries(path=LIST, grandfathered=frozenset(), today=None):
    today = today or date.today()
    maximum = today + timedelta(days=14)
    result = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not fields[0].startswith(("Aiur.", "AiurWeb.")) or not fields[1] or not re.fullmatch(r"#?[1-9][0-9]*", fields[2]) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", fields[3]):
            raise ValueError(f"invalid quarantine entry at {path}:{number}")
        row = tuple(fields)
        expiry = date.fromisoformat(fields[3])
        if expiry > maximum and row not in grandfathered:
            raise ValueError(f"quarantine expiry exceeds 14 days at {path}:{number}")
        result.append(row)
    return result


def baseline_entries():
    merge_base = subprocess.run(["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT, capture_output=True, text=True, check=False)
    refs = ([merge_base.stdout.strip()] if merge_base.returncode == 0 else []) + ["origin/main", "HEAD^"]
    for ref in refs:
        result = subprocess.run(["git", "show", f"{ref}:src/test/quarantine.txt"], cwd=ROOT, capture_output=True, text=True, check=False)
        if result.returncode == 0:
            return frozenset(tuple(line.rstrip().split("\t")) for line in result.stdout.splitlines() if line and not line.startswith("#") and len(line.split("\t")) == 4)
    raise RuntimeError("cannot read base quarantine list to identify grandfathered expiries")


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
    listed = entries(grandfathered=baseline_entries()) if listed is None else listed
    tests = list(scan(tests_root))
    problems = []
    selected = set()
    for module, name, _ticket, _expires in listed:
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
        selected = selectors(listed=entries(grandfathered=baseline_entries()))
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
