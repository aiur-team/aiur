"""Validate optional GitHub identities without treating guessed numbers as facts."""

from __future__ import annotations

from typing import Any

from validation_common import REPOSITORY, Report, nonempty_string, strict_int, strict_object
from validation_github_receipt import validate_reconciliation


GITHUB_KEYS = {"repository", "number", "node_id", "url"}


def validate_github_mapping(
    value: object,
    label: str,
    report: Report,
    *,
    expected_repository: str | None = None,
) -> dict[str, Any] | None:
    if value is None:
        return None
    mapping = strict_object(value, label, GITHUB_KEYS, report)
    if mapping is None:
        return None
    repository = mapping.get("repository")
    if not isinstance(repository, str) or not REPOSITORY.fullmatch(repository):
        report.error(f"{label}.repository must be owner/repo")
        repository = None
    elif expected_repository is not None and repository != expected_repository:
        report.error(f"{label}.repository must equal {expected_repository}")
    number = mapping.get("number")
    if not strict_int(number) or number < 1:
        report.error(f"{label}.number must be a positive integer")
    if not nonempty_string(mapping.get("node_id")):
        report.error(f"{label}.node_id must be a non-empty string")
    url = mapping.get("url")
    expected_url = None
    if repository is not None and strict_int(number) and number > 0:
        expected_url = f"https://github.com/{repository}/issues/{number}"
    if not nonempty_string(url):
        report.error(f"{label}.url must be a non-empty string")
    elif expected_url is not None and url != expected_url:
        report.error(f"{label}.url must equal {expected_url}")
    return mapping


def validate_all_github(
    data: dict[str, Any], by_id: dict[str, dict[str, Any]], report: Report,
    approved_body_expectations: dict[str, dict[str, Any]] | None = None,
) -> None:
    repository = data.get("repository") if isinstance(data.get("repository"), str) else None
    root = validate_github_mapping(
        data.get("github_root"), "github_root", report, expected_repository=repository
    )
    root_repository = root.get("repository") if root else None
    root_owner = root_repository.split("/", 1)[0] if isinstance(root_repository, str) else None
    identities: dict[tuple[str, object], str] = {}
    node_ids: dict[str, str] = {}
    mappings: list[tuple[str, dict[str, Any] | None]] = [("github_root", root)]
    ticket_mappings: dict[str, dict[str, Any] | None] = {}
    for ticket_id, ticket in by_id.items():
        mapping = validate_github_mapping(ticket.get("github"), f"{ticket_id}.github", report)
        ticket_mappings[ticket_id] = mapping
        mappings.append((ticket_id, mapping))
        if mapping is not None and root is None:
            report.error(f"{ticket_id}.github cannot be materialized without github_root")
        ticket_repo = mapping.get("repository") if mapping else None
        if root_owner and isinstance(ticket_repo, str) and ticket_repo.split("/", 1)[0] != root_owner:
            report.error(f"{ticket_id}.github must share the GitHub owner of github_root")
    for label, mapping in mappings:
        if mapping is None:
            continue
        repository = mapping.get("repository")
        number = mapping.get("number")
        if isinstance(repository, str) and strict_int(number):
            identity = (repository, number)
            if identity in identities:
                report.error(f"{label}.github duplicates issue identity used by {identities[identity]}")
            else:
                identities[identity] = label
        node_id = mapping.get("node_id")
        if nonempty_string(node_id) and node_id in node_ids:
            report.error(f"{label}.github duplicates node_id used by {node_ids[node_id]}")
        elif nonempty_string(node_id):
            node_ids[node_id] = label
    validate_reconciliation(
        data, by_id, root, ticket_mappings, report,
        approved_body_expectations,
    )
