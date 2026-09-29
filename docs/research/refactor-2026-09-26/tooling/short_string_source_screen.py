#!/usr/bin/env python3
"""Reproduce a conservative source-role screen of the 709 short string groups.

This is navigation evidence, not semantic clearance. It preserves every source
candidate and keeps domain vocabulary open for caller tracing.
"""

import collections
import hashlib
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
INPUT = ROOT / "review/in-progress/inline-literal-lowfanout-ledger.json"
SNAPSHOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(
    "/home/everdred/.aiur/research/refactor-2026-09-26/scratch/snapshot-3339b887-complete"
)

EXISTING = {
    "ticket.": "dup-by-body-46; dup-by-concept-02",
    "ticket:": "dup-by-body-42",
    "run_id": "dup-by-name-04",
    "0.0.0.0": "dup-by-constant-05",
    "todo": "dup-by-concept-01",
    "rework": "dup-by-concept-01",
    "paused": "dup-by-concept-01",
    "merging": "dup-by-concept-01",
}
TOPIC = {"system.", "phase.", "phase:", "pr:", "agent.", "agent:", "ticket:", "model:"}
STRUCTURED = {"run_id", "wake_id", "boot_id", "turn_id", "msg_id", "call_id", "node_id", "os_pid", "api_key", "age_ms", "etag", "sha", "slug"}
STATUS = {"open", "opened", "closed", "done", "pending", "queued", "active", "failed", "success", "unknown", "stale", "ready", "blocked", "partial", "expired", "working", "running", "hold", "held", "fresh", "error", "todo", "rework", "merging", "paused", "OPEN", "CLOSED", "Closed"}
PROTOCOL = {"0.0.0.0", "RS256", "JWT", "HEAD", "HOME", "PATH", "TMPDIR", "Accept", "Bearer ", "http://", "https", "origin/", "Etc/UTC", "-KILL", "-TERM", "-echo", "-icanon", "--json", "--quiet", "--jq", "set -eu"}


def shape(value):
    if value in EXISTING:
        return "crosslinked_existing"
    if not value.strip() or all(not char.isalnum() for char in value):
        return "syntax_or_visual_symbol"
    if value in TOPIC or value.endswith(".") and value[:-1] in {"ticket", "system", "phase", "agent"}:
        return "topic_fragment_open"
    if value in STRUCTURED:
        return "identity_or_schema_field_open"
    if value in STATUS:
        return "status_vocabulary_open"
    if value in PROTOCOL or value.startswith(("/", ".", "--")) or re.fullmatch(r"-[A-Za-z0-9]", value):
        return "external_protocol_or_path_token"
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", value):
        return "field_or_vocabulary_open"
    if len(value) < 8 and (value.startswith(" ") or value.endswith((" ", "=", ":"))):
        return "display_or_log_fragment"
    return "mixed_fragment_open"


def main():
    data = json.loads(INPUT.read_text())
    rows = [row for row in data["rows"] if row[0] == "s" and len(row[2]) < 8]
    assert len(rows) == 709
    if data["snapshot"] != "3339b887196d5e9aefb273117a14bf33391ee41f":
        raise SystemExit("unexpected source snapshot")
    counts = collections.Counter()
    reviewed = []
    for row in rows:
        value = row[2]
        category = shape(value)
        anchors = []
        for file_id, line in row[7]:
            path = data["files"][file_id]
            source = (SNAPSHOT / path).read_text(errors="replace").splitlines()
            assert 0 < line <= len(source), (value, path, line)
            # Only the first two module-distinct locations are given by the
            # candidate ledger. Do not imply that this traces every consumer.
            anchors.append([file_id, line])
        counts[category] += 1
        reviewed.append([value, row[3], row[4], category, anchors, EXISTING.get(value)])
    result = {
        "status": "source-role-screen; semantic candidates remain open",
        "snapshot": data["snapshot"],
        "input_sha256": hashlib.sha256(INPUT.read_bytes()).hexdigest(),
        "input_relative_path": str(INPUT.relative_to(ROOT)),
        "anchor_file_table": "input.files",
        "row_schema": ["value", "module_count", "site_count", "source_role_screen", "first_two_distinct_module_file_id_line_anchors", "existing_raw_crosslink_or_null"],
        "short_string_groups": len(reviewed),
        "source_role_counts": dict(sorted(counts.items())),
        "limits": ["Source role uses lexical value and frozen source anchors; it is not a shared-policy verdict.", "Only the first two distinct-module anchors are held in the compact input; all sites remain in the private full census.", "Open groups require caller/owner tracing before promotion or dismissal."],
        "rows": reviewed,
    }
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
