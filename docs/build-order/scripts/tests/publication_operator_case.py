"""Shared publisher fixtures: context, fake client and canned GitHub responses."""

from __future__ import annotations

import copy
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
for _path in (SCRIPT_DIR, SKILL_PUBLICATION, Path(__file__).resolve().parent):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from publication_operator import Context, CREATABLE_LABELS, IssueSpec, Publisher
from publication_rendering import authority_preamble


APPROVED = "a" * 40
AUTHORITY = "b" * 40
RECEIPT = "c" * 40
REPOSITORY = "example/repo"
ROOT = "example/repo:build-order-dashboard"
SKILL = "SKILL-DELIVERY-001"


def issue(number: int, logical_id: str, *, pull: bool = False) -> dict[str, Any]:
    body = authority_preamble(REPOSITORY, logical_id, 1, APPROVED) + "# Body\n"
    value = {
        "id": number + 10_000,
        "number": number,
        "node_id": f"NODE_{number}",
        "html_url": f"https://github.com/{REPOSITORY}/issues/{number}",
        "title": logical_id,
        "body": body,
        "state": "open",
        "locked": False,
        "labels": [],
    }
    if pull:
        value["pull_request"] = {}
        value["html_url"] = f"https://github.com/{REPOSITORY}/pull/{number}"
    return value


def context(tmp: Path) -> Context:
    specs = {
        ROOT: IssueSpec(ROOT, ROOT, issue(1, ROOT)["body"], ("build-order",), "root"),
        SKILL: IssueSpec(SKILL, SKILL, issue(2, SKILL)["body"], ("human:todo",), "skill"),
    }
    tickets = []
    for index in range(1, 55):
        logical_id = f"T-{index:03d}"
        specs[logical_id] = IssueSpec(
            logical_id, logical_id, issue(index + 2, logical_id)["body"],
            ("model:codex-gpt-5.6-terra", "build-lane:runtime", "phase:1", "complexity:2"),
            "ticket",
        )
        tickets.append({"id": logical_id, "github": None, "depends_on": []})
    # The production guard expects 107 unique blocker edges.  The exact graph
    # shape is irrelevant to collision/read tests, but the count remains real.
    ids = [item["id"] for item in tickets]
    edges = {(ids[index], ids[prior]) for index in range(54) for prior in range(index)}
    edges = set(sorted(edges)[:105]) | {(ids[0], SKILL), (ids[1], SKILL)}
    build = {
        "repository": REPOSITORY, "plan_version": 1, "build_order_id": ROOT,
        "tickets": tickets, "github_root": None, "github_reconciliation": None,
    }
    publication = {
        "repository": REPOSITORY, "plan_version": 1,
        "approved_planning_commit": None,
        "trusted_repository_ref": "refs/heads/build-order-research",
        "read_only_issue_refs": [f"{REPOSITORY}#999"],
        "external_blocker_relations": [
            {"blocked_ticket_id": ids[0], "blocker_issue_id": SKILL},
            {"blocked_ticket_id": ids[1], "blocker_issue_id": SKILL},
        ],
        "github_reconciliation": None,
    }
    evidence = {
        key: {"body_sha256": "0" * 64} for key in specs
    }
    return Context(
        root=tmp, build_path=tmp / "build-order.json",
        publication_path=tmp / "publication.json",
        discovery_path=tmp / ".aiur/build_orders/example.json", approved=APPROVED,
        authority=AUTHORITY, repository=REPOSITORY,
        trusted_ref="refs/heads/build-order-research", plan_version=1,
        root_id=ROOT, skill_id=SKILL, build=build, publication=publication,
        specs=specs, approved_evidence=evidence, expected_edges=edges,
        core_edges={edge for edge in edges if edge[1] != SKILL},
        creatable_labels=CREATABLE_LABELS,
        reconciliation_comment=True,
        root_document=tmp / "root-issue.md",
        additional_document=tmp / "skill-delivery.md",
        extra_validator=None,
    )


class FakeClient:
    def __init__(self, responses: dict[tuple[str, str], Any]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, str, Any]] = []

    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None,
        *, allow_404: bool = False,
    ) -> Any:
        self.calls.append((method, path, payload))
        key = (method, path)
        if key not in self.responses:
            if allow_404:
                return None
            raise AssertionError(f"unexpected request: {key}")
        value = self.responses[key]
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)


class AuthorityFreePublisher(Publisher):
    def _check_authority(self, expected_tip: str | None = "configured") -> None:
        return None


class ValidationFreePublisher(AuthorityFreePublisher):
    def _run_validators(self) -> None:
        return None


def labels_response(ctx: Context, *, omit: set[str] | None = None) -> list[dict[str, str]]:
    required = {label for spec in ctx.specs.values() for label in spec.labels}
    return [{"name": value} for value in sorted(required - (omit or set()))]


def dry_responses(ctx: Context, issues: list[dict[str, Any]], labels: list[Any] | None = None) -> dict[tuple[str, str], Any]:
    base = f"repos/{REPOSITORY}"
    return {
        ("GET", f"{base}/labels?per_page=100&page=1"): labels if labels is not None else labels_response(ctx),
        ("GET", f"{base}/issues?state=all&per_page=100&page=1"): issues,
    }


def relationship_responses(
    ctx: Context, mappings: dict[str, dict[str, Any]],
) -> dict[tuple[str, str], Any]:
    def relation(logical_id: str) -> dict[str, Any]:
        mapping = mappings[logical_id]
        return {
            "number": mapping["number"],
            "node_id": mapping["node_id"],
            "html_url": (
                f"https://github.com/{REPOSITORY}/issues/{mapping['number']}"
            ),
        }

    responses: dict[tuple[str, str], Any] = {}
    root_number = mappings[ROOT]["number"]
    for key, mapping in mappings.items():
        number = mapping["number"]
        if ctx.specs[key].kind == "ticket":
            responses[("GET", f"repos/{REPOSITORY}/issues/{number}/parent")] = relation(ROOT)
        responses[("GET", f"repos/{REPOSITORY}/issues/{number}/sub_issues?per_page=100&page=1")] = (
            [relation(candidate) for candidate in mappings if ctx.specs[candidate].kind == "ticket"]
            if key == ROOT else []
        )
        responses[("GET", f"repos/{REPOSITORY}/issues/{number}/dependencies/blocked_by?per_page=100&page=1")] = [
            relation(blocker)
            for blocked, blocker in ctx.expected_edges if blocked == key
        ]
    return responses
