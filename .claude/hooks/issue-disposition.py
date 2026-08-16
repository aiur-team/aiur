#!/usr/bin/env python3
"""Block GitHub issue creation that bypasses Aiur's disposition contract."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


SEPARATORS = {";", "&&", "||", "|", "&"}
SHELLS = {"bash", "dash", "sh", "zsh"}
HTTPIE_VALUE_OPTIONS = {
    "-a",
    "-A",
    "-o",
    "--auth",
    "--auth-type",
    "--cert",
    "--cert-key",
    "--format-options",
    "--history-print",
    "--output",
    "--pretty",
    "--print",
    "--proxy",
    "--session",
    "--session-read-only",
    "--style",
    "--timeout",
    "--verify",
}
GH_GUARD = Path(__file__).resolve().parents[2] / "src/priv/github_quota_guard.sh"
REST_ISSUES_URL = re.compile(
    r"https://api\.github\.com/repos/[^/\s]+/[^/\s]+/issues/?(?:[?\s'\"]|$)"
)
GRAPHQL_URL = re.compile(r"https://api\.github\.com/graphql(?:[?\s'\"]|$)")


def shell_tokens(command: str) -> list[str]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        # An incomplete shell command has not reached Bash yet. Treat it as
        # opaque instead of breaking every unrelated tool call.
        return []


def executable_name(token: str) -> str:
    return os.path.basename(token)


def split_segments(tokens: list[str]) -> list[list[str]]:
    segments: list[list[str]] = []
    current: list[str] = []

    for token in tokens:
        if token in SEPARATORS:
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)

    if current:
        segments.append(current)
    return segments


def executable_argv(segment: list[str]) -> list[str]:
    index = 0
    while index < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[index]):
        index += 1

    while index < len(segment) and segment[index] in {"command", "env", "exec"}:
        wrapper = segment[index]
        index += 1
        if wrapper == "command":
            while index < len(segment) and segment[index].startswith("-"):
                argument = segment[index]
                index += 1
                if "v" in argument.lower():
                    return []
                if argument == "--":
                    break
            continue

        if wrapper == "exec":
            while index < len(segment) and segment[index].startswith("-"):
                argument = segment[index]
                index += 1
                if argument in {"-a", "--argv0"}:
                    index += 1
                if argument == "--":
                    break
            continue

        while index < len(segment):
            argument = segment[index]
            if argument == "--":
                index += 1
                break
            if argument in {"-u", "--unset", "-C", "--chdir", "-a", "--argv0"}:
                index += 2
                continue
            if argument in {"-S", "--split-string"} and index + 1 < len(segment):
                segment = segment[:index] + shell_tokens(segment[index + 1]) + segment[index + 2 :]
                continue
            if argument.startswith("--split-string="):
                segment = segment[:index] + shell_tokens(argument.split("=", 1)[1]) + segment[index + 1 :]
                continue
            if argument.startswith("-S") and argument != "-S":
                segment = segment[:index] + shell_tokens(argument[2:]) + segment[index + 1 :]
                continue
            if argument.startswith(("--unset=", "--chdir=", "-u", "-C")):
                index += 1
                continue
            if argument.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argument):
                index += 1
                continue
            break

    return segment[index:]


def command_substitutions(command: str) -> list[str]:
    substitutions: list[str] = []
    index = 0
    quote: str | None = None

    while index < len(command):
        character = command[index]
        if character == "\\":
            index += 2
            continue
        if character in {"'", '"'}:
            quote = None if quote == character else character if quote is None else quote
            index += 1
            continue
        if quote == "'":
            index += 1
            continue

        opener_length = 0
        if command.startswith("$(", index) and not command.startswith("$((", index):
            opener_length = 2
        elif character in "<>" and command.startswith("(", index + 1):
            opener_length = 2

        if opener_length:
            start = index + opener_length
            depth = 1
            nested_quote: str | None = None
            cursor = start
            while cursor < len(command):
                nested = command[cursor]
                if nested == "\\":
                    cursor += 2
                    continue
                if nested in {"'", '"'}:
                    nested_quote = (
                        None if nested_quote == nested else nested if nested_quote is None else nested_quote
                    )
                elif nested_quote is None:
                    if nested == "(":
                        depth += 1
                    elif nested == ")":
                        depth -= 1
                        if depth == 0:
                            substitutions.append(command[start:cursor])
                            index = cursor + 1
                            break
                cursor += 1
            else:
                index += opener_length
            continue

        if character == "`":
            cursor = index + 1
            while cursor < len(command):
                if command[cursor] == "\\":
                    cursor += 2
                    continue
                if command[cursor] == "`":
                    substitutions.append(command[index + 1 : cursor])
                    index = cursor + 1
                    break
                cursor += 1
            else:
                index += 1
            continue

        index += 1

    return substitutions


def shell_command(segment: list[str]) -> str | None:
    arguments = executable_argv(segment)
    if not arguments or executable_name(arguments[0]) not in SHELLS:
        return None

    for index, argument in enumerate(arguments[1:], start=1):
        short_c_option = argument.startswith("-") and not argument.startswith("--") and "c" in argument[1:]
        if argument == "-c" or short_c_option:
            return arguments[index + 1] if index + 1 < len(arguments) else None
    return None


def command_segments(command: str, depth: int = 0) -> list[list[str]]:
    segments = split_segments(shell_tokens(command))
    if "\n" in command:
        for line in command.splitlines():
            segments.extend(split_segments(shell_tokens(line)))

    if depth >= 8:
        return segments

    nested_commands = command_substitutions(command)
    nested_commands.extend(filter(None, (shell_command(segment) for segment in segments)))
    for nested_command in nested_commands:
        segments.extend(command_segments(nested_command, depth + 1))
    return segments


def request_method(client: str, arguments: list[str]) -> str | None:
    prior = ""
    methods = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}

    if client in {"http", "https"}:
        url_index = next(
            (index for index, argument in enumerate(arguments) if argument.startswith(("http://", "https://"))),
            len(arguments),
        )
        positionals: list[str] = []
        index = 1
        while index < url_index:
            argument = arguments[index]
            if argument in HTTPIE_VALUE_OPTIONS:
                index += 2
            elif argument.startswith("-"):
                index += 1
            else:
                positionals.append(argument)
                index += 1
        for argument in reversed(positionals):
            if argument.upper() in methods:
                return argument.upper()

    for argument in arguments:
        upper = argument.upper()
        if upper in methods and (
            prior in {"-X", "--REQUEST", "--METHOD"}
        ):
            return upper
        for prefix in ("-X", "--REQUEST=", "--METHOD="):
            if upper.startswith(prefix) and len(upper) > len(prefix):
                return upper[len(prefix) :]
        prior = upper
    if any(argument in {"-G", "--get"} for argument in arguments):
        return "GET"
    return None


def has_request_body(client: str, arguments: list[str]) -> bool:
    method = request_method(client, arguments)
    if method is not None:
        return method == "POST"
    if client == "curl":
        return any(argument.startswith(("-d", "--data", "--json")) for argument in arguments)
    if client == "wget":
        return any(argument.startswith(("--post-data", "--post-file")) for argument in arguments)
    if client in {"http", "https"}:
        return any(
            not argument.startswith("-")
            and not argument.startswith(("http://", "https://"))
            and re.match(r"^[^:=@\s]+(?:=(?:$|[^=])|:=|@)", argument)
            for argument in arguments
        )
    return False


def gh_policy_error(segment: list[str]) -> str | None:
    arguments = executable_argv(segment)
    if not arguments or executable_name(arguments[0]) != "gh":
        return None

    result = subprocess.run(
        ["sh", str(GH_GUARD), "--validate-issue-command", *arguments[1:]],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return None
    return result.stderr.strip() or "aiur: GitHub issue command failed disposition validation (#1793)."


def direct_client_create(segment: list[str]) -> bool:
    arguments = executable_argv(segment)
    if not arguments:
        return False

    client = executable_name(arguments[0])
    if client not in {"curl", "http", "https", "wget"}:
        return False

    command = " ".join(arguments)
    rest_create = bool(REST_ISSUES_URL.search(command))
    graphql_create = bool(GRAPHQL_URL.search(command) and re.search(r"\bcreateIssue\s*\(", command))
    if not rest_create and not graphql_create:
        return False

    return has_request_body(client, arguments)


def deny(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


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

    segments = command_segments(command)
    for segment in segments:
        if error := gh_policy_error(segment):
            return deny(error)

    if any(direct_client_create(segment) for segment in segments):
        return deny(
            "aiur: refusing direct GitHub issue API creation (#1793); "
            "use `gh issue create --label ...` so the dispatch disposition is explicit and enforceable."
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
