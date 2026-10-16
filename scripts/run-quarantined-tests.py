#!/usr/bin/env python3
"""Run only tests named by src/test/quarantine.txt."""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "src/test/quarantine.txt"
TESTS = ROOT / "src/test"


def entries():
    result = []
    for number, raw in enumerate(LIST.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not fields[0].startswith("Aiur.") or not fields[1] or not re.fullmatch(r"#?[1-9][0-9]*", fields[2]):
            raise ValueError(f"invalid quarantine entry at {LIST}:{number}")
        result.append(tuple(fields))
    return result


def selectors():
    wanted = {}
    for module, name, _ticket in entries():
        wanted.setdefault(module, set()).add(name)

    found = {module: [] for module in wanted}
    module_pattern = re.compile(r"^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do\b")
    test_pattern = re.compile(r'^\s*test\s+"((?:[^"\\]|\\.)*)"')
    for path in sorted(TESTS.rglob("*_test.exs")):
        current = None
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            module_match = module_pattern.match(line)
            if module_match and module_match.group(1) in wanted:
                current = module_match.group(1)
            if current not in wanted:
                continue
            test_match = test_pattern.match(line)
            if not test_match:
                continue
            name = bytes(test_match.group(1), "utf-8").decode("unicode_escape")
            if "*" in wanted[current] or name in wanted[current]:
                found[current].append((path.relative_to(ROOT / "src").as_posix(), line_number, name))

    missing = [f"{module} :: {name}" for module, names in wanted.items()
               for name in names if name != "*" and not any(test == name for _, _, test in found[module])]
    empty_modules = [module for module, tests in found.items() if not tests]
    if missing or empty_modules:
        raise ValueError(f"quarantine tests not found: {', '.join(missing + empty_modules)}")
    return sorted({f"{path}:{line}" for tests in found.values() for path, line, _ in tests})


def main():
    try:
        selected = selectors()
    except (OSError, ValueError) as error:
        print(f"quarantine selection failed: {error}", file=sys.stderr)
        return 2
    if not selected:
        print("quarantine list selected no tests", file=sys.stderr)
        return 2
    print("Quarantined tests selected:")
    print("\n".join(f"- {item}" for item in selected))
    return subprocess.run(["mix", "test", *selected, "--max-cases", "4"], cwd=ROOT / "src", check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
