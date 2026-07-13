#!/usr/bin/env python3
"""Validate dashboard-companion publication against the Build Order graph."""

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
    strict_object,
    string_list,
)
from publication_auxiliary import validate_auxiliary
from publication_body_evidence import validate_all_body_evidence
from publication_core_receipt import validate_commit_reference, validate_core_receipt
from publication_receipt import validate_receipt
from publication_rendering import render_approved_pack
from publication_records import (
    build_tickets,
    dash_tickets,
    external_gates,
    github_mappings,
    validate_graph,
)


TOP_KEYS = {
    "schema_version",
    "plan_version",
    "repository",
    "researched_at_commit",
    "approved_planning_commit",
    "required_labels",
    "forbidden_labels",
    "external_gates",
    "tickets",
    "github_reconciliation",
}


def validate(
    companion_path: Path, build_path: Path, publication_path: Path | None = None,
) -> Report:
    report = Report()
    companions = load_json(companion_path, "dashboard-companions", report)
    build_order = load_json(build_path, "build-order", report)
    publication_path = publication_path or companion_path.parent / "publication.json"
    publication = load_json(publication_path, "publication", report)
    if companions is None or build_order is None or publication is None:
        return report
    data = strict_object(companions, "top level", TOP_KEYS, report)
    if data is None:
        return report
    repository = _header(data, build_path, report)
    gates = external_gates(data, report)
    build = build_tickets(build_order, repository, report)
    dash = dash_tickets(data, companion_path.parent, repository, gates, report)
    validate_graph(build, dash, report)
    mappings = github_mappings(build_order, build, dash, repository, report)
    # The pinned canonical validator owns the BO receipt shape and membership;
    # its presence here still makes publication globally all-or-nothing.
    materialized = (
        any(mapping is not None for mapping in mappings.values())
        or data.get("github_reconciliation") is not None
        or build_order.get("github_reconciliation") is not None
        or publication.get("github_reconciliation") is not None
    )
    validate_receipt(data, dash, mappings, materialized, report)
    validate_auxiliary(
        publication, publication_path.parent, build_order, mappings, repository,
        data.get("plan_version"), data.get("approved_planning_commit"),
        materialized, report,
    )
    expected_bodies = None
    if materialized:
        expected_bodies = render_approved_pack(
            build_order, data, publication, build_path, companion_path,
            publication_path, data.get("approved_planning_commit"), report,
        )
    validate_core_receipt(build_path, materialized, expected_bodies, report)
    validate_all_body_evidence(
        build_order, data, publication, mappings, expected_bodies,
        materialized, report,
    )
    return report


def _header(data: dict[str, Any], build_path: Path, report: Report) -> str:
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
    approved = data.get("approved_planning_commit")
    if approved is not None and (not isinstance(approved, str) or not SHA.fullmatch(approved)):
        report.error("approved_planning_commit must be null or a 40-character Git SHA")
    elif approved is not None:
        validate_commit_reference(
            approved, "approved_planning_commit", build_path, report
        )
    _label_contract(data, report)
    return repository


def _label_contract(data: dict[str, Any], report: Report) -> None:
    required = string_list(data.get("required_labels"), "required_labels", report)
    forbidden = string_list(data.get("forbidden_labels"), "forbidden_labels", report)
    if required != ["model:codex"]:
        report.error("required_labels must equal model:codex")
    if set(forbidden) != AGENT_LABELS or len(forbidden) != len(AGENT_LABELS):
        report.error("forbidden_labels must exactly match the bounded agent-state denylist")
    overlap = sorted(set(required) & set(forbidden))
    if overlap:
        report.error("required_labels and forbidden_labels overlap: " + ", ".join(overlap))


def main(argv: list[str]) -> int:
    if len(argv) == 1:
        base = Path(__file__).resolve().parent.parent
        companion_path = base / "dashboard-companions.json"
        build_path = base / "build-order.json"
        publication_path = base / "publication.json"
    elif len(argv) == 3:
        companion_path, build_path = Path(argv[1]), Path(argv[2])
        publication_path = companion_path.parent / "publication.json"
    elif len(argv) == 4:
        companion_path, build_path, publication_path = map(Path, argv[1:])
    else:
        print(
            "usage: validate_publication.py [dashboard-companions.json build-order.json [publication.json]]",
            file=sys.stderr,
        )
        return 64
    report = validate(companion_path, build_path, publication_path)
    for message in sorted(report.errors):
        print(f"ERROR: {message}")
    for message in sorted(report.warnings):
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
