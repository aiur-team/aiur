"""Shared primitives for the planning-only publication validator."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from publication_paths import resolved_document


DASH_ID = re.compile(r"^DASH-[0-9]{3,}$", re.ASCII)
BO_ID = re.compile(r"^BO-[0-9]{3,}[A-Z]?$", re.ASCII)
REQ_ID = re.compile(r"^DREQ-[0-9]{3,}$", re.ASCII)
REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
EXTERNAL_BLOCKER = re.compile(r"^[^/#\s]+/[^/#\s]+#[1-9][0-9]*$", re.ASCII)
GATE_ID = re.compile(r"^GATE-[A-Z0-9]+(?:-[A-Z0-9]+)*$", re.ASCII)
SHA = re.compile(r"^[0-9a-fA-F]{40}$", re.ASCII)
TRUSTED_BRANCH_REF = re.compile(
    r"^refs/heads/[A-Za-z0-9](?:[A-Za-z0-9._/-]*[A-Za-z0-9_-])?$",
    re.ASCII,
)
AGENT_LABELS = {
    "agent:todo",
    "agent:in-progress",
    "agent:human-review",
    "agent:rework",
    "agent:merging",
    "agent:paused",
    "agent:done",
    "agent:ci-wait",
    "agent:error",
    "agent:canceled",
    "agent:cancelled",
    "agent:watch",
}
GITHUB_KEYS = {"repository", "number", "node_id", "url"}
RFC3339_UTC = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z$",
    re.ASCII,
)


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def valid_issue_title(value: object) -> bool:
    return (
        isinstance(value, str)
        and value == value.strip()
        and 0 < len(value) <= 256
        and not any(character in value for character in ("\x00", "\r", "\n"))
    )


def valid_trusted_branch_ref(value: object) -> bool:
    if not isinstance(value, str) or not TRUSTED_BRANCH_REF.fullmatch(value):
        return False
    branch = value.removeprefix("refs/heads/")
    return not (
        ".." in branch
        or "@{" in branch
        or "//" in branch
        or branch.endswith((".", "/", ".lock"))
        or branch.startswith("/")
        or "\\" in branch
    )


def valid_rfc3339_utc(value: object) -> bool:
    if not isinstance(value, str) or not RFC3339_UTC.fullmatch(value):
        return False
    try:
        datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError:
        return False
    return True


def strict_int(value: object) -> bool:
    return type(value) is int


def strict_object(
    value: object, label: str, keys: set[str], report: Report
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        report.error(f"{label} must be an object")
        return None
    for key in sorted(keys - set(value)):
        report.error(f"{label}: missing required key {key}")
    for key in sorted(set(value) - keys):
        report.error(f"{label}: unknown key {key}")
    return value


def string_list(value: object, label: str, report: Report) -> list[str]:
    if not isinstance(value, list):
        report.error(f"{label} must be an array of strings")
        return []
    result: list[str] = []
    for index, item in enumerate(value):
        if nonempty_string(item):
            result.append(item)
        else:
            report.error(f"{label}[{index}] must be a non-empty string")
    duplicates = {item for item in result if result.count(item) > 1}
    for item in sorted(duplicates):
        report.error(f"{label} contains duplicate value {item}")
    return result


def safe_string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if nonempty_string(item)]


def load_json(path: Path, label: str, report: Report) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid {label} JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"{label} must be a JSON object")
        return None
    return value


def github_mapping(
    value: object, label: str, repository: str, report: Report
) -> dict[str, Any] | None:
    if value is None:
        return None
    mapping = strict_object(value, label, GITHUB_KEYS, report)
    if mapping is None:
        return None
    if mapping.get("repository") != repository:
        report.error(f"{label}.repository must equal {repository}")
    number = mapping.get("number")
    if not strict_int(number) or number < 1:
        report.error(f"{label}.number must be a positive integer")
    if not nonempty_string(mapping.get("node_id")):
        report.error(f"{label}.node_id must be a non-empty string")
    url = mapping.get("url")
    if strict_int(number) and number > 0:
        expected = f"https://github.com/{repository}/issues/{number}"
        if url != expected:
            report.error(f"{label}.url must equal {expected}")
    elif not nonempty_string(url):
        report.error(f"{label}.url must be a non-empty string")
    return mapping


def validate_document(ticket: dict[str, Any], base: Path, report: Report) -> None:
    ticket_id, value = ticket.get("id"), ticket.get("document")
    path = resolved_document(base, value, f"{ticket_id}.document", report)
    if path is None:
        return
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        report.error(f"{ticket_id}.document cannot be read: {exc}")
        return
    expected_heading = f"# {ticket_id} — {ticket.get('title')}"
    if not text.splitlines() or text.splitlines()[0] != expected_heading:
        report.error(
            f"{ticket_id}.document heading must equal {expected_heading!r}"
        )
    complexity = ticket.get("complexity_points")
    if not re.search(rf"(?m)^\*\*Complexity:\*\*\s+{complexity}(?:\s|$)", text):
        report.error(f"{ticket_id}.document complexity must match JSON")
    requirement = re.escape(str(ticket.get("requirement_ref")))
    if not re.search(rf"(?m)^\*\*Requirements:\*\*.*\b{requirement}\b", text):
        report.error(f"{ticket_id}.document requirement must match JSON")
    if not re.search(r"(?m)^\*\*Build Order membership:\*\*\s+none\b", text):
        report.error(f"{ticket_id}.document must declare no Build Order membership")
    _document_dependencies(ticket, text, report)
    for gate_id in safe_string_list(ticket.get("external_gate_ids")):
        if gate_id not in text:
            report.error(f"{ticket_id}.document missing external gate {gate_id}")


def _document_dependencies(
    ticket: dict[str, Any], text: str, report: Report,
) -> None:
    ticket_id = ticket.get("id")
    match = re.search(r"(?m)^\*\*Depends on:\*\*\s+(.+)$", text)
    if match is None:
        report.error(f"{ticket_id}.document must declare Depends on")
        return
    raw = match.group(1).strip()
    observed = set() if raw == "none" else {item.strip() for item in raw.split(",")}
    expected = set(safe_string_list(ticket.get("depends_on")))
    expected |= set(safe_string_list(ticket.get("external_blockers")))
    if observed != expected:
        report.error(f"{ticket_id}.document dependencies must match JSON")
