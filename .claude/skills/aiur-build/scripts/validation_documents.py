"""Validate worker-facing ticket documents referenced by the graph."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from validation_common import (
    RUNNABLE_KINDS,
    Report,
    nonempty_string,
    resolve_regular_file,
    safe_list,
)


REQUIRED_HEADINGS = (
    "Outcome",
    "Context and evidence",
    "Scope",
    "Non-goals",
    "Existing owner and reuse target",
    "Contract and invariants",
    "Refreshable implementation notes",
    "Acceptance and verification",
    "Failure, security, migration, and accessibility cases",
    "Surfaces",
    "Sibling boundaries and open gates",
)


def validate_document(
    ticket_id: str,
    value: object,
    ticket: dict[str, Any],
    data: dict[str, Any],
    base_dir: Path,
    report: Report,
) -> None:
    path = resolve_regular_file(
        base_dir, value, f"{ticket_id}.document", report,
    )
    if path is None:
        return
    try:
        text = path.read_text(encoding="utf-8")
        first_line = text.splitlines()[0]
    except (OSError, UnicodeError, IndexError) as exc:
        report.error(f"{ticket_id}.document cannot be read: {exc}")
        return
    if not re.match(
        rf"^#\s+(?:BO:\s+)?{re.escape(ticket_id)}(?:\s|\u2014|-)",
        first_line,
    ):
        report.error(
            f"{ticket_id}.document heading must begin with '# {ticket_id}' "
            f"or '# BO: {ticket_id}'"
        )
    kind = ticket.get("kind")
    if isinstance(kind, str) and not re.search(
        rf"(?m)^\*\*Kind:\*\*\s+{re.escape(kind)}\s*$", text
    ):
        report.error(f"{ticket_id}.document Kind metadata must match build-order.json")
    if not isinstance(kind, str) or kind not in RUNNABLE_KINDS:
        return
    researched_at = data.get("researched_at_commit")
    pattern = rf"(?m)^\*\*Researched at:\*\*\s+{re.escape(str(researched_at))}(?:\s|$)"
    if not re.search(pattern, text):
        report.error(f"{ticket_id}.document Researched at metadata must match build-order.json")
    for req_id in safe_list(ticket, "requirement_refs"):
        if isinstance(req_id, str) and not re.search(
            rf"(?m)^\*\*Requirements:\*\*.*\b{re.escape(req_id)}\b", text
        ):
            report.error(f"{ticket_id}.document Requirements metadata omits {req_id}")
    for heading in REQUIRED_HEADINGS:
        if not re.search(rf"(?m)^##\s+{re.escape(heading)}\s*$", text):
            report.error(f"{ticket_id}.document missing section: {heading}")
