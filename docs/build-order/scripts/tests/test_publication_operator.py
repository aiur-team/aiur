from __future__ import annotations

import json
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
    GhClient,
    PublicationError,
    Publisher,
    build_context,
)
from publication_operator_case import (
    APPROVED,
    AuthorityFreePublisher,
    context,
    dry_responses,
    FakeClient,
    issue,
    labels_response,
    REPOSITORY,
    ROOT,
    SKILL,
)


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

    def test_reapproval_reuses_issue_and_reports_content_delta(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        raw = issue(8, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "c" * 40)
        client = FakeClient(dry_responses(self.ctx, [raw]))
        result = AuthorityFreePublisher(client, self.ctx).dry_run()
        self.assertEqual(result["canonical_issues_found"], 1)
        self.assertEqual(result["issues_to_create"], 55)
        self.assertEqual(result["reapproval"]["unchanged_members"], [ROOT])
        self.assertEqual(result["reapproval"]["changed_members"], [])
        self.assertEqual(result["reapproval"]["new_members"], sorted(
            logical_id for logical_id in self.ctx.specs if logical_id != ROOT
        ))

    def test_duplicate_member_authority_names_member_shas_and_recovery(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        old = issue(8, ROOT)
        old["body"] = old["body"].replace(APPROVED, "c" * 40)
        current = issue(9, ROOT)
        client = FakeClient(dry_responses(self.ctx, [old, current]))
        with self.assertRaisesRegex(
            PublicationError,
            rf"{ROOT}.*{APPROVED}.*{'c' * 40}.*re-approve|{ROOT}.*{'c' * 40}.*{APPROVED}.*re-approve",
        ):
            AuthorityFreePublisher(client, self.ctx).dry_run()

    def test_reapproval_reports_removed_member_without_invalidating_it(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        removed = issue(8, "T-REMOVED")
        removed["body"] = removed["body"].replace(APPROVED, "c" * 40)
        result = AuthorityFreePublisher(
            FakeClient(dry_responses(self.ctx, [removed])), self.ctx,
        ).dry_run()
        self.assertEqual(result["canonical_issues_found"], 0)
        self.assertEqual(result["reapproval"]["removed_members"], ["T-REMOVED"])

    def test_reapproval_reports_changed_member_content(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        raw = issue(8, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "c" * 40) + "changed scope\n"
        result = AuthorityFreePublisher(
            FakeClient(dry_responses(self.ctx, [raw])), self.ctx,
        ).dry_run()
        self.assertEqual(result["reapproval"]["changed_members"], [ROOT])

    def test_unrecorded_approval_names_both_shas_and_recovery(self) -> None:
        self.ctx.publication["approved_planning_commit"] = "c" * 40
        raw = issue(8, ROOT)
        raw["body"] = raw["body"].replace(APPROVED, "d" * 40)
        with self.assertRaisesRegex(
            PublicationError,
            rf"{ROOT}.*{'d' * 40}.*{APPROVED}.*Options",
        ):
            AuthorityFreePublisher(
                FakeClient(dry_responses(self.ctx, [raw])), self.ctx,
            ).dry_run()

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
                command[-6:-2],
            )

    # Known failure: the checked-in pack no longer equals its pinned approved
    # commit, and that commit is unreachable from every branch (#4042).
    @unittest.expectedFailure
    def test_repository_pack_exports_all_exact_bodies_and_titles(self) -> None:
        root = Path(__file__).resolve().parents[4]
        publication = json.loads(
            (root / "docs/build-order/publication.json").read_text(encoding="utf-8")
        )
        approved = publication["approved_planning_commit"]
        ctx = build_context(
            root / "docs/build-order/build-order.json",
            root / "docs/build-order/publication.json",
            approved, approved,
        )
        self.assertEqual(len(ctx.specs), 56)
        self.assertEqual(len(ctx.expected_edges), 107)
        self.assertTrue(all(APPROVED not in spec.body for spec in ctx.specs.values()))
        self.assertTrue(all(approved in spec.body for spec in ctx.specs.values()))

    # Known failure: the checked-in pack no longer equals its pinned approved
    # commit, and that commit is unreachable from every branch (#4042).
    @unittest.expectedFailure
    def test_receipt_builder_emits_core_v3_and_auxiliary_v2_from_fresh_evidence(self) -> None:
        from publication_comment import pending_comment_evidence
        from publication_common import Report

        root = Path(__file__).resolve().parents[4]
        publication = json.loads(
            (root / "docs/build-order/publication.json").read_text(encoding="utf-8")
        )
        approved = publication["approved_planning_commit"]
        ctx = build_context(
            root / "docs/build-order/build-order.json",
            root / "docs/build-order/publication.json",
            approved, approved,
        )
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            ctx.root = base
            ctx.build_path = base / "build-order.json"
            ctx.publication_path = base / "publication.json"
            ctx.discovery_path = base / ".aiur/build_orders/example.json"
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
