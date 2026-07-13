#!/usr/bin/env python3
"""Validate consolidated Build Order publication against the single manifest."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from publication_common import (
    AGENT_LABELS,
    REPOSITORY,
    SHA,
    Report,
    load_json,
    strict_int,
    string_list,
)
from publication_auxiliary import validate_auxiliary
from publication_body_evidence import validate_all_body_evidence
from publication_core_receipt import validate_core_receipt
from publication_rendering import render_approved_pack
from publication_rendering import render_approved_titles
from publication_title_evidence import validate_all_title_evidence
from publication_state_evidence import validate_all_issue_state_evidence
from publication_records import (
    external_gates,
    github_mappings,
    manifest_tickets,
    validate_graph,
)


def validate(build_path: Path, publication_path: Path | None = None) -> Report:
    report = Report()
    build_order = load_json(build_path, "build-order", report)
    publication_path = publication_path or build_path.parent / "publication.json"
    publication = load_json(publication_path, "publication", report)
    if build_order is None or publication is None:
        return report
    repository = _header(build_order, report)
    gates = external_gates(build_order, report)
    tickets = manifest_tickets(
        build_order, build_path.parent, repository, gates, report
    )
    validate_graph(tickets, report)
    mappings = github_mappings(build_order, tickets, repository, report)
    # The pinned canonical validator owns the core receipt shape and membership;
    # its presence here still makes publication globally all-or-nothing.
    materialized = (
        any(mapping is not None for mapping in mappings.values())
        or build_order.get("github_reconciliation") is not None
        or publication.get("github_reconciliation") is not None
    )
    approved = publication.get("approved_planning_commit")
    validate_auxiliary(
        publication, publication_path.parent, build_order, mappings, repository,
        materialized, report,
    )
    expected_bodies = None
    expected_titles = None
    if materialized:
        expected_bodies = render_approved_pack(
            build_order, publication, build_path, publication_path,
            approved, report,
        )
        expected_titles = render_approved_titles(
            build_order, publication, build_path, publication_path,
            approved, report,
        )
    validate_core_receipt(
        build_path, materialized, expected_bodies, expected_titles, report
    )
    validate_all_body_evidence(
        build_order, publication, mappings, expected_bodies,
        materialized, report,
    )
    validate_all_title_evidence(
        build_order, publication, expected_titles, materialized, report,
    )
    validate_all_issue_state_evidence(
        build_order, publication, materialized, report,
    )
    return report


def _header(data: dict[str, Any], report: Report) -> str:
    if data.get("schema_version") != 1:
        report.error("schema_version must be integer 1")
    if not strict_int(data.get("plan_version")) or data["plan_version"] < 1:
        report.error("plan_version must be a positive integer")
    repository = data.get("repository")
    if not isinstance(repository, str) or not REPOSITORY.fullmatch(repository):
        report.error("repository must be owner/repo")
        repository = "invalid/invalid"
    researched = data.get("researched_at_commit")
    if not isinstance(researched, str) or not SHA.fullmatch(researched):
        report.error("researched_at_commit must be a 40-character Git SHA")
    _label_contract(data, report)
    return repository


def _label_contract(data: dict[str, Any], report: Report) -> None:
    projection = data.get("label_projection")
    if not isinstance(projection, dict):
        report.error("label_projection must be an object")
        return
    required = string_list(
        projection.get("required_ticket_labels"),
        "label_projection.required_ticket_labels",
        report,
    )
    forbidden = string_list(
        projection.get("forbidden_labels"), "label_projection.forbidden_labels",
        report,
    )
    if required != ["model:codex"]:
        report.error("label_projection.required_ticket_labels must equal model:codex")
    if set(forbidden) != AGENT_LABELS or len(forbidden) != len(AGENT_LABELS):
        report.error(
            "label_projection.forbidden_labels must exactly match the bounded "
            "agent-state denylist"
        )
    overlap = sorted(set(required) & set(forbidden))
    if overlap:
        report.error(
            "required and forbidden ticket labels overlap: " + ", ".join(overlap)
        )


def main(argv: list[str]) -> int:
    if len(argv) == 1:
        base = Path(__file__).resolve().parent.parent
        build_path = base / "build-order.json"
        publication_path = base / "publication.json"
    elif len(argv) == 2:
        build_path = Path(argv[1])
        publication_path = build_path.parent / "publication.json"
    elif len(argv) == 3:
        build_path, publication_path = map(Path, argv[1:])
    else:
        print(
            "usage: validate_publication.py [build-order.json [publication.json]]",
            file=sys.stderr,
        )
        return 64
    report = validate(build_path, publication_path)
    for message in sorted(report.errors):
        print(f"ERROR: {message}")
    for message in sorted(report.warnings):
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
