from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
for path in (SCRIPTS, SKILL_PUBLICATION):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from publication_operator import (  # noqa: E402
    AUTHORITY_CHECKPOINT_MUTATIONS,
    CREATABLE_LABELS,
    Client,
    Context,
    GhClient,
    IssueSpec,
    PublicationError,
    Publisher,
    build_context,
)
from publication_comment import (  # noqa: E402
    render_pending_comment,
    render_successful_comment,
)
from publication_receipt_authority import ReceiptAuthority  # noqa: E402
from publication_rendering import authority_preamble  # noqa: E402


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
        publication_path=tmp / "publication.json", approved=APPROVED,
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


class DryRunTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.ctx = context(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_default_plan_is_read_only_and_counts_resume_matches(self) -> None:
        existing = [issue(1, ROOT), issue(2, SKILL)]
        client = FakeClient(dry_responses(self.ctx, existing))
        result = AuthorityFreePublisher(client, self.ctx).dry_run()
        self.assertEqual(result["canonical_issues_found"], 2)
        self.assertEqual(result["issues_to_create"], 54)
        self.assertEqual(result["mutations"], 0)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_dry_run_reports_only_allowlisted_missing_labels(self) -> None:
        omitted = {"build-order"}
        client = FakeClient(dry_responses(
            self.ctx, [], labels_response(self.ctx, omit=omitted),
        ))
        result = AuthorityFreePublisher(client, self.ctx).dry_run()
        self.assertEqual(result["labels_to_create"], ["build-order"])

    def test_missing_non_creatable_label_fails_closed(self) -> None:
        omitted = {"model:codex-gpt-5.6-terra"}
        client = FakeClient(dry_responses(
            self.ctx, [], labels_response(self.ctx, omit=omitted),
        ))
        with self.assertRaisesRegex(PublicationError, "will not be invented"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_pull_request_marker_collision_fails(self) -> None:
        client = FakeClient(dry_responses(self.ctx, [issue(8, ROOT, pull=True)]))
        with self.assertRaisesRegex(PublicationError, "pull request"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_closed_issue_marker_collision_is_not_hidden(self) -> None:
        raw = issue(8, ROOT); raw["state"] = "closed"
        client = FakeClient(dry_responses(self.ctx, [raw]))
        result = AuthorityFreePublisher(client, self.ctx).dry_run()
        self.assertEqual(result["canonical_issues_found"], 1)

    def test_wrong_approval_marker_fails(self) -> None:
        raw = issue(8, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "c" * 40)
        client = FakeClient(dry_responses(self.ctx, [raw]))
        with self.assertRaisesRegex(PublicationError, "conflicting authority"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_duplicate_logical_marker_matches_fail(self) -> None:
        client = FakeClient(dry_responses(self.ctx, [issue(8, ROOT), issue(9, ROOT)]))
        with self.assertRaisesRegex(PublicationError, "multiple issue matches"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_two_logical_markers_on_one_issue_fail_before_mutation(self) -> None:
        raw = issue(8, ROOT)
        raw["body"] += issue(9, SKILL)["body"].split("# Body\n", 1)[0]
        client = FakeClient(dry_responses(self.ctx, [raw]))
        with self.assertRaisesRegex(PublicationError, "multiple planning markers"):
            AuthorityFreePublisher(client, self.ctx).dry_run()
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_duplicate_node_across_logical_mappings_fails(self) -> None:
        first, second = issue(8, ROOT), issue(9, SKILL)
        second["node_id"] = first["node_id"]
        first["_planning_markers"] = [{
            "schema": 2,
            "logical_id": ROOT,
            "plan_version": 1,
            "approved_planning_commit": APPROVED,
        }]
        second["_planning_markers"] = [{
            "schema": 2,
            "logical_id": SKILL,
            "plan_version": 1,
            "approved_planning_commit": APPROVED,
        }]
        with self.assertRaisesRegex(PublicationError, "same issue"):
            AuthorityFreePublisher(FakeClient({}), self.ctx)._canonical_mappings(
                [first, second]
            )

    def test_malformed_marker_opening_fails(self) -> None:
        raw = issue(8, "unrelated")
        raw["body"] = "<!-- aiur-planning-issue\nnot json\n-->"
        client = FakeClient(dry_responses(self.ctx, [raw]))
        with self.assertRaisesRegex(PublicationError, "malformed planning marker JSON"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_protected_issue_cannot_be_reused(self) -> None:
        raw = issue(999, ROOT)
        client = FakeClient(dry_responses(self.ctx, [raw]))
        with self.assertRaisesRegex(PublicationError, "protected issue"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_duplicate_scan_identity_fails(self) -> None:
        first, second = issue(8, "unrelated"), issue(8, "another")
        client = FakeClient(dry_responses(self.ctx, [first, second]))
        with self.assertRaisesRegex(PublicationError, "duplicate identity"):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_pagination_is_finite(self) -> None:
        responses = dry_responses(self.ctx, [])
        base = f"repos/{REPOSITORY}/labels?per_page=100"
        hundred = [{"name": f"x-{index}"} for index in range(100)]
        for page in range(1, 101):
            responses[("GET", f"{base}&page={page}")] = hundred
        client = FakeClient(responses)
        with self.assertRaisesRegex(PublicationError, "pagination exceeds"):
            AuthorityFreePublisher(client, self.ctx)._pages(base)


class ReconciliationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.ctx = context(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_existing_issue_is_repaired_without_removing_unrelated_label(self) -> None:
        spec = self.ctx.specs[ROOT]
        raw = issue(11, ROOT)
        raw.update({"title": "drift", "body": spec.body, "labels": [{"name": "keep-me"}]})
        repaired = copy.deepcopy(raw)
        repaired.update({"title": spec.title, "labels": [{"name": "keep-me"}, {"name": "build-order"}]})
        base = f"repos/{REPOSITORY}/issues/11"
        class RepairClient(FakeClient):
            count = 0
            def request(inner, method: str, path: str, payload=None, *, allow_404=False):
                inner.calls.append((method, path, payload))
                if method == "GET":
                    inner.count += 1
                    return copy.deepcopy(raw if inner.count == 1 else repaired)
                if method == "POST":
                    self.assertEqual(payload["labels"], ["build-order"])
                return {}
        client = RepairClient({})
        mapping = AuthorityFreePublisher(client, self.ctx)._ensure_issue(
            spec, {"number": 11},
        )
        self.assertEqual(mapping["number"], 11)
        self.assertIn(("PATCH", base, {"title": spec.title}), client.calls)
        self.assertIn(("POST", f"{base}/labels", {"labels": ["build-order"]}), client.calls)

    def test_existing_forbidden_routing_label_is_never_removed(self) -> None:
        raw = issue(11, ROOT)
        raw["labels"] = [{"name": "agent:todo"}]
        client = FakeClient({("GET", f"repos/{REPOSITORY}/issues/11"): raw})
        with self.assertRaisesRegex(PublicationError, "forbidden routing"):
            AuthorityFreePublisher(client, self.ctx)._ensure_issue(
                self.ctx.specs[ROOT], {"number": 11},
            )
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_different_existing_parent_fails_before_mutation(self) -> None:
        ticket_id = next(key for key, value in self.ctx.specs.items() if value.kind == "ticket")
        mappings = {
            key: {
                "number": index + 1,
                "node_id": f"NODE_{index + 1}",
                "_database_id": index + 100,
            }
            for index, key in enumerate(self.ctx.specs)
        }
        root_number = mappings[ROOT]["number"]
        ticket_number = mappings[ticket_id]["number"]
        responses = relationship_responses(self.ctx, mappings)
        responses[("GET", f"repos/{REPOSITORY}/issues/{ticket_number}/parent")] = {
            "number": 9999,
            "node_id": "NODE_9999",
            "html_url": f"https://github.com/{REPOSITORY}/issues/9999",
        }
        client = FakeClient(responses)
        with self.assertRaisesRegex(PublicationError, "outside this publication"):
            AuthorityFreePublisher(client, self.ctx)._ensure_relationships(mappings)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_unexpected_blocker_is_never_removed(self) -> None:
        mappings = {
            key: {
                "number": index + 1,
                "node_id": f"NODE_{index + 1}",
                "_database_id": index + 100,
            }
            for index, key in enumerate(self.ctx.specs)
        }
        responses = relationship_responses(self.ctx, mappings)
        # Root has no expected blockers; injecting one must stop, never delete.
        responses[("GET", f"repos/{REPOSITORY}/issues/{mappings[ROOT]['number']}/dependencies/blocked_by?per_page=100&page=1")] = [
            {
                "number": mappings[SKILL]["number"],
                "node_id": mappings[SKILL]["node_id"],
                "html_url": (
                    f"https://github.com/{REPOSITORY}/issues/"
                    f"{mappings[SKILL]['number']}"
                ),
            }
        ]
        client = FakeClient(responses)
        with self.assertRaisesRegex(PublicationError, "unexpected existing blockers"):
            AuthorityFreePublisher(client, self.ctx)._ensure_relationships(mappings)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_exact_pending_comment_is_reused_without_post(self) -> None:
        from publication_comment import render_pending_comment
        body = render_pending_comment(ROOT, 1, APPROVED, REPOSITORY)
        comment = {
            "id": 44,
            "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-44",
            "body": body,
        }
        client = FakeClient({
            ("GET", f"repos/{REPOSITORY}/issues/1/comments?per_page=100&page=1"): [comment],
        })
        found = AuthorityFreePublisher(client, self.ctx)._ensure_pending_comment(
            {"number": 1}
        )
        self.assertEqual(found["id"], 44)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_multiple_pending_markers_fail_without_mutation(self) -> None:
        from publication_comment import render_pending_comment
        body = render_pending_comment(ROOT, 1, APPROVED, REPOSITORY)
        comments = [
            {"id": value, "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-{value}", "body": body}
            for value in (44, 45)
        ]
        client = FakeClient({
            ("GET", f"repos/{REPOSITORY}/issues/1/comments?per_page=100&page=1"): comments,
        })
        with self.assertRaisesRegex(PublicationError, "multiple reconciliation"):
            AuthorityFreePublisher(client, self.ctx)._ensure_pending_comment({"number": 1})
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_complete_existing_graph_apply_is_idempotent(self) -> None:
        mappings: dict[str, dict[str, Any]] = {}
        raw_issues: list[dict[str, Any]] = []
        for number, (logical_id, spec) in enumerate(self.ctx.specs.items(), 1):
            raw = issue(number, logical_id)
            raw.update({
                "title": spec.title,
                "body": spec.body,
                "labels": [{"name": label} for label in spec.labels],
            })
            raw_issues.append(raw)
            mappings[logical_id] = {
                "number": number,
                "node_id": raw["node_id"],
                "_database_id": raw["id"],
            }
        root_number = mappings[ROOT]["number"]
        comment_body = render_pending_comment(ROOT, 1, APPROVED, REPOSITORY)
        comment = {
            "id": 44,
            "html_url": (
                f"https://github.com/{REPOSITORY}/issues/{root_number}"
                "#issuecomment-44"
            ),
            "body": comment_body,
        }
        base = f"repos/{REPOSITORY}"
        responses = dry_responses(self.ctx, raw_issues)
        responses.update(relationship_responses(self.ctx, mappings))
        for raw in raw_issues:
            responses[("GET", f"{base}/issues/{raw['number']}")] = raw
        responses[("GET", f"{base}/issues/{root_number}/comments?per_page=100&page=1")] = [comment]
        responses[("GET", f"{base}/issues/comments/44")] = comment
        client = FakeClient(responses)

        result = ValidationFreePublisher(client, self.ctx).apply()

        self.assertEqual(result["mode"], "apply-pending")
        self.assertEqual(result["issues"], 56)
        self.assertEqual(result["members"], 54)
        self.assertEqual(result["blocked_by_edges"], 107)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_foreign_same_number_relationships_fail_before_mutation(self) -> None:
        mappings = {
            key: {
                "number": index + 1,
                "node_id": f"NODE_{index + 1}",
                "_database_id": index + 100,
            }
            for index, key in enumerate(self.ctx.specs)
        }
        root_number = mappings[ROOT]["number"]
        ticket_id = next(
            key for key, value in self.ctx.specs.items() if value.kind == "ticket"
        )
        ticket_number = mappings[ticket_id]["number"]
        blocker_edge = next(iter(self.ctx.expected_edges))
        blocked_id, blocker_id = blocker_edge
        blocked_number = mappings[blocked_id]["number"]
        blocker_number = mappings[blocker_id]["number"]

        cases = []
        parent = relationship_responses(self.ctx, mappings)
        parent[("GET", f"repos/{REPOSITORY}/issues/{ticket_number}/parent")] = {
            "number": root_number,
            "node_id": "FOREIGN_PARENT",
            "html_url": f"https://github.com/foreign/repo/issues/{root_number}",
        }
        cases.append(("parent", parent))

        subissue = relationship_responses(self.ctx, mappings)
        root_children = (
            f"repos/{REPOSITORY}/issues/{root_number}/sub_issues?per_page=100&page=1"
        )
        root_children_key = ("GET", root_children)
        subissue[root_children_key][0] = {
            "number": subissue[root_children_key][0]["number"],
            "node_id": "FOREIGN_SUBISSUE",
            "html_url": (
                "https://github.com/foreign/repo/issues/"
                f"{subissue[root_children_key][0]['number']}"
            ),
        }
        cases.append(("subissues", subissue))

        blocker = relationship_responses(self.ctx, mappings)
        blocker_path = (
            f"repos/{REPOSITORY}/issues/{blocked_number}"
            "/dependencies/blocked_by?per_page=100&page=1"
        )
        blocker_key = ("GET", blocker_path)
        expected_index = next(
            index for index, item in enumerate(blocker[blocker_key])
            if item["number"] == blocker_number
        )
        blocker[blocker_key][expected_index] = {
            "number": blocker_number,
            "node_id": "FOREIGN_BLOCKER",
            "html_url": f"https://github.com/foreign/repo/issues/{blocker_number}",
        }
        cases.append(("blockers", blocker))

        for label, responses in cases:
            with self.subTest(relation=label):
                client = FakeClient(responses)
                with self.assertRaisesRegex(PublicationError, "trusted repository"):
                    AuthorityFreePublisher(client, self.ctx)._ensure_relationships(
                        mappings
                    )
                self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_local_relationship_node_mismatch_fails_before_mutation(self) -> None:
        mappings = {
            key: {
                "number": index + 1,
                "node_id": f"NODE_{index + 1}",
                "_database_id": index + 100,
            }
            for index, key in enumerate(self.ctx.specs)
        }
        ticket_id = next(
            key for key, value in self.ctx.specs.items() if value.kind == "ticket"
        )
        ticket_number = mappings[ticket_id]["number"]
        responses = relationship_responses(self.ctx, mappings)
        responses[("GET", f"repos/{REPOSITORY}/issues/{ticket_number}/parent")][
            "node_id"
        ] = "WRONG_NODE"
        client = FakeClient(responses)
        with self.assertRaisesRegex(PublicationError, "node identity"):
            AuthorityFreePublisher(client, self.ctx)._ensure_relationships(mappings)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))


class FinalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.ctx = context(Path(self.temp.name))
        self.comment_url = (
            f"https://github.com/{REPOSITORY}/issues/1#issuecomment-44"
        )
        self.receipt_url = f"https://github.com/{REPOSITORY}/commit/{RECEIPT}"
        self.authority = ReceiptAuthority(
            repository=REPOSITORY,
            root_id=ROOT,
            plan_version=1,
            approved_commit=APPROVED,
            root_issue_url=f"https://github.com/{REPOSITORY}/issues/1",
            root_comment_url=self.comment_url,
            trusted_repository_ref="refs/heads/build-order-research",
            receipt_manifests={},
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _comment(self, state: str, comment_id: int | None = None) -> dict[str, Any]:
        comment_id = 44 if comment_id is None else comment_id
        comment_url = (
            f"https://github.com/{REPOSITORY}/issues/1"
            f"#issuecomment-{comment_id}"
        )
        body = (
            render_pending_comment(ROOT, 1, APPROVED, REPOSITORY)
            if state == "pending"
            else render_successful_comment(
                ROOT, 1, APPROVED, REPOSITORY, RECEIPT, self.receipt_url,
            )
        )
        return {"id": comment_id, "html_url": comment_url, "body": body}

    def _client(
        self, comments: list[dict[str, Any]], *, drift_after_scans: int | None = None,
    ) -> Client:
        pending_path = f"repos/{REPOSITORY}/issues/comments/44"
        comments_path = f"repos/{REPOSITORY}/issues/1/comments?per_page=100&page=1"
        create_path = f"repos/{REPOSITORY}/issues/1/comments"

        class CommentClient(FakeClient):
            scans = 0

            def request(inner, method: str, path: str, payload=None, *, allow_404=False):
                inner.calls.append((method, path, payload))
                if method == "GET" and path == pending_path:
                    return copy.deepcopy(comments[0])
                if method == "GET" and path == comments_path:
                    inner.scans += 1
                    if drift_after_scans is not None and inner.scans > drift_after_scans:
                        drifted = copy.deepcopy(comments)
                        drifted[0]["body"] = (
                            "Operator revoked finalization.\n\n" + drifted[0]["body"]
                        )
                        return drifted
                    return copy.deepcopy(comments)
                if method == "POST" and path == create_path:
                    successful = self._comment("successful", 45)
                    self.assertEqual(payload, {"body": successful["body"]})
                    comments.append(successful)
                    return copy.deepcopy(successful)
                raise AssertionError((method, path))

        return CommentClient({})

    def _publisher(
        self, client: Client, *, fail_successful_once: bool = False,
    ) -> Publisher:
        authority = self.authority

        class FinalizePublisher(AuthorityFreePublisher):
            def __init__(inner, fake: Client, ctx: Context) -> None:
                super().__init__(fake, ctx)
                inner.verifications: list[str] = []
                inner.fail_successful_once = fail_successful_once

            def _receipt_authority(inner, receipt_commit: str) -> ReceiptAuthority:
                self.assertEqual(receipt_commit, RECEIPT)
                return authority

            def _run_receipt_verifier(
                inner, state: str, value: ReceiptAuthority,
                receipt_commit: str, receipt_url: str,
            ) -> None:
                inner.verifications.append(state)
                if state == "successful" and inner.fail_successful_once:
                    inner.fail_successful_once = False
                    raise PublicationError("simulated post-create verifier failure")

        return FinalizePublisher(client, self.ctx)

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_mutable_checkout_receipt_cannot_redirect_successful_create(
        self, _git: Any, _commit: Any,
    ) -> None:
        self.ctx.publication["github_reconciliation"] = {
            "root_reconciliation_comment_matches": [{
                "url": f"https://github.com/{REPOSITORY}/issues/99#issuecomment-999",
            }],
        }
        comments = [self._comment("pending")]
        client = self._client(comments)
        result = self._publisher(client).finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["pending_comment"], self.comment_url)
        self.assertEqual(
            result["successful_comment"],
            f"https://github.com/{REPOSITORY}/issues/1#issuecomment-45",
        )
        self.assertNotIn("comments/999", [call[1] for call in client.calls])
        self.assertEqual(
            [call[1] for call in client.calls if call[0] == "POST"],
            [f"repos/{REPOSITORY}/issues/1/comments"],
        )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_already_successful_finalization_is_idempotent(
        self, _git: Any, _commit: Any,
    ) -> None:
        pending = self._comment("pending")
        successful = self._comment("successful", 45)
        client = self._client([pending, successful])
        publisher = self._publisher(client)
        result = publisher.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["mode"], "finalized")
        self.assertEqual(result["successful_comment"], successful["html_url"])
        self.assertEqual(publisher.verifications, ["successful"])
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_crash_after_create_resumes_from_successful_comment(
        self, _git: Any, _commit: Any,
    ) -> None:
        comments = [self._comment("pending")]
        client = self._client(comments)
        first = self._publisher(client, fail_successful_once=True)
        with self.assertRaisesRegex(PublicationError, "simulated post-create"):
            first.finalize(RECEIPT, self.receipt_url)
        second = self._publisher(client)
        result = second.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["mode"], "finalized")
        self.assertEqual(second.verifications, ["successful"])
        self.assertEqual(sum(call[0] == "POST" for call in client.calls), 1)

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_visible_pending_drift_before_create_fails_without_mutation(
        self, _git: Any, _commit: Any,
    ) -> None:
        client = self._client([self._comment("pending")], drift_after_scans=1)
        publisher = self._publisher(client)
        with self.assertRaisesRegex(
            PublicationError, "malformed or conflicting",
        ):
            publisher.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(publisher.verifications, ["pending"])
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_malformed_conflicting_and_duplicate_evidence_fail_without_mutation(
        self, _git: Any, _commit: Any,
    ) -> None:
        pending = self._comment("pending")
        malformed = {
            "id": 45,
            "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-45",
            "body": "<!-- aiur-build-order-reconciliation\nnot-json\n-->",
        }
        conflicting = self._comment("successful", 45)
        conflicting["body"] = conflicting["body"].replace(RECEIPT, "d" * 40)
        duplicate = [
            self._comment("successful", 45), self._comment("successful", 46),
        ]
        for label, evidence, message in (
            ("malformed", [malformed], "malformed or conflicting"),
            ("conflicting", [conflicting], "malformed or conflicting"),
            ("duplicate", duplicate, "duplicate successful"),
        ):
            with self.subTest(case=label):
                client = self._client([copy.deepcopy(pending), *copy.deepcopy(evidence)])
                with self.assertRaisesRegex(PublicationError, message):
                    self._publisher(client).finalize(RECEIPT, self.receipt_url)
                self.assertTrue(all(call[0] == "GET" for call in client.calls))


class AuthorityCheckpointTests(unittest.TestCase):
    def test_drift_stops_before_next_bounded_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            ctx = context(Path(name))

            class DriftPublisher(AuthorityFreePublisher):
                checks = 0

                def _check_authority(
                    inner, expected_tip: str | None = "configured",
                ) -> None:
                    inner.checks += 1
                    if inner.checks == 2:
                        raise PublicationError("simulated trusted-ref drift")

            responses = {
                ("POST", f"repos/{REPOSITORY}/labels/{index}"): {}
                for index in range(AUTHORITY_CHECKPOINT_MUTATIONS + 1)
            }
            client = FakeClient(responses)
            publisher = DriftPublisher(client, ctx)
            publisher._guard_apply_mutations = True
            for index in range(AUTHORITY_CHECKPOINT_MUTATIONS):
                publisher._mutate(
                    "POST", f"repos/{REPOSITORY}/labels/{index}", {},
                )
            with self.assertRaisesRegex(PublicationError, "trusted-ref drift"):
                publisher._mutate(
                    "POST",
                    f"repos/{REPOSITORY}/labels/{AUTHORITY_CHECKPOINT_MUTATIONS}",
                    {},
                )
            self.assertEqual(len(client.calls), AUTHORITY_CHECKPOINT_MUTATIONS)


class ClientSafetyTests(unittest.TestCase):
    def test_label_creation_allowlist_is_exactly_the_rehearsed_eight(self) -> None:
        self.assertEqual(set(CREATABLE_LABELS), {
            "build-order", "build-lane:plan-graph", "build-lane:runtime",
            "build-lane:dashboard-ui", "build-lane:accounting",
            "build-lane:platform", "phase:7", "phase:8",
        })

    def test_real_client_refuses_arbitrary_hosts_and_absolute_paths(self) -> None:
        client = GhClient()
        for path in ("https://evil.example/repos/x/y", "/repos/example/repo"):
            with self.subTest(path=path), self.assertRaisesRegex(PublicationError, "refusing"):
                client.request("GET", path)

    def test_real_client_does_not_echo_secret_bearing_stderr(self) -> None:
        completed = __import__("subprocess").CompletedProcess(
            ["gh"], 1, "", "proxy failed token=super-secret HTTP 500",
        )
        with patch("publication_operator.subprocess.run", return_value=completed):
            with self.assertRaises(PublicationError) as caught:
                GhClient().request("GET", "repos/example/repo/issues")
        self.assertNotIn("super-secret", str(caught.exception))


class ApprovedRenderingTests(unittest.TestCase):
    def test_extended_pack_validator_receives_immutable_root_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            ctx = context(Path(name))
            publisher = Publisher(FakeClient({}), ctx)
            commands: list[tuple[list[str], str]] = []
            with patch.object(
                Publisher, "_run_checked",
                side_effect=lambda command, label: commands.append((command, label)),
            ):
                publisher._run_validators()

            self.assertEqual(1, len(commands))
            command, label = commands[0]
            self.assertEqual("canonical validator", label)
            self.assertEqual(
                [
                    "--repository-root", str(ctx.root),
                    "--root-document", "root-issue.md",
                ],
                command[-4:],
            )

    def test_repository_pack_exports_all_exact_bodies_and_titles(self) -> None:
        root = Path(__file__).resolve().parents[4]
        result = subprocess_result = None
        import subprocess
        subprocess_result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        )
        approved = subprocess_result.stdout.strip()
        ctx = build_context(
            root / "docs/build-order/build-order.json",
            root / "docs/build-order/publication.json",
            approved, approved,
        )
        self.assertEqual(len(ctx.specs), 56)
        self.assertEqual(len(ctx.expected_edges), 107)
        self.assertTrue(all(APPROVED not in spec.body for spec in ctx.specs.values()))
        self.assertTrue(all(approved in spec.body for spec in ctx.specs.values()))

    def test_receipt_builder_emits_core_v3_and_auxiliary_v2_from_fresh_evidence(self) -> None:
        import subprocess
        from publication_comment import pending_comment_evidence
        from publication_common import Report

        root = Path(__file__).resolve().parents[4]
        approved = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        ctx = build_context(
            root / "docs/build-order/build-order.json",
            root / "docs/build-order/publication.json",
            approved, approved,
        )
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            ctx.build_path = base / "build-order.json"
            ctx.publication_path = base / "publication.json"
            ctx.root_document = base / "root-issue.md"
            ctx.additional_document = base / "skill-delivery.md"
            ctx.build_path.write_text(json.dumps(ctx.build), encoding="utf-8")
            ctx.publication_path.write_text(json.dumps(ctx.publication), encoding="utf-8")
            issues: dict[str, dict[str, Any]] = {}
            marker_matches: dict[str, list[dict[str, Any]]] = {}
            for number, (logical_id, spec) in enumerate(ctx.specs.items(), 1):
                mapping = {
                    "repository": ctx.repository, "number": number,
                    "node_id": f"NODE_{number}",
                    "url": f"https://github.com/{ctx.repository}/issues/{number}",
                    "_database_id": number + 1000,
                }
                issues[logical_id] = {
                    "mapping": mapping, "labels": list(spec.labels),
                    "title": spec.title, "state": "OPEN", "parent": None,
                }
                marker_matches[logical_id] = [mapping]
            root_number = issues[ctx.root_id]["mapping"]["number"]
            comment_url = (
                f"https://github.com/{ctx.repository}/issues/{root_number}"
                "#issuecomment-99"
            )
            report = Report()
            comment = pending_comment_evidence(
                comment_url, ctx.root_id, ctx.plan_version, ctx.approved,
                ctx.repository, report,
            )
            self.assertIsNotNone(comment)
            AuthorityFreePublisher(FakeClient({}), ctx)._write_materialized({
                "issues": issues, "marker_matches": marker_matches,
                "comment": comment,
            })
            build = json.loads(ctx.build_path.read_text(encoding="utf-8"))
            publication = json.loads(ctx.publication_path.read_text(encoding="utf-8"))
            self.assertEqual(build["github_reconciliation"]["receipt_schema_version"], 3)
            self.assertEqual(publication["github_reconciliation"]["receipt_schema_version"], 2)
            self.assertEqual(len(build["github_reconciliation"]["member_ticket_ids"]), 54)
            self.assertEqual(len(build["github_reconciliation"]["dependency_edges"]), 105)
            self.assertEqual(publication["approved_planning_commit"], approved)
            serialized = json.dumps([build, publication])
            self.assertNotIn("_database_id", serialized)
            self.assertNotIn("<APPROVED_SHA>", (base / "root-issue.md").read_text())
            self.assertIn(approved, (base / "skill-delivery.md").read_text())


if __name__ == "__main__":
    unittest.main()
