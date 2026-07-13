"""Validate root and auxiliary-skill publication evidence."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from publication_common import (
    EXTERNAL_BLOCKER,
    SHA,
    Report,
    nonempty_string,
    strict_object,
    string_list,
    valid_trusted_branch_ref,
)
from publication_auxiliary_receipt import parse_edges, validate_auxiliary_receipt
from publication_core_receipt import validate_commit_reference
from publication_paths import resolved_document


TOP_KEYS = {
    "schema_version", "plan_version", "repository", "approved_planning_commit",
    "trusted_repository_ref",
    "root_issue", "skill_issue", "external_blocker_relations",
    "read_only_issue_refs", "github_reconciliation",
}
ISSUE_KEYS = {
    "logical_id", "document", "required_labels", "forbidden_labels",
    "forbidden_label_prefixes",
}
SKILL_ID = re.compile(r"^SKILL-DELIVERY-[0-9]{3,}$", re.ASCII)
FORBIDDEN_PREFIXES = {"agent:", "model:", "complexity:", "phase:", "build-lane:"}
ROOT_FORBIDDEN_PREFIXES = FORBIDDEN_PREFIXES | {"human:"}


def validate_auxiliary(
    data: dict[str, Any], base: Path, build_data: dict[str, Any],
    core_mappings: dict[str, Any], repository: str,
    pack_materialized: bool, report: Report,
) -> None:
    manifest = strict_object(data, "publication", TOP_KEYS, report)
    if manifest is None:
        return
    _header(manifest, base, repository, build_data.get("plan_version"), report)
    root_id = build_data.get("build_order_id")
    if not nonempty_string(root_id):
        report.error("build-order.build_order_id must be a non-empty string")
        root_id = None
    root = _issue(manifest.get("root_issue"), "root_issue", root_id, base, report)
    skill = _issue(manifest.get("skill_issue"), "skill_issue", None, base, report)
    skill_id = skill.get("logical_id") if skill else None
    if not isinstance(skill_id, str) or not SKILL_ID.fullmatch(skill_id):
        report.error("skill_issue.logical_id must look like SKILL-DELIVERY-001")
    _policy(
        root, "root_issue", {"build-order"}, set(), ROOT_FORBIDDEN_PREFIXES, report
    )
    _policy(
        skill, "skill_issue", {"human:todo"}, {"build-order"},
        FORBIDDEN_PREFIXES, report,
    )
    edges = parse_edges(
        manifest.get("external_blocker_relations"), "external_blocker_relations", report
    )
    expected_edge = (
        {(ticket_id, skill_id) for ticket_id in ("BO-004", "BO-008")}
        if isinstance(skill_id, str) else set()
    )
    if edges != expected_edge:
        report.error(
            "publication must declare BO-004 and BO-008 blocked by "
            "SKILL-DELIVERY-001"
        )
    read_only = _read_only_refs(
        manifest.get("read_only_issue_refs"), repository, report
    )
    validate_auxiliary_receipt(
        manifest, root.get("logical_id") if root else None, skill_id,
        edges, core_mappings, repository,
        pack_materialized, read_only, report,
    )


def _header(
    data: dict[str, Any], base: Path, repository: str,
    build_plan_version: object, report: Report,
) -> None:
    if type(data.get("schema_version")) is not int or data["schema_version"] != 1:
        report.error("publication.schema_version must be integer 1")
    if type(data.get("plan_version")) is not int or data["plan_version"] < 1:
        report.error("publication.plan_version must be a positive integer")
    elif data["plan_version"] != build_plan_version:
        report.error("publication and Build Order plan versions must match")
    if data.get("repository") != repository:
        report.error("publication.repository must match the Build Order manifest")
    if not valid_trusted_branch_ref(data.get("trusted_repository_ref")):
        report.error(
            "publication.trusted_repository_ref must be an exact refs/heads/... "
            "repository-owned branch ref"
        )
    approved = data.get("approved_planning_commit")
    if approved is not None and (not isinstance(approved, str) or not SHA.fullmatch(approved)):
        report.error("publication.approved_planning_commit must be null or a Git SHA")
    elif approved is not None:
        validate_commit_reference(
            approved, "approved_planning_commit", base / "publication.json", report
        )


def _issue(
    value: object, label: str, expected_id: object, base: Path, report: Report,
) -> dict[str, Any] | None:
    issue = strict_object(value, label, ISSUE_KEYS, report)
    if issue is None:
        return None
    logical_id = issue.get("logical_id")
    if not nonempty_string(logical_id):
        report.error(f"{label}.logical_id must be a non-empty string")
    if expected_id is not None and logical_id != expected_id:
        report.error(f"{label}.logical_id must equal {expected_id}")
    document = issue.get("document")
    if not nonempty_string(document):
        report.error(f"{label}.document must be a relative path")
    else:
        _document(base, document, logical_id, label, report)
    for key in ("required_labels", "forbidden_labels", "forbidden_label_prefixes"):
        string_list(issue.get(key), f"{label}.{key}", report)
    return issue


def _document(
    base: Path, value: str, logical_id: object, label: str, report: Report,
) -> None:
    path = resolved_document(base, value, f"{label}.document", report)
    if path is None:
        return
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        report.error(f"{label}.document cannot be read: {exc}")
        return
    lines = text.splitlines()
    if not lines or not lines[0].startswith("# ") or str(logical_id) not in text:
        report.error(
            f"{label}.document must contain its logical ID and a title heading"
        )


def _policy(
    issue: dict[str, Any] | None, label: str, required: set[str],
    forbidden: set[str], expected_prefixes: set[str], report: Report,
) -> None:
    if issue is None:
        return
    declared = set(issue.get("required_labels", []))
    if declared != required:
        report.error(f"{label}.required_labels must equal " + ", ".join(sorted(required)))
    declared_forbidden = set(issue.get("forbidden_labels", []))
    if declared_forbidden != forbidden:
        report.error(
            f"{label}.forbidden_labels must equal " + ", ".join(sorted(forbidden))
        )
    prefixes = set(issue.get("forbidden_label_prefixes", []))
    if prefixes != expected_prefixes:
        report.error(
            f"{label}.forbidden_label_prefixes must equal "
            + ", ".join(sorted(expected_prefixes))
        )


def _read_only_refs(
    value: object, repository: str, report: Report,
) -> set[tuple[str, int]]:
    refs = set(string_list(value, "read_only_issue_refs", report))
    expected = {
        f"{repository}#{number}" for number in (132, 845, 1033, 1034, 1067)
    }
    if refs != expected:
        report.error("read_only_issue_refs must contain exactly #132, #845, #1033, #1034, and #1067")
    for ref in refs:
        if not EXTERNAL_BLOCKER.fullmatch(ref):
            report.error(f"read_only_issue_refs has invalid identity {ref}")
    return {
        (ref.rsplit("#", 1)[0], int(ref.rsplit("#", 1)[1]))
        for ref in refs
        if EXTERNAL_BLOCKER.fullmatch(ref)
    }
