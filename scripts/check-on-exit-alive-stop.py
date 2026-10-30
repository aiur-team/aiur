#!/usr/bin/env python3
"""Reject alive?-then-stop cleanup inside test on_exit callbacks."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TEST_DIR = ROOT / "src/test"
ON_EXIT = re.compile(r"\bon_exit\s*\(")
ALIVE = re.compile(r"\b(?:Process\.alive\?|:erlang\.is_process_alive)\s*\(")
STOP = re.compile(r"\b(?:GenServer|Supervisor)\.stop\s*\(")
HELPER_STOP = re.compile(r"\b(?:safe_stop_genserver|safe_stop_supervisor|safe_stop|stop_store)\s*\(")


def call_end(source: str, opening: int) -> int:
    depth = 1
    quote = None
    escaped = False
    for index in range(opening + 1, len(source)):
        char = source[index]
        if escaped:
            escaped = False
            continue
        if quote and char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char == "#":
            newline = source.find("\n", index)
            if newline < 0:
                return len(source)
            continue
        if char in ('"', "'"):
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(source)


def violations(source: str) -> list[tuple[int, str]]:
    found = []
    for callback in ON_EXIT.finditer(source):
        opening = source.find("(", callback.start())
        end = call_end(source, opening)
        body = source[opening + 1 : end - 1]
        # Explicitly unlinked probes are outside the linked-process race.
        unlinked = set(re.findall(r"Process\.unlink\s*\(\s*(\w+)\s*\)", source))
        for stop in list(STOP.finditer(body)) + list(HELPER_STOP.finditer(body)):
            prefix = body[: stop.start()]
            guard_prefix = r"if\s+(?:is_pid\([^)]*\)\s+and\s+)?(?:Process\.alive\?|:erlang\.is_process_alive)\([^)]*\)"
            guard_sep = r"\s*(?:,\s*do:\s*|\s+do\b)\s*"
            alive_guard = re.search(guard_prefix + guard_sep + r"[\s\S]{0,240}?(?:GenServer|Supervisor)\.stop\s*\(", body)
            helper_guard = re.search(
                guard_prefix + guard_sep + r"[\s\S]{0,240}?(?:safe_stop_genserver|safe_stop_supervisor|safe_stop|stop_store)\s*\(",
                body,
            )
            guarded_stop = bool(alive_guard and not any(re.search(rf"\b{re.escape(pid)}\b", body[stop.start():stop.end() + 30]) for pid in unlinked))
            if guarded_stop or helper_guard:
                line = source.count("\n", 0, callback.start()) + 1
                found.append((line, source.splitlines()[line - 1].strip()))
                break
    return found


def main() -> int:
    test_dirs = [Path(arg).resolve() for arg in sys.argv[1:]] or [DEFAULT_TEST_DIR]
    files = sorted(path for directory in test_dirs for ext in ("*.ex", "*.exs") for path in directory.rglob(ext))
    if not files:
        print("check-on-exit-alive-stop: no test files found", file=sys.stderr)
        return 1
    issues = []
    for path in files:
        source = path.read_text(encoding="utf-8")
        for line, text in violations(source):
            location = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
            issues.append((location, line, text))
    if issues:
        print("check-on-exit-alive-stop: replace linked-process teardown with start_supervised!/1:", file=sys.stderr)
        for path, line, text in issues:
            print(f"  {path}:{line}: {text}", file=sys.stderr)
        return 1
    print(f"check-on-exit-alive-stop: OK ({len(files)} test files; baseline 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
