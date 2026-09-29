#!/usr/bin/env python3
"""Summarize high-fanout inline literal candidates without semantic verdicts."""

import collections
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path


STATE_VALUES = {
    "assistant", "attention", "blocking", "canceled", "cancelled",
    "collapsed", "completed", "human-review", "interrupted", "operator",
    "progress", "resolved", "secondary", "supervisor", "unavailable",
    "unresolved", "unattributed",
}
HTTP_STATUS = {200, 299, 304, 401, 403, 404, 429}
TIME_CONVERSIONS = {1000, 3600, 60000, 86400}


def string_shape(value: str) -> str:
    if value.startswith(".") or value.startswith(("pr.", "issue.", "executor.", "turn/")):
        return "topic_or_event_fragment"
    if value in STATE_VALUES:
        return "state_or_display_enum"
    if value.startswith(("/", "https://", "refs/", "x-")) or value in {
        "application/json", "content-type", "github.com", "GITHUB_TOKEN"
    } or value.startswith("AIUR_"):
        return "protocol_path_header_or_env_name"
    if value != value.strip() or " " in value or value[:1].isupper():
        return "display_or_log_fragment"
    if re.fullmatch(r"[a-z][A-Za-z0-9_]*", value):
        return "field_or_identifier_token"
    return "other_literal_shape"


def number_shape(value: int | float) -> str:
    if value in HTTP_STATUS:
        return "http_status_candidate"
    if value in TIME_CONVERSIONS:
        return "time_unit_candidate"
    if value == 384:
        return "file_mode_candidate_0o600"
    if isinstance(value, int) and 2 <= value <= 16:
        return "small_ordinal_or_count"
    return "bound_duration_size_or_protocol_candidate"


def build(source: Path) -> dict:
    raw = gzip.open(source, "rb").read() if source.suffix == ".gz" else source.read_bytes()
    data = json.loads(raw)
    groups = collections.defaultdict(list)
    for row in data["literals"]:
        groups[(row["kind"], type(row["value"]), row["value"])].append(row)
    selected = []
    for (kind, _value_type, value), rows in groups.items():
        modules = {row["module"] for row in rows}
        if kind == "string":
            if len(modules) < 5 or len(value) < 8 or not value.strip() or not any(c.isalpha() for c in value):
                continue
            shape = string_shape(value)
        else:
            if len(modules) < 5 or value in (0, 1):
                continue
            shape = number_shape(value)
        examples = []
        seen = set()
        for row in rows:
            if row["module"] in seen:
                continue
            seen.add(row["module"])
            examples.append({"path": row["path"], "line": row["line"], "module": row["module"]})
            if len(examples) == 3:
                break
        selected.append({"kind": kind, "value": value, "modules": len(modules),
                         "sites": len(rows), "shape": shape, "examples": examples})
    selected.sort(key=lambda row: (row["kind"], -row["modules"], str(row["value"])))
    return {
        "status": "candidate-shape-index-only",
        "snapshot": "3339b887196d5e9aefb273117a14bf33391ee41f",
        "input_sha256": hashlib.sha256(raw).hexdigest(),
        "source_files": len(data["files"]),
        "literal_sites": len(data["literals"]),
        "selected_groups": len(selected),
        "selected_strings": sum(row["kind"] == "string" for row in selected),
        "selected_numbers": sum(row["kind"] == "number" for row in selected),
        "rows": selected,
        "limits": "All 1032 frozen src/lib Elixir files are parsed. Selection is static strings length >=8 in >=5 modules and non-0/1 numbers in >=5 modules. Shape labels are lexical routing only, not semantic ownership, units or duplication verdicts. Full lower-fanout and excluded literal population remains in the private input census.",
    }


if __name__ == "__main__":
    data = build(Path(sys.argv[1]))
    rows = data.pop("rows")
    print("{")
    items = list(data.items())
    for offset in range(0, len(items), 4):
        print("  " + ", ".join(
            f"{json.dumps(key)}: {json.dumps(value)}"
            for key, value in items[offset:offset + 4]
        ) + ",")
    print('  "rows": [')
    for index, row in enumerate(rows):
        suffix = "," if index < len(rows) - 1 else ""
        print("    " + json.dumps(row, separators=(",", ":")) + suffix)
    print("  ]\n}")
