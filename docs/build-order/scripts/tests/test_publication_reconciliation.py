"""Publisher apply-stage reconciliation tests."""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path
from typing import Any

from publication_operator_case import (
    APPROVED,
    AuthorityFreePublisher,
    context,
    dry_responses,
    FakeClient,
    issue,
    relationship_responses,
    REPOSITORY,
    ROOT,
    SKILL,
    ValidationFreePublisher,
)
from publication_operator import PublicationError
from publication_comment import render_pending_comment


class ReconciliationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.ctx = context(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_reapproval_updates_existing_issue_in_place(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        spec = self.ctx.specs[ROOT]
        raw = issue(11, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "c" * 40)
        raw["labels"] = [{"name": "build-order"}]
        raw["_planning_markers"] = [{
            "schema": 2,
            "logical_id": ROOT,
            "plan_version": 1,
            "approved_planning_commit": "c" * 40,
        }]
        updated = copy.deepcopy(raw)
        updated["body"] = spec.body
        base = f"repos/{REPOSITORY}/issues/11"

        class ReapprovalClient(FakeClient):
            count = 0

            def request(inner, method: str, path: str, payload=None, *, allow_404=False):
                inner.calls.append((method, path, payload))
                if method == "GET":
                    inner.count += 1
                    return copy.deepcopy(raw if inner.count == 1 else updated)
                return {}

        publisher = AuthorityFreePublisher(ReapprovalClient({}), self.ctx)
        mapping = publisher._canonical_mappings([raw])[ROOT]
        publisher._ensure_issue(spec, mapping)

        self.assertIn(("PATCH", base, {"body": spec.body}), publisher.client.calls)

    def test_persisted_reapproval_retains_mapping_and_reports_changed_member(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        raw = issue(11, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "c" * 40) + "changed scope\n"
        raw["_planning_markers"] = [{
            "schema": 2,
            "logical_id": ROOT,
            "plan_version": 1,
            "approved_planning_commit": "c" * 40,
        }]
        publisher = AuthorityFreePublisher(FakeClient({}), self.ctx)
        self.ctx.build["github_root"] = publisher._receipt_mapping(
            publisher._mapping(raw)
        )

        mappings = publisher._canonical_mappings([raw])

        self.assertEqual(11, mappings[ROOT]["number"])
        self.assertEqual([ROOT], publisher._reapproval["changed_members"])
        publisher._validate_live_issue_identity(raw, self.ctx.specs[ROOT])

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
        publisher = AuthorityFreePublisher(client, self.ctx)
        mapping = publisher._ensure_issue(
            spec, publisher._receipt_mapping(publisher._mapping(raw)),
        )
        self.assertEqual(mapping["number"], 11)
        self.assertIn(("PATCH", base, {"title": spec.title}), client.calls)
        self.assertIn(("POST", f"{base}/labels", {"labels": ["build-order"]}), client.calls)

    def test_existing_forbidden_routing_label_is_never_removed(self) -> None:
        raw = issue(11, ROOT)
        raw["labels"] = [{"name": "agent:todo"}]
        client = FakeClient({("GET", f"repos/{REPOSITORY}/issues/11"): raw})
        publisher = AuthorityFreePublisher(client, self.ctx)
        with self.assertRaisesRegex(PublicationError, "forbidden routing"):
            publisher._ensure_issue(
                self.ctx.specs[ROOT],
                publisher._receipt_mapping(publisher._mapping(raw)),
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

    def test_reapproval_unlinks_retired_member_relationships(self) -> None:
        ticket_id = next(
            key for key, spec in self.ctx.specs.items() if spec.kind == "ticket"
        )
        self.ctx.specs = {
            ROOT: self.ctx.specs[ROOT], ticket_id: self.ctx.specs[ticket_id],
        }
        self.ctx.expected_edges = set()
        self.ctx.core_edges = set()
        mappings = {
            ROOT: {"number": 1, "node_id": "NODE_1", "_database_id": 101},
            ticket_id: {"number": 2, "node_id": "NODE_2", "_database_id": 102},
        }
        retired = {"number": 3, "node_id": "NODE_3", "_database_id": 103}
        publisher = AuthorityFreePublisher(FakeClient({}), self.ctx)
        publisher._retired_mappings = {"T-REMOVED": retired}
        publisher._retired_by_number = {3: ("T-REMOVED", "NODE_3")}
        by_number = {1: mappings[ROOT], 2: mappings[ticket_id], 3: retired}

        def relation(number: int) -> dict[str, Any]:
            mapping = by_number[number]
            return {
                "number": number, "node_id": mapping["node_id"],
                "html_url": f"https://github.com/{REPOSITORY}/issues/{number}",
            }

        base = f"repos/{REPOSITORY}/issues"
        publisher.client.responses = {
            ("GET", f"{base}/1/parent"): None,
            ("GET", f"{base}/1/sub_issues?per_page=100&page=1"): [relation(2), relation(3)],
            ("GET", f"{base}/1/dependencies/blocked_by?per_page=100&page=1"): [],
            ("GET", f"{base}/2/parent"): relation(1),
            ("GET", f"{base}/2/sub_issues?per_page=100&page=1"): [],
            ("GET", f"{base}/2/dependencies/blocked_by?per_page=100&page=1"): [relation(3)],
            ("DELETE", f"{base}/1/sub_issues/3"): {},
            ("DELETE", f"{base}/2/dependencies/blocked_by/3"): {},
        }
        publisher._ensure_relationships(mappings)
        self.assertIn(("DELETE", f"{base}/1/sub_issues/3", {}), publisher.client.calls)
        self.assertIn(("DELETE", f"{base}/2/dependencies/blocked_by/3", {}), publisher.client.calls)

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

    def test_reapproval_updates_prior_pending_comment_in_place(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        prior = {
            "id": 44,
            "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-44",
            "body": render_pending_comment(ROOT, 1, "c" * 40, REPOSITORY),
        }
        current = {
            "id": 44,
            "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-44",
            "body": render_pending_comment(ROOT, 1, APPROVED, REPOSITORY),
        }
        client = FakeClient({
            ("GET", f"repos/{REPOSITORY}/issues/1/comments?per_page=100&page=1"): [prior],
            ("PATCH", f"repos/{REPOSITORY}/issues/comments/44"): current,
            ("GET", f"repos/{REPOSITORY}/issues/comments/44"): current,
        })
        publisher = AuthorityFreePublisher(client, self.ctx)
        found = publisher._ensure_pending_comment({"number": 1})
        self.assertEqual(found["id"], 44)
        self.assertIn(
            ("PATCH", f"repos/{REPOSITORY}/issues/comments/44", {"body": current["body"]}),
            client.calls,
        )

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
