"""Validate captured design evidence and planning decisions."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from validation_common import (
    DECISION_ID,
    DESIGN_ID,
    Report,
    checked_string_list,
    nonempty_string,
    resolve_regular_file,
    safe_list,
    strict_object,
)


DESIGN_KEYS = {"id", "source", "captured_at", "artifact", "sha256"}
DECISION_KEYS = {"id", "summary", "status", "rationale", "design_evidence_refs"}


def _artifact_path(value: object, label: str, base_dir: Path, report: Report) -> Path | None:
    return resolve_regular_file(base_dir, value, label, report)


def validate_design_evidence(
    data: dict[str, Any], base_dir: Path, report: Report
) -> dict[str, dict[str, Any]]:
    records = data.get("design_evidence")
    if not isinstance(records, list):
        report.error("design_evidence must be an array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(records):
        label = f"design_evidence[{index}]"
        record = strict_object(value, label, DESIGN_KEYS, report)
        if record is None:
            continue
        evidence_id = record.get("id")
        if not isinstance(evidence_id, str) or not DESIGN_ID.fullmatch(evidence_id):
            report.error(f"{label}.id must look like DESIGN-001")
            continue
        if evidence_id in found:
            report.error(f"duplicate design evidence id {evidence_id}")
        else:
            found[evidence_id] = record
        for field in ("source", "captured_at"):
            if not nonempty_string(record.get(field)):
                report.error(f"{evidence_id}.{field} must be a non-empty string")
        expected_hash = record.get("sha256")
        if not isinstance(expected_hash, str) or len(expected_hash) != 64:
            report.error(f"{evidence_id}.sha256 must be a 64-character digest")
            expected_hash = None
        else:
            try:
                int(expected_hash, 16)
            except ValueError:
                report.error(f"{evidence_id}.sha256 must be hexadecimal")
                expected_hash = None
        path = _artifact_path(record.get("artifact"), f"{evidence_id}.artifact", base_dir, report)
        if path is not None and expected_hash is not None:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual.casefold() != expected_hash.casefold():
                report.error(f"{evidence_id}.sha256 does not match {record.get('artifact')}")
    return found


def validate_decisions(data: dict[str, Any], report: Report) -> dict[str, dict[str, Any]]:
    records = data.get("decisions")
    if not isinstance(records, list) or not records:
        report.error("decisions must be a non-empty array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(records):
        label = f"decisions[{index}]"
        record = strict_object(value, label, DECISION_KEYS, report)
        if record is None:
            continue
        decision_id = record.get("id")
        if not isinstance(decision_id, str) or not DECISION_ID.fullmatch(decision_id):
            report.error(f"{label}.id must look like DEC-001")
            continue
        if decision_id in found:
            report.error(f"duplicate decision id {decision_id}")
        else:
            found[decision_id] = record
        for field in ("summary", "rationale"):
            if not nonempty_string(record.get(field)):
                report.error(f"{decision_id}.{field} must be a non-empty string")
        status = record.get("status")
        if not isinstance(status, str) or status not in {"accepted", "rejected"}:
            report.error(f"{decision_id}.status must be accepted or rejected")
        checked_string_list(
            record.get("design_evidence_refs"),
            f"{decision_id}.design_evidence_refs",
            report,
        )
    return found


def validate_record_refs(
    design: dict[str, dict[str, Any]],
    decisions: dict[str, dict[str, Any]],
    tickets: dict[str, dict[str, Any]],
    report: Report,
) -> None:
    design_users: set[str] = set()
    decision_users: set[str] = set()
    for decision_id, decision in decisions.items():
        for evidence_id in safe_list(decision, "design_evidence_refs"):
            if evidence_id not in design:
                report.error(f"{decision_id}: unknown design evidence ref {evidence_id}")
            else:
                design_users.add(evidence_id)
    for ticket_id, ticket in tickets.items():
        for decision_id in safe_list(ticket, "decision_refs"):
            decision = decisions.get(decision_id)
            if decision is None:
                report.error(f"{ticket_id}: unknown decision ref {decision_id}")
            elif decision.get("status") != "accepted":
                report.error(f"{ticket_id}: cannot reference rejected decision {decision_id}")
            else:
                decision_users.add(decision_id)
        for evidence_id in safe_list(ticket, "design_evidence_refs"):
            if evidence_id not in design:
                report.error(f"{ticket_id}: unknown design evidence ref {evidence_id}")
            else:
                design_users.add(evidence_id)
    for decision_id, decision in decisions.items():
        if decision.get("status") == "accepted" and decision_id not in decision_users:
            report.error(f"{decision_id}: accepted decision is not referenced by any ticket")
    for evidence_id in design:
        if evidence_id not in design_users:
            report.error(f"{evidence_id}: design evidence is not referenced")
