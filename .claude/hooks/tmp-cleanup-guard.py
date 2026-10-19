#!/usr/bin/env python3
"""Refuse shell commands that sweep /tmp or delete live X11 socket paths."""

from __future__ import annotations

import json
import re
import sys


PROTECTED_PATH = re.compile(r"(?:/tmp/\.(?:X11-unix|ICE-unix)(?:/|\b)|/tmp/\.X[^/\s'\"]*-lock(?:$|[/\s'\"])|/tmp\b.*['\"]\.X(?:11-unix|ICE-unix|[^'\"]*-lock)['\"])")
TMP_GLOB = re.compile(r"/tmp/(?:\*|\.[^/\s'\"]*\*)|/tmp\b.*['\"]\.\*['\"]")
DELETE_COMMAND = re.compile(r"\b(?:rm|find)\b")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    command = payload.get("tool_input", {}).get("command")
    if not isinstance(command, str):
        return 0

    if DELETE_COMMAND.search(command) and (PROTECTED_PATH.search(command) or TMP_GLOB.search(command)):
        print(
            "aiur: refusing deletion under /tmp X11 paths or a /tmp glob. "
            "Delete only exact paths you created; never sweep /tmp.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
