"""Root reconciliation comment state and fresh receipt evidence."""

from __future__ import annotations

import hashlib
from typing import Any

from publication_comment import (
    COMMENT_MARKER,
    inspect_comment,
    render_pending_comment,
    render_successful_comment,
)
from publication_common import Report, SHA
from publication_labels import routing_subset
from publication_receipt_authority import ReceiptAuthority
from publication_client import PublicationError


def reconciliation_comment_states(
    publisher, authority: ReceiptAuthority, receipt_commit: str,
    receipt_url: str,
) -> dict[str, str]:
    root_number = authority.root_issue_url.rsplit("/", 1)[-1]
    raw_comments = publisher._pages(
        f"repos/{authority.repository}/issues/{root_number}/comments?per_page=100"
    )
    found: dict[str, list[str]] = {"pending": [], "successful": []}
    for raw in raw_comments:
        body = raw.get("body") if isinstance(raw, dict) else None
        if not isinstance(body, str):
            raise PublicationError("root comment scan returned invalid content")
        if f"<!-- {COMMENT_MARKER}" not in body:
            continue
        state = publisher._canonical_comment_state(
            raw, authority, receipt_commit, receipt_url,
        )
        if state is None:
            raise PublicationError(
                "root issue contains malformed or conflicting reconciliation evidence"
            )
        found[state].append(raw["html_url"])
    if found["pending"] != [authority.root_comment_url]:
        raise PublicationError(
            "root issue must preserve exactly one receipt-bound pending comment"
        )
    if len(found["successful"]) > 1:
        raise PublicationError(
            "root issue contains duplicate successful reconciliation evidence"
        )
    return {
        "pending": found["pending"][0],
        **({"successful": found["successful"][0]} if found["successful"] else {}),
    }


def canonical_comment_state(
    publisher, raw: Any, authority: ReceiptAuthority, receipt_commit: str,
    receipt_url: str,
) -> str | None:
    if not isinstance(raw, dict):
        return None
    comment_url = raw.get("html_url")
    prefix = f"{authority.root_issue_url}#issuecomment-"
    comment_id = comment_url.removeprefix(prefix) if isinstance(comment_url, str) else ""
    if (
        not isinstance(comment_url, str) or not comment_url.startswith(prefix)
        or not comment_id.isdigit() or comment_id.startswith("0")
    ):
        return None
    body = raw.get("body")
    for state, commit, url, canonical_body in (
        (
            "successful", receipt_commit, receipt_url,
            render_successful_comment(
                authority.root_id, authority.plan_version,
                authority.approved_commit, authority.repository,
                receipt_commit, receipt_url,
            ),
        ),
        (
            "pending", None, None,
            render_pending_comment(
                authority.root_id, authority.plan_version,
                authority.approved_commit, authority.repository,
            ),
        ),
    ):
        if body != canonical_body:
            continue
        if state == "pending" and comment_url != authority.root_comment_url:
            continue
        if state == "successful" and comment_url == authority.root_comment_url:
            continue
        report = Report()
        if inspect_comment(
            body, comment_url, authority.root_id,
            authority.plan_version, authority.approved_commit, state,
            commit, url, authority.repository,
            f"receipt-bound {state} comment", report,
        ) is not None and not report.errors:
            return state
    return None


def ensure_pending_comment(publisher, root: dict[str, Any]) -> dict[str, Any]:
    body = render_pending_comment(
        publisher.context.root_id, publisher.context.plan_version,
        publisher.context.approved, publisher.context.repository,
    )
    comments = publisher._pages(
        f"repos/{publisher.context.repository}/issues/{root['number']}/comments?per_page=100"
    )
    matches = [
        item for item in comments if isinstance(item, dict)
        and isinstance(item.get("body"), str)
        and f"<!-- {COMMENT_MARKER}" in item["body"]
    ]
    current: list[dict[str, Any]] = []
    prior_matches: list[dict[str, Any]] = []
    prior = publisher.context.publication.get("approved_planning_commit")
    prior_body = (
        render_pending_comment(
            publisher.context.root_id, publisher.context.plan_version, prior,
            publisher.context.repository,
        )
        if isinstance(prior, str) and SHA.fullmatch(prior) and prior != publisher.context.approved
        else None
    )
    for comment in matches:
        if comment.get("body") == body:
            current.append(comment)
            continue
        if comment.get("body") == prior_body:
            prior_matches.append(comment)
            continue
        raise PublicationError(
            "existing reconciliation comment is malformed or not canonical pending"
        )
    if len(current) > 1:
        raise PublicationError("root has multiple reconciliation comments")
    if len(prior_matches) > 1:
        raise PublicationError("root has multiple reconciliation comments")
    if current:
        if prior_matches:
            raise PublicationError("root has multiple reconciliation comments")
        comment = current[0]
        report = Report()
        evidence = inspect_comment(
            comment.get("body"), comment.get("html_url"), publisher.context.root_id,
            publisher.context.plan_version, publisher.context.approved, "pending", None,
            None, publisher.context.repository, "pending root comment", report,
        )
        if evidence is None or comment.get("body") != body:
            raise PublicationError(
                "existing reconciliation comment is malformed or not canonical pending"
            )
        return comment
    if prior_matches:
        comment = prior_matches[0]
        comment_id = comment.get("id")
        if type(comment_id) is not int:
            raise PublicationError("prior reconciliation comment lacks numeric identity")
        publisher._mutate(
            "PATCH", f"repos/{publisher.context.repository}/issues/comments/{comment_id}",
            {"body": body},
        )
        return publisher._get(
            f"repos/{publisher.context.repository}/issues/comments/{comment_id}"
        )
    created = publisher._mutate(
        "POST", f"repos/{publisher.context.repository}/issues/{root['number']}/comments",
        {"body": body},
    )
    comment_id = created.get("id") if isinstance(created, dict) else None
    if type(comment_id) is not int:
        raise PublicationError("created reconciliation comment lacks numeric identity")
    return publisher._get(
        f"repos/{publisher.context.repository}/issues/comments/{comment_id}"
    )


