#!/usr/bin/env python3
"""Refuse agent commands that change the host's shared mise toolchain (#4692)."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


_spec = importlib.util.spec_from_file_location("issue_disposition", Path(__file__).with_name("issue-disposition.py"))
_shell = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shell)

# Every worker resolves Erlang/Elixir from the one host install, so a single
# agent's install/upgrade/prune can break the whole fleet.
MUTATING = {"install", "i", "upgrade", "up", "prune", "uninstall", "remove", "rm", "use", "u", "self-update"}
EXEC = {"exec", "x"}
VALUE_FLAGS = {"-C", "--cd", "-E", "--env", "-j", "--jobs"}


def mise_subcommand(arguments: list[str]) -> str | None:
    if not arguments or _shell.executable_name(arguments[0]) != "mise":
        return None

    index = 1
    while index < len(arguments):
        argument = arguments[index]
        if argument in VALUE_FLAGS:
            index += 2
        elif argument.startswith("-"):
            index += 1
        else:
            break
    if index >= len(arguments):
        return None

    subcommand = arguments[index]
    if subcommand in EXEC and "--" in arguments[index:]:
        nested = arguments[arguments.index("--", index) + 1 :]
        return mise_subcommand(_shell.executable_argv(nested))
    return subcommand if subcommand in MUTATING else None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0

    command = payload.get("tool_input", {}).get("command") if payload.get("tool_name") == "Bash" else None
    if not isinstance(command, str):
        return 0

    for segment in _shell.command_segments(command):
        if subcommand := mise_subcommand(_shell.executable_argv(segment)):
            print(
                f"aiur: refusing `mise {subcommand}` (#4692); the mise toolchain is shared by every worker on this host. "
                "Ask the Executor to change it.",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
