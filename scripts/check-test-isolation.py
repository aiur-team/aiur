#!/usr/bin/env python3
"""Ratcheting checks for recurring test-isolation hazards.

After a test-file split or rename lands on main, refresh the per-file baseline
with ``python3 scripts/check-test-isolation.py --write-baseline``. Review the
old and new file counts first: moved findings are existing debt, while findings
added by new test logic are not. The writer rejects count growth in existing
files and records the moved counts under their current paths.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
TEST_ROOT = ROOT / "src/test"
BASELINE = ROOT / "scripts/test-isolation-baseline.json"
RULES = {
    "sleep": re.compile(r"\bProcess\.sleep\s*\("),
    "empty_capture": re.compile(r"\b(?:capture_log|ExUnit\.CaptureLog\.capture_log)\s*\([^\n]*\)\s*(?:==|===|!=|!==)\s*\"\""),
    "global_pubsub": re.compile(r"\b(?:Phoenix\.)?PubSub\.subscribe\([^\n]*,\s*\"[^\"]+\""),
    "unowned_start": re.compile(r"\b(?:spawn|Task\.start)\s*\("),
}


def counts(path):
    text = path.read_text(encoding="utf-8")
    result = {name: [] for name in RULES}
    lines = text.splitlines()
    # Strip line comments so examples and explanations do not enter the ratchet.
    for index, line in enumerate(lines):
        lines[index] = re.sub(r"(?<!\\)#.*$", "", line)
    clean = "\n".join(lines)
    module_ranges = []
    cases = list(re.finditer(r"(?m)^\s*use\s+[\w.]*Case\b[^\n]*", clean))
    for index, match in enumerate(cases):
        async_match = re.search(r"async:\s*(true|false)", match.group(0))
        end = cases[index + 1].start() if index + 1 < len(cases) else len(clean)
        module_ranges.append((match.start(), end, bool(async_match and async_match.group(1) == "true")))
    for name, pattern in RULES.items():
        for match in pattern.finditer(clean):
            line_no = clean.count("\n", 0, match.start()) + 1
            line = lines[line_no - 1]
            if name == "unowned_start" and re.search(r"\b(?:start_supervised!?|Isolation\.start_owned!)\s*\(", line):
                continue
            if name == "unowned_start" and re.search(r"\b(?:spawn|Task\.start)\s*\([^\n]*\bowner:\s*", line):
                continue
            result[name].append(line_no)
    for match in re.finditer(r"\b(?:Application\.put_env|System\.put_env)\s*\(", clean):
        module = next((async_flag for start, end, async_flag in module_ranges if start <= match.start() < end), False)
        if module:
            result.setdefault("async_global_env", []).append(clean.count("\n", 0, match.start()) + 1)
    return {name: len(lines) for name, lines in result.items()}


def scan():
    return {path.relative_to(ROOT).as_posix(): counts(path) for path in sorted(TEST_ROOT.rglob("*_test.exs"))}


def compact(current):
    return {
        file: {rule: count for rule, count in rules.items() if count}
        for file, rules in current.items()
        if any(rules.values())
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    current = scan()
    if args.write_baseline:
        if BASELINE.exists():
            previous = json.loads(BASELINE.read_text())
            for file, rules in previous.items():
                for rule, count in rules.items():
                    if current.get(file, {}).get(rule, 0) > count:
                        print(f"{file}: {rule} count would rise from {count} to {current[file][rule]}; baseline not updated", file=sys.stderr)
                        return 1
        BASELINE.write_text(json.dumps(compact(current), separators=(",", ":"), sort_keys=True) + "\n")
        return 0
    baseline = json.loads(BASELINE.read_text())
    failures = []
    for file, rules in current.items():
        for rule, locations in rules.items():
            allowed = baseline.get(file, {}).get(rule, 0)
            if locations > allowed:
                failures.append(f"{file}: {rule} count {locations} exceeds baseline {allowed}")
    for line in failures:
        print(line, file=sys.stderr)
    if failures:
        return 1
    print(f"check-test-isolation: OK ({len(current)} test files; baseline {BASELINE.relative_to(ROOT)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