def fresh_evidence(
    publisher, mappings: dict[str, dict[str, Any]], comment: dict[str, Any] | None,
) -> dict[str, Any]:
    scan = publisher._scan_all()
    fresh_mappings = publisher._canonical_mappings(scan)
    if set(fresh_mappings) != set(publisher.context.specs):
        raise PublicationError(
            "fresh marker scan does not exactly cover every planned identity"
        )
    marker_matches = {key: [fresh_mappings[key]] for key in fresh_mappings}
    issues: dict[str, dict[str, Any]] = {}
    by_number = {
        value["number"]: (key, value["node_id"])
        for key, value in fresh_mappings.items()
    }
    for logical_id, mapping in sorted(fresh_mappings.items()):
        spec = publisher.context.specs[logical_id]
        raw = publisher._get(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}"
        )
        publisher._validate_live_issue_identity(raw, spec)
        labels = publisher._labels(raw)
        if routing_subset(set(labels)) != routing_subset(set(spec.labels)):
            raise PublicationError(f"fresh labels differ from projection for {logical_id}")
        parent_raw = publisher._get(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}/parent",
            allow_404=True,
        )
        parent = None if parent_raw is None else publisher._relationship_id(parent_raw, by_number, f"{logical_id} parent")
        subissues = publisher._relationship_ids(publisher._pages(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}/sub_issues?per_page=100"
        ), by_number, f"{logical_id} subissues")
        blockers = publisher._relationship_ids(publisher._pages(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}/dependencies/blocked_by?per_page=100"
        ), by_number, f"{logical_id} blockers")
        expected_parent = publisher.context.root_id if spec.kind == "ticket" else None
        expected_subissues = {
            key for key, candidate in publisher.context.specs.items() if candidate.kind == "ticket"
        } if logical_id == publisher.context.root_id else set()
        expected_blockers = {blocker for blocked, blocker in publisher.context.expected_edges if blocked == logical_id}
        if parent != expected_parent or subissues != expected_subissues or blockers != expected_blockers:
            raise PublicationError(f"fresh relationship evidence differs for {logical_id}")
        body = raw.get("body")
        if raw.get("title") != spec.title or body != spec.body:
            raise PublicationError(f"fresh content evidence differs for {logical_id}")
        issues[logical_id] = {
            "mapping": publisher._mapping(raw), "labels": labels,
            "title": raw["title"], "state": raw["state"].upper(),
            "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
            "parent": parent,
        }
    comment_evidence = None
    if comment is not None:
        fresh_comment = publisher._get(
            f"repos/{publisher.context.repository}/issues/comments/{comment['id']}"
        )
        report = Report()
        comment_evidence = inspect_comment(
            fresh_comment.get("body") if isinstance(fresh_comment, dict) else None,
            fresh_comment.get("html_url") if isinstance(fresh_comment, dict) else None,
            publisher.context.root_id, publisher.context.plan_version, publisher.context.approved,
            "pending", None, None, publisher.context.repository,
            "fresh pending root comment", report,
        )
        if comment_evidence is None:
            raise PublicationError(
                "fresh pending comment evidence is invalid: "
                + "; ".join(report.errors)
            )
        comments = publisher._pages(
            f"repos/{publisher.context.repository}/issues/"
            f"{fresh_mappings[publisher.context.root_id]['number']}"
            "/comments?per_page=100"
        )
        marker_urls = [
            value.get("html_url") for value in comments
            if isinstance(value, dict) and isinstance(value.get("body"), str)
            and f"<!-- {COMMENT_MARKER}" in value["body"]
        ]
        if marker_urls != [comment_evidence["url"]]:
            raise PublicationError(
                "fresh root comment scan must find exactly one pending marker"
            )
    return {
        "issues": issues, "marker_matches": marker_matches,
        "comment": comment_evidence,
    }
