"""Canonical and persisted issue mappings, with ownership validation."""

from __future__ import annotations

import json
from typing import Any

from publication_common import SHA
from publication_labels import routing_subset
from publication_live_graph import MARKER, MARKER_NAME
from publication_rendering import authority_preamble, MARKER_KEYS
from publication_client import PublicationError
from publication_context import IssueSpec


def scan_all(publisher) -> list[dict[str, Any]]:
    values = publisher._pages(
        f"repos/{publisher.context.repository}/issues?state=all&per_page=100"
    )
    seen_numbers: set[int] = set()
    seen_nodes: set[str] = set()
    output: list[dict[str, Any]] = []
    for raw in values:
        if not isinstance(raw, dict):
            raise PublicationError("all-state scan returned a non-object")
        number, node = raw.get("number"), raw.get("node_id")
        if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
            raise PublicationError("all-state scan returned invalid identity")
        if number in seen_numbers or node in seen_nodes:
            raise PublicationError("all-state scan returned duplicate identity")
        seen_numbers.add(number); seen_nodes.add(node)
        body = raw.get("body")
        if body is not None and not isinstance(body, str):
            raise PublicationError(f"issue/PR #{number} returned a non-text body")
        text = body or ""
        openings = text.count(f"<!-- {MARKER_NAME}")
        matches = list(MARKER.finditer(text))
        if openings != len(matches):
            raise PublicationError(f"malformed planning marker on issue/PR #{number}")
        payloads: list[dict[str, Any]] = []
        for match in matches:
            try:
                payload = json.loads(match.group("payload"))
            except json.JSONDecodeError:
                raise PublicationError(f"malformed planning marker JSON on issue/PR #{number}") from None
            if not isinstance(payload, dict) or set(payload) != MARKER_KEYS:
                raise PublicationError(f"malformed planning marker schema on issue/PR #{number}")
            payloads.append(payload)
        if len(payloads) > 1:
            raise PublicationError(
                f"issue/PR #{number} contains multiple planning markers"
            )
        copy = dict(raw); copy["_planning_markers"] = payloads
        output.append(copy)
    return output


def empty_reapproval() -> dict[str, list[str]]:
    return {
        "unchanged_members": [], "changed_members": [],
        "new_members": [], "removed_members": [],
    }


def authority_conflict(
    publisher, logical_id: str, observed: object, detail: str,
) -> PublicationError:
    return PublicationError(
        f"logical identity {logical_id} has conflicting authority: {detail}; "
        f"published approval {observed!r}; requested approval "
        f"{publisher.context.approved}. Options: re-approve the updated planning pack "
        "while retaining its canonical issue mapping, or resolve duplicate markers"
    )


def content_changed(publisher, raw: dict[str, Any], spec: IssueSpec, marker: dict[str, Any]) -> bool:
    """Ignore only the approval preamble when classifying a re-approval diff."""
    body = raw.get("body")
    approved = marker.get("approved_planning_commit")
    if not isinstance(body, str) or not isinstance(approved, str):
        return True
    old_preamble = authority_preamble(
        publisher.context.repository, spec.logical_id, publisher.context.plan_version, approved,
    )
    current_preamble = authority_preamble(
        publisher.context.repository, spec.logical_id, publisher.context.plan_version,
        publisher.context.approved,
    )
    normalized = body.replace(old_preamble, current_preamble, 1)
    return raw.get("title") != spec.title or normalized != spec.body


def is_recorded_reapproval(publisher, marker: dict[str, Any]) -> bool:
    """Accept only the prior receipt's approval as a re-approval source."""
    observed = marker.get("approved_planning_commit")
    prior = publisher.context.publication.get("approved_planning_commit")
    return observed == publisher.context.approved or (
        isinstance(prior, str) and observed == prior
    )


