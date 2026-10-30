#!/usr/bin/env python3
"""Fail when a config key has no entry in the published configuration reference.

This is the mechanical half of the "docs ship with the change" rule in
AGENTS.md. It covers workflow and machine settings; CLI flags have a separate
checker, while dashboard pages and behavior changes remain review expectations.

The check resolves each key to its full dotted path by walking `embeds_one`
from `Aiur.Config.Schema` and `Aiur.Machine.Settings.Schema`, then requires
that exact path in the reference. Machine paths carry the `machine:` prefix.
Structured map fields listed in KNOWN_MAP_SUBKEYS expand into
canonical paths containing placeholders such as `<backend>`. Matching bare
field names would be worthless: `command`, `enabled`, and `model` each appear
in several sections, so any new field reusing one of those names would pass
without being documented.

A module that the root cannot reach is not config and is not checked. A key an
operator would never set goes in EXEMPT below, with a reason.

Usage: scripts/check-config-docs.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parent.parent


class Root(NamedTuple):
    root_file: Path
    module: str
    prefix: str = ""


ROOTS = [
    Root(REPO_ROOT / "src/lib/aiur/config/schema.ex", "Aiur.Config.Schema"),
    Root(REPO_ROOT / "src/lib/aiur/machine/settings/schema.ex", "Aiur.Machine.Settings.Schema", "machine:"),
]
REFERENCE_DIR = REPO_ROOT / "website/docs-app/reference"
# A key may be documented on any of these pages, exactly one of which is needed.
REFERENCES = [
    REFERENCE_DIR / "configuration.md",
    REFERENCE_DIR / "configuration-agent.md",
    REFERENCE_DIR / "configuration-build-order.md",
    REFERENCE_DIR / "configuration-voice.md",
    REFERENCE_DIR / "merge-policy.md",
]


# Dotted keys that are deliberately undocumented. Add a one-line reason with
# each entry; "it is new" is not a reason.
EXEMPT: dict[str, str] = {}

# Plain `:map` fields do not expose their inner shape to the Ecto schema. Keep
# the operator-facing maps with named sub-keys explicit here; maps keyed by
# operator-chosen values with scalar leaves need no expansion. The backend
# inventory mirrors OpenAICompat.Config's known keys plus direct consumers in
# CodingAgent, Init.AgentCLI, and BalanceBaseline.
KNOWN_MAP_SUBKEYS: dict[str, tuple[str, ...]] = {
    "agent.backend_configs": (
        "<backend>.enabled",
        "<backend>.command",
        "<backend>.model",
        "<backend>.model_discovery",
        "<backend>.default_model",
        "<backend>.base_url",
        "<backend>.api_key_env",
        "<backend>.management_api_key_env",
        "<backend>.transport",
        "<backend>.balance_baseline",
        "<backend>.quirks.reasoning_content_replay",
        "<backend>.quirks.text_tool_fallback",
        "<backend>.quirks.openrouter_metadata",
        "<backend>.quirks.local_concurrency_limit",
        "openrouter.provider.order",
        "openrouter.provider.ignore",
        "openrouter.provider.allow_fallbacks",
        "openrouter.provider.sort",
    ),
}

DEFMODULE_RE = re.compile(r"^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do", re.MULTILINE)
FIELD_RE = re.compile(r"^\s*field\(\s*:([a-zA-Z0-9_]+)", re.MULTILINE)
EMBEDS_RE = re.compile(r"^\s*embeds_(?:one|many)\(\s*:([a-zA-Z0-9_]+)\s*,\s*([A-Za-z0-9_.]+)", re.MULTILINE)
INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")


def die(message: str, code: int = 2) -> None:
    print(f"check-config-docs: {message}", file=sys.stderr)
    sys.exit(code)


def module_name(short: str, root: Root) -> str:
    """Resolve a module reference as written in an alias-using schema file."""
    if short.startswith("Aiur."):
        return short
    return f"{root.module}.{short}"


def load_modules(root: Root) -> dict[str, str]:
    """Map fully-qualified module name -> that module's source slice.

    A single file may define several schema modules (`agent.ex` defines the
    Agent section alongside Claude and Codex), so slice the file at each
    top-level `defmodule` rather than assuming one module per file.
    """
    root_schema = root.root_file
    schema_dir = root_schema.with_suffix("")
    paths = [root_schema, *sorted(schema_dir.glob("*.ex"))]
    modules: dict[str, str] = {}

    for path in paths:
        if not path.exists():
            die(f"expected path is missing: {path}\ncheck-config-docs: update this script if the layout moved.")
        source = path.read_text(encoding="utf-8")
        matches = list(DEFMODULE_RE.finditer(source))
        for index, match in enumerate(matches):
            end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
            modules[match.group(1)] = source[match.start() : end]

    return modules


def collect(modules: dict[str, str], module: str, prefix: str, seen: set[str], keys: dict[str, str], root: Root) -> None:
    """Walk embeds_one from `module`, recording every reachable dotted key."""
    if module in seen:
        return
    seen.add(module)

    source = modules.get(module)
    if source is None:
        # An embedded module defined outside the schema directory (for example a
        # custom Ecto type used as a section). Nothing to enumerate.
        return

    for field in FIELD_RE.findall(source):
        key = f"{prefix}{field}"
        keys[key] = module
        for subkey in KNOWN_MAP_SUBKEYS.get(key, ()):
            keys[f"{key}.{subkey}"] = f"{module} (known map shape)"

    for section, short in EMBEDS_RE.findall(source):
        collect(modules, module_name(short, root), f"{prefix}{section}.", seen, keys, root)


def main() -> int:
    for page in REFERENCES:
        if not page.exists():
            die(f"expected path is missing: {page}\ncheck-config-docs: update this script if the layout moved.")

    keys: dict[str, str] = {}
    for root in ROOTS:
        modules = load_modules(root)
        if root.module not in modules:
            die(f"could not find {root.module} in {root.root_file}; the matcher is broken, not the schema")

        root_keys: dict[str, str] = {}
        collect(modules, root.module, root.prefix, set(), root_keys, root)
        if not root_keys:
            die(f"found no config keys in {root.root_file}; that is a broken matcher, not an empty schema")
        keys.update(root_keys)

    references = sorted(set(REFERENCES) | set(REFERENCE_DIR.glob("configuration-*.md")))
    reference = "\n".join(page.read_text(encoding="utf-8") for page in references)
    documented = set(INLINE_CODE_RE.findall(reference))
    missing = sorted(key for key in keys if key not in EXEMPT and key not in documented)

    if missing:
        print("check-config-docs: config keys with no entry in the configuration reference:", file=sys.stderr)
        for key in missing:
            print(f"  - {key}  ({keys[key]})", file=sys.stderr)
        print(
            "\nDocumentation ships in the same PR as the change (AGENTS.md, \"Docs ship\n"
            "with the change\"). Add a row for each key to\n"
            "the topic linked from website/docs-app/reference/configuration.md, giving the\n"
            "type, the default, and what an operator changes it for. Keep it to one\n"
            "line; a wrong entry is worse than a missing one.\n\n"
            "If a key is genuinely internal and no operator would ever set it, add it\n"
            "to EXEMPT in this script with a reason.",
            file=sys.stderr,
        )
        return 1

    print(f"check-config-docs: all {len(keys)} config keys are documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
