"""Live issue identity and authority checks, and relationship reconciliation."""

from __future__ import annotations

import json
from typing import Any

from publication_live_graph import MARKER, MARKER_NAME
from publication_rendering import MARKER_KEYS
from publication_client import PublicationError
from publication_context import IssueSpec


def validate_live_issue_identity(publisher, raw: Any, spec: IssueSpec) -> None:
    if not isinstance(raw, dict) or "pull_request" in raw:
        raise PublicationError(f"{spec.logical_id} did not resolve to an issue")
    if raw.get("state") != "open" or raw.get("locked") is not False:
        raise PublicationError(f"{spec.logical_id} must be open and unlocked")
    if type(raw.get("id")) is not int or raw["id"] < 1:
        raise PublicationError(f"{spec.logical_id} lacks numeric relationship identity")
    publisher._validate_live_issue_authority(raw, spec)


def validate_live_issue_authority(publisher, raw: dict[str, Any], spec: IssueSpec) -> None:
    """Prove the live issue carries this publication's planning marker.

    Numeric identity alone does not establish ownership: a durable
    pointer can name an unrelated issue (stale checkpoint, hand-edited
    manifest, recycled number).  Every mutation target must independently
    prove it belongs to this logical identity, plan version, and approved
    authority, using the same schema-2 marker contract the remote scan
    enforces in ``_canonical_mappings``.
    """
    body = raw.get("body")
    if body is not None and not isinstance(body, str):
        raise PublicationError(
            f"{spec.logical_id} returned a non-text body"
        )
    text = body or ""
    openings = text.count(f"<!-- {MARKER_NAME}")
    matches = list(MARKER.finditer(text))
    if openings != len(matches) or len(matches) != 1:
        raise PublicationError(
            f"{spec.logical_id} does not carry exactly one planning marker"
        )
    try:
        payload = json.loads(matches[0].group("payload"))
    except json.JSONDecodeError:
        raise PublicationError(
            f"{spec.logical_id} has a malformed planning marker"
        ) from None
    if not isinstance(payload, dict) or set(payload) != MARKER_KEYS:
        raise PublicationError(
            f"{spec.logical_id} has a malformed planning marker"
        )
    if (
        payload.get("logical_id") != spec.logical_id
        or payload.get("schema") != 2
        or payload.get("plan_version") != publisher.context.plan_version
        or not publisher._is_recorded_reapproval(payload)
    ):
        raise PublicationError(
            f"{spec.logical_id} resolved to an issue owned by different authority"
        )


def ensure_relationships(publisher, mappings: dict[str, dict[str, Any]]) -> None:
    root = mappings[publisher.context.root_id]
    member_ids = {key for key, spec in publisher.context.specs.items() if spec.kind == "ticket"}
    by_number = {
        value["number"]: (key, value["node_id"])
        for key, value in mappings.items()
    }
    observed_subissues: dict[str, set[str]] = {}
    observed_parents: dict[str, str | None] = {}
    observed_blockers: dict[str, set[str]] = {}
    expected_by_blocked: dict[str, set[str]] = {
        logical_id: set() for logical_id in mappings
    }
    for blocked, blocker in publisher.context.expected_edges:
        expected_by_blocked[blocked].add(blocker)

    # Complete the bounded conflict read before the first relationship
    # mutation.  A late unexpected parent/edge must not leave a partial
    # graph that the operator could have rejected up front.
    for logical_id in sorted(mappings):
        mapping = mappings[logical_id]
        parent = publisher._get(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}/parent",
            allow_404=True,
        )
        observed_parents[logical_id] = None if parent is None else publisher._relationship_id(
            parent, by_number, f"{logical_id} parent",
        )
        observed_subissues[logical_id] = publisher._relationship_ids(publisher._pages(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}"
            "/sub_issues?per_page=100"
        ), by_number, f"{logical_id} subissues")
        observed_blockers[logical_id] = publisher._relationship_ids(publisher._pages(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}"
            "/dependencies/blocked_by?per_page=100"
        ), by_number, f"{logical_id} blockers")

    for logical_id in sorted(mappings):
        expected_parent = publisher.context.root_id if logical_id in member_ids else None
        if observed_parents[logical_id] != expected_parent and observed_parents[logical_id] is not None:
            raise PublicationError(f"{logical_id} already has a different parent")
        expected_children = member_ids if logical_id == publisher.context.root_id else set()
        unexpected_children = (
            observed_subissues[logical_id] - expected_children
            - set(publisher._retired_mappings)
        )
        if unexpected_children:
            raise PublicationError(
                f"{logical_id} has unexpected existing subissues: "
                + ", ".join(sorted(unexpected_children))
            )
        unexpected = (
            observed_blockers[logical_id] - expected_by_blocked[logical_id]
            - set(publisher._retired_mappings)
        )
        if unexpected:
            raise PublicationError(
                f"{logical_id} has unexpected existing blockers: "
                + ", ".join(sorted(unexpected))
            )

    for logical_id in sorted(member_ids - observed_subissues[publisher.context.root_id]):
        publisher._mutate(
            "POST",
            f"repos/{publisher.context.repository}/issues/{root['number']}/sub_issues",
            {"sub_issue_id": publisher._database_id(mappings[logical_id])},
        )
    for logical_id in sorted(
        observed_subissues[publisher.context.root_id] & set(publisher._retired_mappings)
    ):
        publisher._mutate(
            "DELETE",
            f"repos/{publisher.context.repository}/issues/{root['number']}/sub_issues/"
            f"{publisher._retired_mappings[logical_id]['number']}",
            {},
        )
    for blocked in sorted(mappings):
        for blocker in sorted(expected_by_blocked[blocked] - observed_blockers[blocked]):
            publisher._mutate(
                "POST",
                f"repos/{publisher.context.repository}/issues/{mappings[blocked]['number']}"
                "/dependencies/blocked_by",
                {"issue_id": publisher._database_id(mappings[blocker])},
            )
        for blocker in sorted(observed_blockers[blocked] & set(publisher._retired_mappings)):
            publisher._mutate(
                "DELETE",
                f"repos/{publisher.context.repository}/issues/{mappings[blocked]['number']}"
                f"/dependencies/blocked_by/{publisher._retired_mappings[blocker]['number']}",
                {},
            )


def relationship_id(
    publisher, raw: Any, by_number: dict[int, tuple[str, str]], label: str,
) -> str:
    if not isinstance(raw, dict) or type(raw.get("number")) is not int:
        raise PublicationError(f"{label} returned invalid relationship identity")
    expected = by_number.get(raw["number"])
    if expected is None:
        expected = publisher._retired_by_number.get(raw["number"])
    if expected is None:
        raise PublicationError(f"{label} references an issue outside this publication")
    logical_id, expected_node = expected
    expected_url = (
        f"https://github.com/{publisher.context.repository}/issues/{raw['number']}"
    )
    if raw.get("html_url") != expected_url or "pull_request" in raw:
        raise PublicationError(
            f"{label} must resolve inside the trusted repository"
        )
    node = raw.get("node_id")
    if node is not None and node != expected_node:
        raise PublicationError(
            f"{label} returned a conflicting node identity"
        )
    return logical_id


def relationship_ids(
    publisher, raw: list[Any], by_number: dict[int, tuple[str, str]], label: str,
) -> set[str]:
    values = [publisher._relationship_id(item, by_number, label) for item in raw]
    if len(values) != len(set(values)):
        raise PublicationError(f"{label} returned duplicate relationships")
    return set(values)
