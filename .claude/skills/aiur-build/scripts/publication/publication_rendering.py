"""Render every published issue body from the immutable approved commit."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
from typing import Any

from publication_common import Report
from publication_paths import safe_repository_relative
from publication_rendering_sections import (
    _approved_content_titles,
    _approved_document_title,
    _approved_json,
    _approved_ticket_titles,
    authority_preamble,
    _current_document_bytes,
    exact_commit,
    _frozen_planning_fields,
    _git_show,
    inspect_issue_body,
    repository_relative,
    repository_root,
    _tickets,
)
from publication_rendering_sections import (  # noqa: F401
    approved_link,
    AUTHORITY_GIT_TIMEOUT_SECONDS,
    BODY_SHA,
    COMMIT_LINK,
    EVIDENCE_KEYS,
    MARKER,
    MARKER_KEYS,
    MARKER_NAME,
    _regular_tree_entry,
    reject_legacy_grafts,
    run_authority_git,
)


def render_approved_pack(
    build: dict[str, Any], publication: dict[str, Any],
    build_path: Path, publication_path: Path,
    approved: object, report: Report,
) -> dict[str, dict[str, Any]] | None:
    """Use only ``git show <approval>:<path>`` to derive all published bodies."""
    root = repository_root(build_path, report)
    if root is None or not exact_commit(root, approved, "approved_planning_commit", report):
        return None
    if not isinstance(approved, str):
        return None
    current_paths = (build_path, publication_path)
    relative_paths = [repository_relative(path, root, report) for path in current_paths]
    if any(path is None for path in relative_paths):
        return None
    approved_build = _approved_json(root, approved, relative_paths[0], "build-order", report)
    approved_publication = _approved_json(
        root, approved, relative_paths[1], "publication", report
    )
    if any(value is None for value in (approved_build, approved_publication)):
        return None
    assert approved_build is not None
    assert approved_publication is not None
    frozen_packs = (
        ("build-order", approved_build, build, "build"),
        ("publication", approved_publication, publication, "publication"),
    )
    for label, approved_pack, current_pack, family in frozen_packs:
        if _frozen_planning_fields(approved_pack, family) != _frozen_planning_fields(
            current_pack, family
        ):
            report.error(
                f"materialized {label} planning fields must equal the approved commit"
            )
            return None
    repository = build.get("repository")
    plan_version = build.get("plan_version")
    root_id = build.get("build_order_id")
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    if not isinstance(repository, str) or type(plan_version) is not int:
        report.error("materialized pack identity is unavailable for body rendering")
        return None
    if not isinstance(root_id, str) or not isinstance(skill_id, str):
        report.error("materialized root and skill identities are required for body rendering")
        return None
    _same_header(approved_build, build, ("repository", "plan_version", "build_order_id"), "build-order", report)
    _same_header(approved_publication, publication, ("repository", "plan_version"), "publication", report)
    current_tickets, approved_tickets = _tickets(build), _tickets(approved_build)
    if set(current_tickets) != set(approved_tickets):
        report.error("approved build-order ticket IDs must match the materialized pack")
    approved_root = approved_publication.get("root_issue")
    approved_skill = approved_publication.get("skill_issue")
    if not isinstance(approved_root, dict) or approved_root.get("logical_id") != root_id:
        report.error("approved publication root identity must match the materialized pack")
    if not isinstance(approved_skill, dict) or approved_skill.get("logical_id") != skill_id:
        report.error("approved publication skill identity must match the materialized pack")
    expectations: dict[str, dict[str, Any]] = {}
    _render_template(
        expectations, root, approved, PurePosixPath(relative_paths[1]).parent,
        approved_root, publication.get("root_issue"), publication_path.parent,
        root_id, repository, plan_version, "approved root", report,
    )
    _render_template(
        expectations, root, approved, PurePosixPath(relative_paths[1]).parent,
        approved_skill, publication.get("skill_issue"), publication_path.parent,
        skill_id, repository, plan_version, "approved skill", report,
    )
    _render_tickets(
        expectations, root, approved, PurePosixPath(relative_paths[0]).parent,
        approved_tickets, current_tickets, build_path.parent,
        repository, plan_version, "ticket", report,
    )
    expected_ids = {root_id, skill_id, *current_tickets}
    if set(expectations) != expected_ids:
        report.error("approved body rendering must exactly cover root, ticket, and skill issues")
        return None
    return expectations


def render_approved_titles(
    build: dict[str, Any], publication: dict[str, Any],
    build_path: Path, publication_path: Path,
    approved: object, report: Report,
) -> dict[str, str] | None:
    """Derive every exact issue title from the immutable approval commit."""
    root = repository_root(build_path, report)
    if root is None or not exact_commit(
        root, approved, "approved_planning_commit", report
    ):
        return None
    if not isinstance(approved, str):
        return None
    relative_paths = [
        repository_relative(path, root, report)
        for path in (build_path, publication_path)
    ]
    if any(path is None for path in relative_paths):
        return None
    approved_build = _approved_json(
        root, approved, relative_paths[0], "build-order", report
    )
    approved_publication = _approved_json(
        root, approved, relative_paths[1], "publication", report
    )
    if any(value is None for value in (approved_build, approved_publication)):
        return None
    assert approved_build is not None
    assert approved_publication is not None
    for label, approved_pack, current_pack, family in (
        ("build-order", approved_build, build, "build"),
        ("publication", approved_publication, publication, "publication"),
    ):
        if _frozen_planning_fields(
            approved_pack, family
        ) != _frozen_planning_fields(current_pack, family):
            report.error(
                f"materialized {label} planning fields must equal the approved commit"
            )
            return None

    titles: dict[str, str] = {}
    _approved_ticket_titles(
        titles, root, approved, PurePosixPath(relative_paths[0]).parent,
        approved_build, "ticket", report,
    )
    for key in ("root_issue", "skill_issue"):
        issue = approved_publication.get(key)
        label = f"approved publication {key}"
        if not isinstance(issue, dict):
            report.error(f"{label} must be an object")
            continue
        _approved_document_title(
            titles, root, approved, PurePosixPath(relative_paths[1]).parent,
            issue.get("logical_id"), issue.get("document"), None, label, report,
        )

    current_ids = {*(_tickets(build)), build.get("build_order_id")}
    skill = publication.get("skill_issue")
    if isinstance(skill, dict):
        current_ids.add(skill.get("logical_id"))
    if None in current_ids or set(titles) != current_ids:
        report.error(
            "approved title rendering must exactly cover root, ticket, and skill issues"
        )
        return None
    return titles


def render_approved_issue_content(
    build_path: Path, publication_path: Path, approved: object, report: Report,
) -> tuple[dict[str, str], dict[str, str], dict[str, dict[str, Any]]] | None:
    """Render titles, bodies, and evidence using only approval-commit blobs.

    This is the publication operator's write-side counterpart to
    :func:`render_approved_pack`.  It deliberately does not consult current
    document bytes: an unmaterialized checkout still contains
    ``<APPROVED_SHA>`` in the two templates.  The caller may write those exact
    substitutions only after authority and collision checks succeed.
    """
    root = repository_root(build_path, report)
    if root is None or not exact_commit(
        root, approved, "approved_planning_commit", report
    ) or not isinstance(approved, str):
        return None
    relative_paths = [
        repository_relative(path, root, report)
        for path in (build_path, publication_path)
    ]
    if any(path is None for path in relative_paths):
        return None
    build_relative, publication_relative = relative_paths
    assert build_relative is not None and publication_relative is not None
    build = _approved_json(root, approved, build_relative, "build-order", report)
    publication = _approved_json(
        root, approved, publication_relative, "publication", report
    )
    if build is None or publication is None:
        return None
    try:
        current_build = json.loads(build_path.read_text(encoding="utf-8"))
        current_publication = json.loads(
            publication_path.read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"current publication manifests must be valid JSON: {exc}")
        return None
    for label, approved_pack, current_pack, family in (
        ("build-order", build, current_build, "build"),
        ("publication", publication, current_publication, "publication"),
    ):
        if not isinstance(current_pack, dict) or _frozen_planning_fields(
            approved_pack, family
        ) != _frozen_planning_fields(current_pack, family):
            report.error(
                f"current {label} planning fields must equal the approved commit"
            )
            return None
    repository, plan_version = build.get("repository"), build.get("plan_version")
    root_id = build.get("build_order_id")
    root_issue, skill_issue = publication.get("root_issue"), publication.get("skill_issue")
    skill_id = skill_issue.get("logical_id") if isinstance(skill_issue, dict) else None
    if (
        not isinstance(repository, str) or type(plan_version) is not int
        or not isinstance(root_id, str) or not isinstance(skill_id, str)
    ):
        report.error("approved publication identity is unavailable")
        return None

    bodies: dict[str, str] = {}
    evidence: dict[str, dict[str, Any]] = {}
    build_dir, publication_dir = (
        PurePosixPath(build_relative).parent,
        PurePosixPath(publication_relative).parent,
    )
    for logical_id, issue, label in (
        (root_id, root_issue, "approved root"),
        (skill_id, skill_issue, "approved skill"),
    ):
        if not isinstance(issue, dict):
            report.error(f"{label} must be an object")
            continue
        document = safe_repository_relative(
            issue.get("document"), f"{label}.document", report,
        )
        if document is None:
            continue
        template = _git_show(
            root, approved, str(publication_dir / PurePosixPath(document)),
            f"{label} document", report,
        )
        if template is None:
            continue
        if template.count("<APPROVED_SHA>") < 1:
            report.error(f"{label} document must contain <APPROVED_SHA>")
            continue
        body = template.replace("<APPROVED_SHA>", approved)
        inspected = inspect_issue_body(
            body, repository, logical_id, plan_version, approved, report,
            f"{label} body",
        )
        if inspected is not None:
            bodies[logical_id], evidence[logical_id] = body, inspected

    tickets = build.get("tickets")
    if not isinstance(tickets, list):
        report.error("approved build-order tickets must be an array")
        return None
    for index, ticket in enumerate(tickets):
        label = f"approved build-order tickets[{index}]"
        if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
            report.error(f"{label} must have a logical ID")
            continue
        logical_id = ticket["id"]
        document = safe_repository_relative(
            ticket.get("document"), f"{label}.document", report,
        )
        if document is None:
            continue
        source = _git_show(
            root, approved, str(build_dir / PurePosixPath(document)),
            f"approved {logical_id} document", report,
        )
        if source is None:
            continue
        body = authority_preamble(
            repository, logical_id, plan_version, approved,
        ) + source
        inspected = inspect_issue_body(
            body, repository, logical_id, plan_version, approved, report,
            f"approved ticket body {logical_id}",
        )
        if inspected is not None:
            bodies[logical_id], evidence[logical_id] = body, inspected

    titles = _approved_content_titles(
        root, approved, build_dir, publication_dir, build, publication, report,
    )
    expected_ids = {root_id, skill_id} | {
        item.get("id") for item in tickets if isinstance(item, dict)
    }
    if (
        None in expected_ids or set(bodies) != expected_ids
        or set(evidence) != expected_ids or set(titles) != expected_ids
    ):
        report.error("approved publication content must exactly cover all 56 issues")
        return None
    return titles, bodies, evidence


def _render_tickets(
    output: dict[str, dict[str, Any]], root: Path, approved: str,
    pack_dir: PurePosixPath, tickets: dict[str, dict[str, Any]],
    current_tickets: dict[str, dict[str, Any]], current_base: Path,
    repository: str, plan_version: int, family: str, report: Report,
) -> None:
    for logical_id in sorted(tickets):
        ticket = tickets[logical_id]
        document = safe_repository_relative(
            ticket.get("document"), f"approved {logical_id}.document", report,
        )
        if document is None:
            continue
        source = _git_show(
            root, approved, str(pack_dir / PurePosixPath(document)),
            f"approved {logical_id} document", report,
        )
        if source is None:
            continue
        current_ticket = current_tickets.get(logical_id)
        current_document = (
            current_ticket.get("document") if isinstance(current_ticket, dict) else None
        )
        current_source = _current_document_bytes(
            current_base, current_document, f"current {logical_id} document", report
        )
        if current_source is None:
            continue
        if current_source != source.encode("utf-8"):
            report.error(
                f"current {logical_id} document must equal the approved source byte-for-byte"
            )
            continue
        body = authority_preamble(repository, logical_id, plan_version, approved) + source
        evidence = inspect_issue_body(
            body, repository, logical_id, plan_version, approved,
            report, f"approved {family} body {logical_id}",
        )
        if evidence is not None:
            output[logical_id] = evidence


def _render_template(
    output: dict[str, dict[str, Any]], root: Path, approved: str,
    pack_dir: PurePosixPath, issue: object,
    current_issue: object, current_base: Path, logical_id: str,
    repository: str, plan_version: int, label: str, report: Report,
) -> None:
    if not isinstance(issue, dict):
        return
    document = safe_repository_relative(
        issue.get("document"), f"{label}.document", report,
    )
    if document is None:
        return
    template = _git_show(
        root, approved, str(pack_dir / PurePosixPath(document)),
        f"{label} document", report,
    )
    if template is None:
        return
    if "<APPROVED_SHA>" not in template:
        report.error(f"{label} document must contain <APPROVED_SHA>")
        return
    body = template.replace("<APPROVED_SHA>", approved)
    current_document = (
        current_issue.get("document") if isinstance(current_issue, dict) else None
    )
    current_source = _current_document_bytes(
        current_base, current_document, f"current {label} document", report
    )
    if current_source is None:
        return
    if current_source != body.encode("utf-8"):
        report.error(
            f"current {label} document must equal the approved template after approval substitution"
        )
        return
    evidence = inspect_issue_body(
        body, repository, logical_id, plan_version, approved,
        report, f"{label} body",
    )
    if evidence is not None:
        output[logical_id] = evidence


def _same_header(
    approved: dict[str, Any], current: dict[str, Any], keys: tuple[str, ...],
    label: str, report: Report,
) -> None:
    for key in keys:
        if approved.get(key) != current.get(key):
            report.error(f"approved {label} {key} must match the materialized pack")


