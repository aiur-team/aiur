"""Derive receipt authority from validated receipts and prove remote containment."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from publication_common import Report, SHA, valid_trusted_branch_ref
from publication_rendering import exact_commit


MANIFEST_NAMES = (
    "build-order.json",
    "publication.json",
)


RemoteRefContainmentChecker = Callable[[str, str, str, str], bool]


@dataclass(frozen=True)
class ReceiptAuthority:
    repository: str
    root_id: str
    plan_version: int
    approved_commit: str
    root_issue_url: str
    root_comment_url: str
    trusted_repository_ref: str
    receipt_manifests: dict[str, dict[str, Any]] = field(
        repr=False, compare=False,
    )


def _document_references(
    manifests: dict[str, dict[str, Any]],
) -> list[tuple[str, object]]:
    references: list[tuple[str, object]] = []
    tickets = manifests["build-order.json"].get("tickets")
    if isinstance(tickets, list):
        for index, ticket in enumerate(tickets):
            if isinstance(ticket, dict):
                ticket_id = ticket.get("id", index)
                references.append(
                    (f"receipt document for {ticket_id}", ticket.get("document"))
                )
    publication = manifests["publication.json"]
    for key in ("root_issue", "skill_issue"):
        issue = publication.get(key)
        if isinstance(issue, dict):
            references.append(
                (f"receipt document for {key}", issue.get("document"))
            )
    return references


def _json_object(raw: bytes, label: str, report: Report) -> dict[str, Any] | None:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.error(f"{label} must be valid UTF-8 JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"{label} must be a JSON object")
        return None
    return value


def _require_materialized_receipts(
    manifests: dict[str, dict[str, Any]], report: Report,
) -> None:
    for name in MANIFEST_NAMES:
        if not isinstance(manifests[name].get("github_reconciliation"), dict):
            report.error(
                f"receipt commit {name} github_reconciliation must be materialized"
            )


def _derive_authority(
    manifests: dict[str, dict[str, Any]], root: Path,
    trusted_repository: str, report: Report,
) -> ReceiptAuthority | None:
    build = manifests["build-order.json"]
    publication = manifests["publication.json"]
    repository = build.get("repository")
    root_id = build.get("build_order_id")
    plan_version = build.get("plan_version")
    approved = publication.get("approved_planning_commit")
    github_root = build.get("github_root")
    root_url = github_root.get("url") if isinstance(github_root, dict) else None
    root_number = (
        github_root.get("number") if isinstance(github_root, dict) else None
    )
    trusted_ref = publication.get("trusted_repository_ref")
    publication_receipt = publication.get("github_reconciliation")
    comment_matches = (
        publication_receipt.get("root_reconciliation_comment_matches")
        if isinstance(publication_receipt, dict) else None
    )
    root_comment_url = (
        comment_matches[0].get("url")
        if isinstance(comment_matches, list) and len(comment_matches) == 1
        and isinstance(comment_matches[0], dict)
        else None
    )
    if not isinstance(repository, str):
        report.error("validated receipt repository is unavailable")
    elif repository != trusted_repository:
        report.error(
            "validated receipt repository must equal configured GitHub origin "
            f"{trusted_repository}"
        )
    if not isinstance(root_id, str):
        report.error("validated receipt root ID is unavailable")
    elif not root_id.startswith(f"{trusted_repository}:"):
        report.error(
            "validated receipt root ID must use configured GitHub repository namespace"
        )
    if type(plan_version) is not int:
        report.error("validated receipt plan version is unavailable")
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("validated receipt approval commit is unavailable")
    elif not exact_commit(root, approved, "approved_planning_commit", report):
        pass
    if not isinstance(root_url, str):
        report.error("validated receipt root issue URL is unavailable")
    elif root_url != (
        f"https://github.com/{trusted_repository}/issues/{root_number}"
    ):
        report.error(
            "validated receipt root issue URL must use configured GitHub repository namespace"
        )
    if not valid_trusted_branch_ref(trusted_ref):
        report.error(
            "validated receipt trusted_repository_ref must be an exact "
            "refs/heads/... repository-owned branch ref"
        )
    if not isinstance(root_comment_url, str):
        report.error("validated receipt root reconciliation comment URL is unavailable")
    elif isinstance(root_url, str) and not re.fullmatch(
        re.escape(root_url) + r"#issuecomment-[1-9][0-9]*", root_comment_url
    ):
        report.error(
            "validated receipt root reconciliation comment URL must belong to "
            "the mapped root issue"
        )
    if report.errors:
        return None
    assert isinstance(repository, str)
    assert isinstance(root_id, str)
    assert type(plan_version) is int
    assert isinstance(approved, str)
    assert isinstance(root_url, str)
    assert isinstance(root_comment_url, str)
    assert isinstance(trusted_ref, str)
    return ReceiptAuthority(
        repository=trusted_repository,
        root_id=root_id,
        plan_version=plan_version,
        approved_commit=approved,
        root_issue_url=root_url,
        root_comment_url=root_comment_url,
        trusted_repository_ref=trusted_ref,
        receipt_manifests=manifests,
    )


def _require_remote_ref_containment(
    authority: ReceiptAuthority, receipt_commit: str,
    checker: RemoteRefContainmentChecker, report: Report,
) -> None:
    try:
        contains = checker(
            authority.repository,
            authority.trusted_repository_ref,
            authority.approved_commit,
            receipt_commit,
        )
    except Exception:
        contains = False
    if contains is not True:
        report.error(
            "receipt_commit must descend from approved_planning_commit and both "
            "must remain ancestors of configured GitHub repository branch "
            f"{authority.repository}:{authority.trusted_repository_ref}"
        )


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.errors.extend(
        f"receipt authority warning: {warning}" for warning in source.warnings
    )
