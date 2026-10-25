"""Approved publication context: issue specs, edges and adapter extensions."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from publication_common import load_json, Report, SHA
from publication_rendering import render_approved_issue_content, repository_root
from validation_common import RUNNABLE_KINDS
from validation_github_approved import render_approved_build_order
from validation_github_rendering import inspect_issue_body, render_template_body
from validation_git_approved_source import approved_text
from publication_client import PublicationError
from publication_materialize import recover_materialization_transaction


CREATABLE_LABELS = {
    "build-order": ("5319e7", "Build Order planning root"),
    "build-lane:plan-graph": ("bfdadc", "Build Order lane: plan graph"),
    "build-lane:runtime": ("bfdadc", "Build Order lane: runtime"),
    "build-lane:dashboard-ui": ("bfdadc", "Build Order lane: dashboard UI"),
    "build-lane:accounting": ("bfdadc", "Build Order lane: accounting"),
    "build-lane:platform": ("bfdadc", "Build Order lane: platform"),
    "phase:7": ("d4c5f9", "Build Order phase 7"),
    "phase:8": ("d4c5f9", "Build Order phase 8"),
}


@dataclass(frozen=True)
class IssueSpec:
    logical_id: str
    title: str
    body: str
    labels: tuple[str, ...]
    kind: str


@dataclass
class Context:
    root: Path
    build_path: Path
    publication_path: Path
    discovery_path: Path
    approved: str
    authority: str
    repository: str
    trusted_ref: str
    plan_version: int
    root_id: str
    skill_id: str | None
    build: dict[str, Any]
    publication: dict[str, Any]
    specs: dict[str, IssueSpec]
    approved_evidence: dict[str, dict[str, Any]]
    expected_edges: set[tuple[str, str]]
    core_edges: set[tuple[str, str]]
    creatable_labels: dict[str, tuple[str, str]]
    reconciliation_comment: bool
    root_document: Path
    additional_document: Path | None
    extra_validator: Path | None


def build_context(
    build_path: Path, publication_path: Path, approved: str, authority: str,
    extension: dict[str, Any] | None = None,
) -> Context:
    if not SHA.fullmatch(approved) or not SHA.fullmatch(authority):
        raise PublicationError("approval and green authority must be exact 40-character SHAs")
    report = Report()
    root = repository_root(build_path, report)
    build = load_json(build_path, "build-order", report)
    publication = load_json(publication_path, "publication", report)
    if root is None or build is None or publication is None:
        raise PublicationError("; ".join(report.errors))
    if recover_materialization_transaction(root):
        build = load_json(build_path, "build-order", report)
        publication = load_json(publication_path, "publication", report)
        if build is None or publication is None:
            raise PublicationError("; ".join(report.errors))
    repository, plan_version, root_id = (
        build.get("repository"), build.get("plan_version"), build.get("build_order_id")
    )
    trusted_ref = publication.get("trusted_repository_ref")
    if not all(
        isinstance(value, str) and value
        for value in (repository, root_id, trusted_ref)
    ) or type(plan_version) is not int:
        raise PublicationError("publication identity fields are invalid")
    slug = root_id.removeprefix(f"{repository}:")
    if root_id == slug or not slug or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in slug):
        raise PublicationError("build_order_id must be repository:feature-slug")
    mutation_repositories = publication.get("mutation_repositories")
    if mutation_repositories is not None and (
        not isinstance(mutation_repositories, list)
        or repository not in mutation_repositories
    ):
        raise PublicationError(
            "canonical repository must be explicitly authorized for mutation"
        )
    try:
        build_relative = build_path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        raise PublicationError("build-order manifest must remain inside the repository") from None
    extension = dict(extension or {})
    if not extension and isinstance(publication.get("skill_issue"), dict):
        extension = {
            "additional_issue": {
                "manifest_key": "skill_issue", "labels": ["human:todo"],
            },
            "external_edges_field": "external_blocker_relations",
            "feature_title_prefix": "BO:",
            "additional_title_must_be_unprefixed": True,
            "reconciliation_comment": True,
            "creatable_labels": CREATABLE_LABELS,
            "extra_validator": "scripts/validate_publication.py",
        }
    root_document_value = publication.get("root_document")
    if not isinstance(root_document_value, str):
        root_manifest = publication.get("root_issue")
        root_relative = root_manifest.get("document") if isinstance(root_manifest, dict) else None
        if not isinstance(root_relative, str):
            raise PublicationError("publication root document is unavailable")
        root_document_value = (
            build_path.parent / root_relative
        ).resolve().relative_to(root.resolve()).as_posix()
    if isinstance(extension.get("additional_issue"), dict):
        rendered = render_approved_issue_content(
            build_path, publication_path, approved.lower(), report,
        )
        if rendered is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        titles, bodies, evidence = rendered
    else:
        expectations = render_approved_build_order(
            root, approved.lower(), build_relative, root_document_value,
            build, report,
        )
        if (
            expectations is None or expectations.rendered_bodies is None
            or report.errors
        ):
            raise PublicationError("; ".join(report.errors))
        titles = expectations.titles
        bodies = expectations.rendered_bodies
        evidence = dict(expectations.bodies)
    feature_prefix = extension.get("feature_title_prefix")
    feature_ids = {
        root_id,
        *(
            item.get("id") for item in build.get("tickets", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ),
    }
    if isinstance(feature_prefix, str) and any(
        not titles.get(logical_id, "").startswith(feature_prefix)
        for logical_id in feature_ids
    ):
        raise PublicationError(
            f"every feature issue title must start with {feature_prefix}"
        )
    tickets = build.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        raise PublicationError("operator requires a non-empty reviewed ticket manifest")
    projection = build.get("label_projection")
    if not isinstance(projection, dict):
        raise PublicationError("label projection is unavailable")
    root_label = projection.get("build_order")
    if not isinstance(root_label, str) or not root_label:
        raise PublicationError("label projection build_order is unavailable")
    specs: dict[str, IssueSpec] = {
        root_id: IssueSpec(
            root_id, titles[root_id], bodies[root_id], (root_label,), "root",
        ),
    }
    core_edges: set[tuple[str, str]] = set()
    for ticket in tickets:
        if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
            raise PublicationError("ticket manifest entry is invalid")
        logical_id = ticket["id"]
        labels: tuple[str, ...] = ()
        if ticket.get("kind") in RUNNABLE_KINDS:
            try:
                labels = (
                    *projection["required_ticket_labels"],
                    projection["workstreams"][ticket["workstream"]],
                    projection["phases"][str(ticket["phase_hint"])],
                    projection["complexities"][str(ticket["complexity_points"])],
                )
            except (KeyError, TypeError):
                raise PublicationError(
                    f"ticket label projection is invalid for {logical_id}"
                ) from None
        specs[logical_id] = IssueSpec(
            logical_id, titles[logical_id], bodies[logical_id], tuple(sorted(labels)), "ticket",
        )
        dependencies = ticket.get("depends_on")
        if not isinstance(dependencies, list):
            raise PublicationError(f"ticket dependencies are invalid for {logical_id}")
        core_edges.update((logical_id, blocker) for blocker in dependencies)

    skill_id = None
    additional_document = None
    additional = extension.get("additional_issue")
    if isinstance(additional, dict):
        manifest_key = additional.get("manifest_key")
        raw_issue = publication.get(manifest_key) if isinstance(manifest_key, str) else None
        if not isinstance(raw_issue, dict):
            raise PublicationError("declared additional issue manifest is unavailable")
        skill_id = raw_issue.get("logical_id")
        document = raw_issue.get("document")
        labels = additional.get("labels")
        if (
            not isinstance(skill_id, str) or not isinstance(document, str)
            or not isinstance(labels, list)
            or not all(isinstance(item, str) and item for item in labels)
        ):
            raise PublicationError("declared additional issue is invalid")
        additional_relative = (
            build_path.parent / document
        ).resolve().relative_to(root.resolve()).as_posix()
        source = approved_text(
            root, approved.lower(), additional_relative,
            f"approved {skill_id} document", report,
        )
        if source is None:
            raise PublicationError("; ".join(report.errors))
        lines = source.splitlines()
        title = lines[0][2:].strip() if lines and lines[0].startswith("# ") else ""
        body = render_template_body(
            source, repository, skill_id, plan_version, approved.lower(),
            report, f"approved {skill_id} document",
        )
        if not title or body is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        if extension.get("additional_title_must_be_unprefixed") and (
            isinstance(feature_prefix, str) and title.startswith(feature_prefix)
        ):
            raise PublicationError(
                "the declared additional issue title must remain unprefixed"
            )
        additional_evidence = inspect_issue_body(
            body, repository, skill_id, plan_version, approved.lower(), report,
            f"approved {skill_id} body",
        )
        if additional_evidence is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        specs[skill_id] = IssueSpec(
            skill_id, title, body, tuple(sorted(labels)), "skill",
        )
        evidence[skill_id] = additional_evidence
        additional_document = root / additional_relative

    edges = set(core_edges)
    external_field = extension.get("external_edges_field")
    if isinstance(external_field, str):
        relations = publication.get(external_field)
        if not isinstance(relations, list):
            raise PublicationError("declared external blocker relations are invalid")
        for relation in relations:
            if not isinstance(relation, dict):
                raise PublicationError("external blocker relation is invalid")
            edges.add((
                relation.get("blocked_ticket_id"),
                relation.get("blocker_issue_id"),
            ))
    if any(blocked not in specs or blocker not in specs for blocked, blocker in edges):
        raise PublicationError("publication edge references an unknown logical identity")
    creatable = extension.get("creatable_labels", {})
    if not isinstance(creatable, dict) or any(
        not isinstance(value, (list, tuple)) or len(value) != 2
        or not all(isinstance(item, str) for item in value)
        for value in creatable.values()
    ):
        raise PublicationError("declared creatable label policy is invalid")
    extra_validator = extension.get("extra_validator")
    validator_path = (
        build_path.parent / extra_validator
        if isinstance(extra_validator, str) else None
    )
    return Context(
        root=root, build_path=build_path, publication_path=publication_path,
        discovery_path=root / ".aiur" / "build_orders" / f"{slug}.json",
        approved=approved.lower(), authority=authority.lower(),
        repository=repository, trusted_ref=trusted_ref, plan_version=plan_version,
        root_id=root_id, skill_id=skill_id, build=build, publication=publication,
        specs=specs, approved_evidence=evidence, expected_edges=edges,
        core_edges=core_edges,
        creatable_labels={
            key: (value[0], value[1]) for key, value in creatable.items()
        },
        reconciliation_comment=bool(extension.get("reconciliation_comment")),
        root_document=root / root_document_value,
        additional_document=additional_document,
        extra_validator=validator_path,
    )
