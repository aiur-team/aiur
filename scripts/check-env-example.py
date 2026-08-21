#!/usr/bin/env python3
"""Fail when `.env.example` disagrees with the env-var schema.

The env schema (`src/lib/aiur/env/schema.ex`) is the single source of truth for
every environment variable Aiur reads: name, type, requiredness, default,
secret-ness, and the one-line purpose/fetch text `.env.example` renders.
`.env.example` is generated from it and checked in, so the two cannot be allowed
to drift: a variable added to the schema but never regenerated into the example
silently disappears from operator onboarding, and a variable deleted from the
schema but still listed in the example misleads.

This is the mechanical half of the "generate .env.example from the schema"
requirement and mirrors `check-config-docs.py` for config keys: a fast,
Elixir-free gate that runs in the required lint job. It verifies, in both
directions, that the set of env-var names in `.env.example` equals the set the
schema declares for the example (every declaration that is not `example: false`
— launcher-managed and ambient variables are excluded), and that the section
headers match the schema's group headers. Full-content fidelity (purpose text,
fetch notes, alignment, defaults) is guaranteed by regenerating with
`mix aiur.env.example`; the drift gate catches any change that would let an
example diverge in the first place.

Usage: scripts/check-env-example.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA = REPO_ROOT / "src/lib/aiur/env/schema.ex"
EXAMPLE = REPO_ROOT / ".env.example"

# A declaration is a tuple literal: {"NAME", type: ..., ...}. The name is the
# only line-leading "UPPERCASE" string literal in the schema, so this match is
# unambiguous (see the note in the schema's @specs comment).
ENTRY_RE = re.compile(r'\{\s*"([A-Z][A-Z0-9_]*)",')
ENV_KEY_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=\s*\S?")
GROUP_HEADER_RE = re.compile(r"^## (.+)$", re.MULTILINE)
SCHEMA_GROUP_RE = re.compile(r"^\s*([a-z_]+):\s+\"([^\"]+)\"", re.MULTILINE)
GROUPS_BODY_RE = re.compile(r"def groups do\n(.*?)\n  end", re.DOTALL)


def die(message: str, code: int = 2) -> None:
    print(f"check-env-example: {message}", file=sys.stderr)
    sys.exit(code)


def parse_schema_entries(source: str) -> dict[str, bool]:
    """Map declared env-var name -> whether it should appear in .env.example.

    A declaration is included unless its spec carries `example: false`.
    """
    matches = list(ENTRY_RE.finditer(source))
    entries: dict[str, bool] = {}

    for index, match in enumerate(matches):
        name = match.group(1)
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        block = source[match.start() : end]
        entries[name] = "example: false" not in block

    return entries


def parse_example_keys(source: str) -> set[str]:
    """Env-var names assigned in `.env.example`, ignoring comment and blank lines."""
    keys = set()
    for line in source.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ENV_KEY_RE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def parse_example_headers(source: str) -> set[str]:
    return set(GROUP_HEADER_RE.findall(source))


def parse_schema_headers(source: str) -> set[str]:
    body = GROUPS_BODY_RE.search(source)
    if body is None:
        die("could not find `def groups do` in the env schema; the matcher is broken, not the schema")
    return set(match[1] for match in SCHEMA_GROUP_RE.findall(body.group(1)))


def main() -> int:
    if not SCHEMA.exists():
        die(f"expected path is missing: {SCHEMA}\ncheck-env-example: update this script if the layout moved.")
    if not EXAMPLE.exists():
        die(f"expected path is missing: {EXAMPLE}\ncheck-env-example: .env.example must exist and be checked in.")

    schema_source = SCHEMA.read_text(encoding="utf-8")
    example_source = EXAMPLE.read_text(encoding="utf-8")

    entries = parse_schema_entries(schema_source)
    if not entries:
        die("found no env-var declarations in the schema; that is a broken matcher, not an empty schema")

    example_keys = parse_example_keys(example_source)
    if not example_keys:
        die("found no env-var keys in .env.example; that is a broken matcher, not an empty example")

    declared = set(entries)
    expected = {name for name, include in entries.items() if include}

    problems: list[str] = []

    missing = sorted(expected - example_keys)
    if missing:
        problems.append(
            "env vars declared in the schema for .env.example but absent from it:\n"
            + "\n".join(f"  - {name}" for name in missing)
            + "\nRun `mix aiur.env.example` to regenerate and check in the result."
        )

    extra = sorted(example_keys - declared)
    if extra:
        problems.append(
            "env vars present in .env.example but not declared in the schema:\n"
            + "\n".join(f"  - {name}" for name in extra)
            + "\nRemove them, or declare them in src/lib/aiur/env/schema.ex."
        )

    # Variables the schema declares but intentionally hides from the example
    # (launcher-managed, ambient) must not leak into the checked-in file.
    hidden = sorted(example_keys - expected)
    if hidden:
        problems.append(
            "env vars marked `example: false` in the schema but present in .env.example:\n"
            + "\n".join(f"  - {name}" for name in hidden)
            + "\nRun `mix aiur.env.example` to regenerate."
        )

    example_headers = parse_example_headers(example_source)
    schema_headers = parse_schema_headers(schema_source)
    missing_headers = sorted(schema_headers - example_headers)
    extra_headers = sorted(example_headers - schema_headers)
    if missing_headers:
        problems.append(
            "section headers in the schema groups missing from .env.example:\n"
            + "\n".join(f"  - ## {header}" for header in missing_headers)
        )
    if extra_headers:
        problems.append(
            "section headers in .env.example not declared in the schema groups:\n"
            + "\n".join(f"  - ## {header}" for header in extra_headers)
        )

    if problems:
        print("check-env-example: .env.example drifts from the env schema:", file=sys.stderr)
        for problem in problems:
            print(f"\n{problem}", file=sys.stderr)
        print(
            "\n.env.example is generated from src/lib/aiur/env/schema.ex. Run\n"
            "`mix aiur.env.example` in src/ to regenerate it, check the diff, and\n"
            "commit the regenerated file.",
            file=sys.stderr,
        )
        return 1

    print(f"check-env-example: {len(expected)} declared env vars are documented in .env.example")
    return 0


if __name__ == "__main__":
    sys.exit(main())
