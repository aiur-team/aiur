#!/usr/bin/env python3
"""Close the static cross-module scalar screen by source role, without claiming caller equivalence."""

import json
import sys
from collections import Counter
from pathlib import Path


LONG_DECISIONS = {
    "field_identifier_or_version": "record_or_wire_field_requires_schema_owner",
    "display_log_sql_or_message_fragment": "message_fragment_requires_presentation_owner",
    "other_string_fragment": "protocol_or_mechanic_requires_caller_contract",
    "path_url_header_or_env": "path_header_env_requires_producer_consumer_contract",
    "topic_or_event_fragment": "topic_fragment_requires_typed_event_grammar",
    "nonsemantic_or_protocol_symbols": "external_syntax_not_standalone_policy",
}
SHORT_DECISIONS = {
    "field_or_vocabulary_open": "common_field_or_word_requires_schema_owner",
    "identity_or_schema_field_open": "identity_field_requires_typed_schema",
    "status_vocabulary_open": "status_word_requires_state_machine_owner",
    "topic_fragment_open": "topic_fragment_requires_typed_event_grammar",
    "mixed_fragment_open": "syntax_or_mechanic_requires_caller_contract",
}


def build(low_path: Path, short_path: Path) -> dict:
    low = json.loads(low_path.read_text())
    short = json.loads(short_path.read_text())
    assert low["snapshot"] == short["snapshot"]
    assert low["remaining_groups"] == 1514 and short["short_string_groups"] == 709
    unreviewed_id = low["dispositions"].index("unreviewed_source_semantics")
    rows = []
    for row in low["rows"]:
        kind, _, value, _, _, role_id, disposition_id, anchors = row[:8]
        if kind != "s" or len(value) < 8 or disposition_id != unreviewed_id:
            continue
        role = low["roles"][role_id]
        rows.append(["long", value, LONG_DECISIONS[role], anchors])
    for row in short["rows"]:
        value, _, _, role, anchors = row[:5]
        if role not in SHORT_DECISIONS:
            continue
        rows.append(["short", value, SHORT_DECISIONS[role], anchors])
    assert len(rows) == 870
    counts = Counter(row[2] for row in rows)
    return {
        "status": "bounded_static_literal_role_screen_not_full_caller_review",
        "snapshot": low["snapshot"],
        "input_census_sha256": low["input_sha256"],
        "source_file_table": "inline-literal-lowfanout-ledger.json:files",
        "row_schema": ["length_class", "value", "source_role_disposition", "first_two_distinct_module_file_id_line_anchors"],
        "role_screened_groups": len(rows),
        "long_groups": sum(row[0] == "long" for row in rows),
        "short_groups": sum(row[0] == "short" for row in rows),
        "disposition_counts": dict(sorted(counts.items())),
        "limits": "These are source-role dispositions for low-fanout lexical matches, not assertions that all callers are semantically equivalent or that no feature duplicates a literal through generated/dynamic code. Source anchors and file hashes are in the input ledgers; material shared rules are assessed separately in the raw findings and review notes.",
        "rows": rows,
    }


if __name__ == "__main__":
    report = build(Path(sys.argv[1]), Path(sys.argv[2]))
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