def canonical_mappings(publisher, scan: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    persisted = publisher._persisted_mappings()
    found: dict[str, list[dict[str, Any]]] = {key: [] for key in publisher.context.specs}
    retired: dict[str, list[dict[str, Any]]] = {}
    protected = {
        int(value.rsplit("#", 1)[-1].rsplit("/", 1)[-1])
        for value in (
            publisher.context.publication.get("read_only_issue_refs", [])
            or publisher.context.publication.get("reference_only_issue_urls", [])
        )
        if isinstance(value, str)
        and ("#" in value or "/issues/" in value)
    }
    for raw in scan:
        for marker in raw["_planning_markers"]:
            logical_id = marker.get("logical_id")
            if logical_id not in found:
                if (
                    isinstance(logical_id, str)
                    and marker.get("schema") == 2
                    and marker.get("plan_version") == publisher.context.plan_version
                    and publisher._is_recorded_reapproval(marker)
                ):
                    retired.setdefault(logical_id, []).append(raw)
                continue
            if "pull_request" in raw:
                raise PublicationError(f"logical identity {logical_id} collides with a pull request")
            if (
                marker.get("schema") != 2
                or marker.get("plan_version") != publisher.context.plan_version
            ):
                raise publisher._authority_conflict(
                    logical_id, marker.get("approved_planning_commit"),
                    "schema or plan version differs",
                )
            if not isinstance(marker.get("approved_planning_commit"), str) or not SHA.fullmatch(
                marker["approved_planning_commit"]
            ):
                raise publisher._authority_conflict(
                    logical_id, marker.get("approved_planning_commit"),
                    "published marker does not name an exact approval SHA",
                )
            if not publisher._is_recorded_reapproval(marker):
                raise publisher._authority_conflict(
                    logical_id, marker["approved_planning_commit"],
                    "published marker does not match the current or recorded prior approval",
                )
            found[logical_id].append(raw)
    mappings: dict[str, dict[str, Any]] = {}
    reapproval = publisher._empty_reapproval()
    for logical_id, matches in found.items():
        if len(matches) > 1:
            authorities = ", ".join(
                f"#{raw['number']} ({raw['_planning_markers'][0]['approved_planning_commit']})"
                for raw in matches
            )
            raise PublicationError(
                f"logical identity {logical_id} has multiple issue matches with conflicting authority across "
                f"published issues {authorities}; requested approval {publisher.context.approved}. "
                "Options: re-approve the updated planning pack while retaining one "
                "canonical issue mapping, or resolve duplicate markers"
            )
        if logical_id in persisted:
            persisted_mapping = persisted[logical_id]
            if matches and matches[0]["number"] != persisted_mapping["number"]:
                raise PublicationError(
                    f"logical identity {logical_id} conflicts with its persisted issue"
                )
            if persisted_mapping["number"] in protected:
                raise PublicationError(
                    f"logical identity {logical_id} reuses protected issue #{persisted_mapping['number']}"
                )
            mappings[logical_id] = persisted_mapping
            if matches:
                raw = matches[0]
                if publisher._content_changed(
                    raw, publisher.context.specs[logical_id], raw["_planning_markers"][0],
                ):
                    reapproval["changed_members"].append(logical_id)
                else:
                    reapproval["unchanged_members"].append(logical_id)
            else:
                reapproval["unchanged_members"].append(logical_id)
            continue
        if matches:
            raw = matches[0]
            if raw["number"] in protected:
                raise PublicationError(f"logical identity {logical_id} reuses protected issue #{raw['number']}")
            mappings[logical_id] = publisher._mapping(raw)
            if publisher._content_changed(raw, publisher.context.specs[logical_id], raw["_planning_markers"][0]):
                reapproval["changed_members"].append(logical_id)
            else:
                reapproval["unchanged_members"].append(logical_id)
        else:
            reapproval["new_members"].append(logical_id)
    publisher._retired_mappings = {}
    for logical_id, matches in retired.items():
        if len(matches) > 1:
            raise PublicationError(
                f"removed logical identity {logical_id} has multiple published issue matches; "
                "resolve duplicate markers without recreating published issues"
            )
        raw = matches[0]
        if "pull_request" in raw:
            raise PublicationError(f"removed logical identity {logical_id} collides with a pull request")
        publisher._retired_mappings[logical_id] = publisher._mapping(raw)
        reapproval["removed_members"].append(logical_id)
    publisher._retired_by_number = {
        mapping["number"]: (logical_id, mapping["node_id"])
        for logical_id, mapping in publisher._retired_mappings.items()
    }
    publisher._reapproval = {
        key: sorted(value) for key, value in reapproval.items()
    }
    numbers = [mapping["number"] for mapping in mappings.values()]
    nodes = [mapping["node_id"] for mapping in mappings.values()]
    if len(numbers) != len(set(numbers)) or len(nodes) != len(set(nodes)):
        raise PublicationError(
            "multiple logical identities resolve to the same issue"
        )
    return mappings


def persisted_mappings(publisher) -> dict[str, dict[str, Any]]:
    """Load durable pointers before trusting a remote marker scan.

    A scan can be stale or incomplete after a process crash.  A validated
    local pointer is therefore authoritative for that logical identity;
    the subsequent issue GET in ``_ensure_issue`` validates it against the
    approved body before any reconciliation mutation occurs.
    """
    candidates: dict[str, dict[str, Any]] = {}

    def add(logical_id: str, value: object, source: str) -> None:
        if value is None:
            return
        if not isinstance(value, dict) or set(value) != {
            "repository", "number", "node_id", "url",
        }:
            raise PublicationError(f"persisted mapping for {logical_id} is invalid ({source})")
        repository = value.get("repository")
        number = value.get("number")
        node = value.get("node_id")
        url = value.get("url")
        expected_url = f"https://github.com/{publisher.context.repository}/issues/{number}"
        if (
            repository != publisher.context.repository
            or type(number) is not int or number < 1
            or not isinstance(node, str) or not node
            or url != expected_url
        ):
            raise PublicationError(f"persisted mapping for {logical_id} is not canonical")
        mapping = {
            "repository": repository, "number": number,
            "node_id": node, "url": url,
        }
        previous = candidates.get(logical_id)
        if previous is not None and previous != mapping:
            raise PublicationError(
                f"persisted mappings disagree for logical identity {logical_id}"
            )
        candidates[logical_id] = mapping

    build = publisher.context.build
    add(publisher.context.root_id, build.get("github_root"), "build-order")
    for ticket in build.get("tickets", []):
        if isinstance(ticket, dict) and isinstance(ticket.get("id"), str):
            add(ticket["id"], ticket.get("github"), "build-order")
    reconciliation = publisher.context.publication.get("github_reconciliation")
    if reconciliation is not None and not isinstance(reconciliation, dict):
        raise PublicationError(
            "publication.github_reconciliation must be an object or null"
        )
    issue_mappings = (
        reconciliation.get("issue_mappings")
        if isinstance(reconciliation, dict) else None
    )
    if issue_mappings is not None:
        if not isinstance(issue_mappings, dict):
            raise PublicationError("persisted issue mappings are invalid")
        for logical_id, value in issue_mappings.items():
            if logical_id not in publisher.context.specs:
                raise PublicationError(
                    f"persisted mapping names unknown logical identity {logical_id}"
                )
            add(logical_id, value, "publication")
    numbers = [mapping["number"] for mapping in candidates.values()]
    nodes = [mapping["node_id"] for mapping in candidates.values()]
    if len(numbers) != len(set(numbers)) or len(nodes) != len(set(nodes)):
        raise PublicationError(
            "persisted mappings resolve to the same issue more than once"
        )
    return candidates


def validate_persisted_ownership(publisher) -> None:
    """Validate every durable pointer before any repository mutation."""
    for logical_id, mapping in sorted(publisher._persisted_mappings().items()):
        raw = publisher._get(
            f"repos/{publisher.context.repository}/issues/{mapping['number']}"
        )
        live_mapping = publisher._mapping(raw)
        if publisher._receipt_mapping(live_mapping) != mapping:
            raise PublicationError(
                f"{logical_id} persisted issue pointer does not own the resolved issue"
            )
        publisher._validate_live_issue_identity(raw, publisher.context.specs[logical_id])


def ensure_issue(
    publisher, spec: IssueSpec, mapping: dict[str, Any] | None,
) -> dict[str, Any]:
    base = f"repos/{publisher.context.repository}/issues"
    if mapping is None:
        created = publisher._mutate("POST", base, {
            "title": spec.title, "body": spec.body, "labels": list(spec.labels),
        })
        number = created.get("number") if isinstance(created, dict) else None
        if type(number) is not int:
            raise PublicationError(f"create response for {spec.logical_id} lacks issue number")
        # Record the successful create before any follow-up read or
        # reconciliation can fail.  The marker scan remains the remote
        # duplicate guard, while this checkpoint preserves the local
        # authority pointer across a crashed publication process.
        mapping = publisher._mapping(created)
        publisher._persist_mapping(spec.logical_id, mapping)
        number = mapping["number"]
    else:
        number = mapping["number"]
    raw = publisher._get(f"{base}/{number}")
    live_mapping = publisher._mapping(raw)
    if mapping is not None and publisher._receipt_mapping(live_mapping) != publisher._receipt_mapping(mapping):
        raise PublicationError(
            f"{spec.logical_id} persisted issue pointer does not own the resolved issue"
        )
    publisher._validate_live_issue_identity(raw, spec)
    labels = publisher._labels(raw)
    routing = routing_subset(set(labels))
    expected_routing = routing_subset(set(spec.labels))
    unexpected = sorted(routing - expected_routing)
    if unexpected:
        raise PublicationError(
            f"{spec.logical_id} has forbidden routing labels: " + ", ".join(unexpected)
        )
    patch: dict[str, Any] = {}
    if raw.get("title") != spec.title:
        patch["title"] = spec.title
    if raw.get("body") != spec.body:
        patch["body"] = spec.body
    missing = sorted(set(spec.labels) - set(labels))
    if patch:
        publisher._mutate("PATCH", f"{base}/{number}", patch)
    if missing:
        # The additive labels endpoint avoids a read/replace race that
        # could remove unrelated metadata added between GET and PATCH.
        publisher._mutate("POST", f"{base}/{number}/labels", {"labels": missing})
    if patch or missing:
        raw = publisher._get(f"{base}/{number}")
        publisher._validate_live_issue_identity(raw, spec)
        if raw.get("title") != spec.title or raw.get("body") != spec.body:
            raise PublicationError(f"{spec.logical_id} did not reconcile exact content")
        if not set(spec.labels).issubset(publisher._labels(raw)):
            raise PublicationError(f"{spec.logical_id} did not reconcile labels")
    return publisher._mapping(raw)


def persist_mapping(publisher, logical_id: str, mapping: dict[str, Any]) -> None:
    """Checkpoint one issue mapping so an interrupted loop is resumable."""
    receipt_mapping = publisher._receipt_mapping(mapping)
    build = json.loads(json.dumps(publisher.context.build))
    publication = json.loads(json.dumps(publisher.context.publication))
    if logical_id == publisher.context.root_id:
        build["github_root"] = receipt_mapping
    else:
        for ticket in build.get("tickets", []):
            if isinstance(ticket, dict) and ticket.get("id") == logical_id:
                ticket["github"] = receipt_mapping
                break
    if publisher.context.skill_id is not None and logical_id in {
        publisher.context.root_id, publisher.context.skill_id,
    }:
        reconciliation = publication.get("github_reconciliation")
        if reconciliation is None:
            reconciliation = {}
            publication["github_reconciliation"] = reconciliation
        elif not isinstance(reconciliation, dict):
            raise PublicationError(
                "publication.github_reconciliation must be an object or null"
            )
        issue_mappings = reconciliation.setdefault("issue_mappings", {})
        issue_mappings[logical_id] = receipt_mapping
    files = {
        publisher.context.build_path: json.dumps(build, indent=1) + "\n",
    }
    if publisher.context.skill_id is not None:
        files[publisher.context.publication_path] = json.dumps(publication, indent=2) + "\n"
    publisher._atomic_write_bundle(files)
    publisher.context.build = build
    if publisher.context.skill_id is not None:
        publisher.context.publication = publication
