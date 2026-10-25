#!/usr/bin/env python3
"""Regenerate marked reference tables from metadata beside their definitions."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_KEYS = r"[a-zA-Z0-9_.<>-]+(?:, [a-zA-Z0-9_.<>-]+)*"
CONFIG_ROW = re.compile(rf"^\s*# @config-reference ([a-z][a-z0-9_-]+) ({CONFIG_KEYS}) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|\s*$")
CONFIG_KEY = re.compile(rf"^\s*# @config-reference ([a-z][a-z0-9_-]+) ({CONFIG_KEYS})\s*$")
CONFIG_DETAIL = re.compile(rf"^\s*# @config-detail ({CONFIG_KEYS}) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|\s*$")
MARKER = re.compile(r"<!-- generated-reference:([a-z][a-z0-9_-]*) -->")
TABLE_ROW = re.compile(r"^\|[^\n]*\|$", re.M)


def config_tables() -> dict[str, list[str]]:
    tables: dict[str, list[str]] = defaultdict(list)
    for path in sorted((ROOT / "src/lib/aiur/config").rglob("*.ex")):
        for table, rows in config_rows(path.read_text(encoding="utf-8"), path).items():
            tables[table].extend(rows)
    for table, rows in tables.items():
        keys = [row_identity(row) for row in rows]
        if len(keys) != len(set(keys)):
            raise SystemExit(f"duplicate @config-reference key in {table}")
    return {name: sorted(rows, key=lambda row: row_identity(row).casefold()) for name, rows in tables.items()}


def config_rows(source: str, path: Path | str = "schema") -> dict[str, list[str]]:
    tables: dict[str, list[str]] = defaultdict(list)
    pending: dict[str, str] = {}
    for line_number, line in enumerate(source.splitlines(), 1):
        if match := CONFIG_ROW.match(line):
            table, keys, kind, default, description = match.groups()
            tables[table].append(f"| {format_keys(keys)} | {kind} | {default} | {description} |")
        elif match := CONFIG_KEY.match(line):
            table, keys = match.groups()
            for key in split_keys(keys):
                if key in pending:
                    raise SystemExit(f"{path}:{line_number}: duplicate @config-reference for {key}")
                pending[key] = table
        elif match := CONFIG_DETAIL.match(line):
            keys, kind, default, description = match.groups()
            key_list = split_keys(keys)
            row_tables = {pending.pop(key, None) for key in key_list}
            if None in row_tables or len(row_tables) != 1:
                raise SystemExit(f"{path}:{line_number}: @config-detail {keys} has no matching @config-reference")
            table = row_tables.pop()
            tables[table].append(f"| {format_keys(keys)} | {kind} | {default} | {description} |")
    if pending:
        raise SystemExit(f"{path}: missing @config-detail for {', '.join(sorted(pending))}")
    return tables


def split_keys(keys: str) -> list[str]:
    return [key.strip() for key in keys.split(",")]


def format_keys(keys: str) -> str:
    return ", ".join(f"`{key}`" for key in split_keys(keys))


def cli_tables() -> dict[str, list[str]]:
    expression = (
        'Aiur.CLI.reference_options() |> Enum.map(fn o -> '
        '"| `" <> o.syntax <> "` | " <> o.description <> " | `" <> o.example <> "` |" end) '
        '|> Jason.encode!() |> IO.write()'
    )
    result = subprocess.run(
        ["mise", "exec", "--", "mix", "run", "--no-start", "-e", expression],
        cwd=ROOT / "src",
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise SystemExit("could not read CLI reference definitions:\n" + result.stderr)
    try:
        output = result.stdout.strip().splitlines()[-1]
        return {"cli-run-options": json.loads(output)}
    except json.JSONDecodeError as error:
        raise SystemExit(f"CLI reference API returned invalid JSON: {error}") from error


def rendered_tables() -> dict[str, list[str]]:
    result = config_tables()
    cli = cli_tables()
    overlap = result.keys() & cli.keys()
    if overlap:
        raise SystemExit(f"duplicate generated table ids: {sorted(overlap)}")
    result.update(cli)
    shell_annotations = read_shell_cli_annotations()
    for table, rows in shell_annotations.items():
        result[table].extend(rows)
        result[table].sort(key=lambda row: re.search(r"\| `([^`]+)` \|", row).group(1).casefold())
    return result


def read_shell_cli_annotations() -> dict[str, list[str]]:
    annotation = re.compile(r"^\s*# @cli-reference ([^|]+)\|([^|]+)\|([^\n]+)$", re.M)
    paths = [ROOT / "packaging/npm/aiur-cli/libexec/aiur-engine.sh", ROOT / "scripts/aiurdev"]
    tables: dict[str, list[str]] = defaultdict(list)
    for path in paths:
        for match in annotation.finditer(path.read_text(encoding="utf-8")):
            syntax, description, example = (value.strip() for value in match.groups())
            tables["cli-run-options"].append(f"| `{syntax}` | {description} | `{example}` |")
    return tables


def replace_tables(text: str, tables: dict[str, list[str]], page: str) -> tuple[str, set[str]]:
    seen: set[str] = set()
    replacements: list[tuple[int, int, str]] = []

    for match in MARKER.finditer(text):
        table_id = match.group(1)
        if table_id in seen:
            raise SystemExit(f"{page}: duplicate generated-reference marker {table_id}")
        seen.add(table_id)
        if table_id not in tables:
            raise SystemExit(f"{page}: generated-reference marker {table_id} has no schema or CLI annotations")
        header_end = text.find("\n", match.end())
        if header_end < 0:
            raise SystemExit(f"{page}: marker is not inside a table header")
        separator_start = header_end + 1
        separator_end = text.find("\n", separator_start)
        if separator_end < 0 or not text[separator_start:separator_end].lstrip().startswith("| ---"):
            raise SystemExit(f"{page}: generated table {table_id} has no markdown separator row")
        cursor = separator_end + 1
        while cursor < len(text) and text[cursor : cursor + 1] == "|":
            next_line = text.find("\n", cursor)
            cursor = len(text) if next_line < 0 else next_line + 1
        rows = tables[table_id]
        keys = [row_identity(row) for row in rows]
        if keys != sorted(keys, key=str.casefold) or len(keys) != len(set(keys)):
            raise SystemExit(f"{page}: generated table {table_id} has duplicate or unsorted rows")
        existing = [
            line
            for line in text[separator_end + 1 : cursor].splitlines()
            if line.startswith("|") and not line.lstrip().startswith("| ---")
        ]
        if existing == rows:
            continue
        replacement = text[match.start() : separator_end + 1] + "\n".join(rows) + ("\n" if rows else "")
        replacements.append((match.start(), cursor, replacement))

    updated = text
    for start, end, replacement in reversed(replacements):
        updated = updated[:start] + replacement + updated[end:]
    missing = set(tables) - seen
    if missing and page in {"website/docs-app/reference/configuration.md", "website/docs-app/reference/configuration-agent.md", "website/docs-app/reference/configuration-build-order.md", "website/docs-app/reference/configuration-voice.md", "website/docs-app/reference/merge-policy.md", "website/docs-app/reference/cli.md", "website/docs-app/reference/cli-options.md"}:
        # Each table has a single owning page; other pages intentionally have no marker.
        page_tables = {name for name in tables if name.startswith(page.rsplit("/", 1)[-1].replace(".md", "") + "-")}
        absent = page_tables - seen
        if absent:
            raise SystemExit(f"{page}: missing generated-reference markers: {sorted(absent)}")
    return updated, seen


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail instead of writing when generated tables drift")
    args = parser.parse_args()
    tables = rendered_tables()
    changed = []
    pages = [
        "website/docs-app/reference/configuration.md",
        "website/docs-app/reference/configuration-agent.md",
        "website/docs-app/reference/configuration-build-order.md",
        "website/docs-app/reference/configuration-voice.md",
        "website/docs-app/reference/merge-policy.md",
        "website/docs-app/reference/cli.md",
        "website/docs-app/reference/cli-options.md",
    ]
    originals = {relative: (ROOT / relative).read_text(encoding="utf-8") for relative in pages}
    page_prefixes = {
        "configuration.md": "config-configuration-",
        "configuration-agent.md": "config-configuration-agent-",
        "configuration-build-order.md": "config-configuration-build-order-",
        "configuration-voice.md": "config-configuration-voice-",
        "merge-policy.md": "config-merge-policy-",
    }
    for relative in pages:
        path = ROOT / relative
        original = originals[relative]
        prefix = page_prefixes.get(Path(relative).name)
        if prefix:
            page_tables = {table_id: rows for table_id, rows in tables.items() if table_id.startswith(prefix)}
        elif relative.endswith("cli.md"):
            page_tables = {}
        elif relative.endswith("cli-options.md"):
            page_tables = {"cli-run-options": tables["cli-run-options"]}
        updated, seen = replace_tables(original, page_tables, relative)
        if updated != original:
            changed.append(relative)
            if not args.check:
                path.write_text(updated, encoding="utf-8")
    if args.check and changed:
        print("reference table drift: " + ", ".join(changed), file=sys.stderr)
        return 1
    print("reference tables are current" if args.check else "regenerated reference tables")
    return 0


def row_identity(row: str) -> str:
    match = re.search(r"\| `([^`]+)`", row)
    if not match:
        raise SystemExit(f"generated reference row has no code-formatted key: {row}")
    return match.group(1)


if __name__ == "__main__":
    sys.exit(main())
