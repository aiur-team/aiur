"""Validate canonical Build Order data and approved source documents."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from validation_common import Report, repository_path_from_file
from validation_github import validate_all_github
from validation_github_approved import (
    ApprovedIssueExpectations,
    render_approved_build_order,
)
from validation_graph import (
    dependency_closure,
    validate_boundary_refs,
    validate_edge_types,
    validate_hierarchy,
    validate_phases,
    validate_references,
)
from validation_header import (
    validate_boundary,
    validate_external_gates,
    validate_identity,
    validate_label_projection,
    validate_requirements,
    validate_workstreams,
)
from validation_outcome import (
    validate_epic_acceptance,
    validate_label_coverage,
    validate_surface_conflicts,
)
from validation_publication_authority import PublicationAuthority
from validation_records import (
    validate_decisions,
    validate_design_evidence,
    validate_record_refs,
)
from validation_tickets import validate_tickets


def validate_data(
    value: object, base_dir: Path,
    approved_expectations: ApprovedIssueExpectations | None = None,
    publication_authority: PublicationAuthority | None = None,
) -> Report:
    report = Report()
    if not isinstance(value, dict):
        report.error("top level must be a JSON object")
        return report
    data: dict[str, Any] = value
    validate_identity(data, report)
    workstreams = validate_workstreams(data, report)
    critical_path = validate_boundary(data, report)
    projection = validate_label_projection(data, report)
    gates = validate_external_gates(data, report)
    requirements = validate_requirements(data, report)
    design = validate_design_evidence(data, base_dir, report)
    decisions = validate_decisions(data, report)
    by_id = validate_tickets(data, base_dir, report)
    validate_record_refs(design, decisions, by_id, report)
    validate_references(requirements, by_id, workstreams, gates, report)
    validate_edge_types(by_id, report)
    closure = dependency_closure(by_id, report)
    validate_hierarchy(by_id, report)
    validate_phases(by_id, report)
    validate_boundary_refs(critical_path, by_id, report)
    validate_label_coverage(projection, workstreams, by_id, report)
    validate_surface_conflicts(by_id, closure, report)
    validate_epic_acceptance(data, by_id, closure, critical_path, report)
    validate_all_github(
        data, by_id, report, approved_expectations, publication_authority,
    )
    return report


def load(path: Path, report: Report) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid JSON: {exc}")
        return None


def _validate_path(
    path: Path,
    repository_root: Path | None,
    root_document: str | None,
    report: Report,
    publication_authority: PublicationAuthority | None = None,
) -> tuple[object | None, Report]:
    value = load(path, report)
    expectations = None
    if isinstance(value, dict) and repository_root is not None and root_document is not None:
        build_path = repository_path_from_file(
            path, repository_root, "build-order path", report,
        )
        receipt = value.get("github_reconciliation")
        approved = receipt.get("approved_planning_commit") if isinstance(receipt, dict) else None
        if build_path is not None:
            expectations = render_approved_build_order(
                repository_root, approved, build_path, root_document, value, report,
            )
    if value is None:
        return value, report
    validated = validate_data(
        value, path.parent, expectations, publication_authority,
    )
    validated.errors[:0] = report.errors
    validated.warnings[:0] = report.warnings
    return value, validated
