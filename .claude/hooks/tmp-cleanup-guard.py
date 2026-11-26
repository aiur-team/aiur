#!/usr/bin/env python3
"""Refuse shell commands that sweep /tmp or delete live X11 socket paths."""

from __future__ import annotations

import json
import re
import sys


PROTECTED_PATH = re.compile(r"(?:/tmp/\.(?:X11-unix|ICE-unix)(?:/|\b)|/tmp/\.X[^/\s'\"]*-lock(?:$|[/\s'\"])|/tmp\b.*['\"]\.X(?:11-unix|ICE-unix|[^'\"]*-lock)['\"])")
TMP_GLOB = re.compile(r"/tmp/(?:\*|\.[^/\s'\"]*\*)|/tmp\b.*['\"]\.\*['\"]")
DELETE_COMMAND = re.compile(r"\b(?:rm|find)\b")
TMP_FIND_ROOT = re.compile(r"\bfind\s+(?:--\s+)?/tmp(?:/\.)?/*(?:\s|$)")
FIND_DELETE = re.compile(r"(?:^|\s)-delete(?:\s|$)")
FIND_EXEC_RM = re.compile(r"(?:^|\s)-exec(?:dir)?(?:\s|$)[^;&|\n]*\brm\b")
TMPFILES_CLEANUP = re.compile(r"\bsystemd-tmpfiles\b[^;&|\n]*\s--(?:clean|remove)(?:\s|$)")
TMP_CLEANUP_TOOLS = re.compile(r"\b(?:tmpwatch|tmpreaper)\b")


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

    destructive_tmp_find = TMP_FIND_ROOT.search(command) and (
        FIND_DELETE.search(command) or FIND_EXEC_RM.search(command)
    )
    if TMPFILES_CLEANUP.search(command) or TMP_CLEANUP_TOOLS.search(command) or destructive_tmp_find or (
        DELETE_COMMAND.search(command) and (PROTECTED_PATH.search(command) or TMP_GLOB.search(command))
    ):
        print(
            "aiur: refusing a /tmp cleanup sweep or deletion under protected X11 paths. "
            "Delete only exact paths you created; never sweep /tmp.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
