"""Final-comment verification tests: comment state, receipt and approval identity."""

from __future__ import annotations

import json
import subprocess
from unittest.mock import patch

from publication_rendering_case import FinalCommentCase, replace_repository
from publication_comment import (
    render_pending_comment,
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report
from publication_fixtures import Fixture
from publication_materialized_fixture import materialized_pack


class FinalCommentTests(FinalCommentCase):
    def test_exact_successful_comment_is_clean(self) -> None:
        _, _, _, url, body = self.values()
        self.assertEqual([], self.report([{"url": url, "body": body}]).errors)

    def test_production_verifier_uses_exact_receipt_comment_url(self) -> None:
        _, _, _, url, body = self.values()
        report = self.report([{"url": url, "body": body}])
        self.assertEqual([], report.errors)

    def test_successful_comment_must_remain_on_trusted_root(self) -> None:
        _, _, _, url, body = self.values()
        wrong_url = "https://github.com/attacker/fork/issues/1#issuecomment-999"
        self.assertIn(
            "must be a distinct canonical comment on the trusted root issue",
            "\n".join(
                self.report([{"url": wrong_url, "body": body}]).errors
            ),
        )

    def test_duplicate_comment_matches_fail(self) -> None:
        _, _, _, url, body = self.values()
        item = {"url": url, "body": body}
        self.assertIn(
            "exactly one successful comment",
            "\n".join(self.report([item, dict(item)]).errors),
        )

    def test_pending_state_and_duplicate_marker_fail_final_verification(self) -> None:
        _, _, _, url, body = self.values()
        pending = render_pending_comment(
            self.root_id, self.plan_version, self.approved, self.repository
        )
        self.assertIn(
            "canonical successful receipt",
            "\n".join(self.report([{"url": url, "body": pending}]).errors),
        )
        marker = body[body.index("<!-- aiur-build-order-reconciliation"):]
        self.assertIn(
            "exactly one aiur-build-order-reconciliation marker",
            "\n".join(self.report([{"url": url, "body": body + marker}]).errors),
        )

    def test_nonexistent_receipt_commit_fails_final_verification(self) -> None:
        missing = "0" * 40
        receipt_url = f"https://github.com/{self.repository}/commit/{missing}"
        _, _, _, comment_url, _ = self.values()
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            missing, receipt_url,
        )
        report = self.report(
            [{"url": comment_url, "body": body}],
            receipt=missing, receipt_url=receipt_url,
        )
        self.assertIn(
            "receipt_commit must resolve to an exact commit in this repository",
            report.errors,
        )

    def test_malformed_receipt_url_fails_final_verification(self) -> None:
        receipt, canonical_url, _, comment_url, _ = self.values()
        urls = (
            f"https://evil.example/receipts/{receipt}",
            canonical_url + "?not-the-commit-object",
        )
        for receipt_url in urls:
            with self.subTest(receipt_url=receipt_url):
                body = render_successful_comment(
                    self.root_id, self.plan_version, self.approved,
                    self.repository, receipt, receipt_url,
                )
                report = self.report(
                    [{"url": comment_url, "body": body}],
                    receipt_url=receipt_url,
                )
                self.assertIn(
                    f"receipt_url must equal {canonical_url}", report.errors
                )

    def test_caller_consistent_foreign_authority_is_rejected(self) -> None:
        foreign_repository = "attacker/fork"
        foreign_root_id = "attacker/fork:build-order-dashboard"
        foreign_root_url = "https://github.com/attacker/fork/issues/901"
        receipt_url = (
            f"https://github.com/{foreign_repository}/commit/{self.receipt}"
        )
        body = render_successful_comment(
            foreign_root_id, self.plan_version, self.approved,
            foreign_repository, self.receipt, receipt_url,
        )
        report = self.report(
            [{"url": foreign_root_url + "#issuecomment-123", "body": body}],
            receipt_url=receipt_url,
            root_id=foreign_root_id,
            root_url=foreign_root_url,
            repository=foreign_repository,
        )
        joined = "\n".join(report.errors)
        self.assertIn("repository must equal receipt authority value", joined)
        self.assertIn("root_id must equal receipt authority value", joined)
        self.assertIn("root_issue_url must equal receipt authority value", joined)

    def test_nonexistent_caller_approval_is_rejected(self) -> None:
        missing = "0" * 40
        _, receipt_url, _, comment_url, _ = self.values()
        body = render_successful_comment(
            self.root_id, self.plan_version, missing, self.repository,
            self.receipt, receipt_url,
        )
        report = self.report(
            [{"url": comment_url, "body": body}], approved=missing,
        )
        self.assertTrue(any(
            "approved planning commit must equal receipt authority value" in error
            for error in report.errors
        ))

    def test_receipt_with_nonexistent_approval_is_rejected(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        missing = "0" * 40
        path = fixture.publication_path
        value = json.loads(path.read_text(encoding="utf-8"))
        value["approved_planning_commit"] = missing
        path.write_text(json.dumps(value), encoding="utf-8")
        receipt = fixture.commit_materialized()
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        repository = build["repository"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            materialized_build["build_order_id"], build["plan_version"], missing,
            repository, receipt, receipt_url,
        )
        report = Report()
        with patch("publication_comment.verify_live_graph", return_value=True):
            validate_final_comment_matches(
                materialized_build["build_order_id"], build["plan_version"], missing,
                receipt, receipt_url, root_url, repository, report,
                repository_anchor=fixture.build_path,
                remote_ref_contains=self.remote_ref_contains,
            )
        self.assertTrue(any(
            "approved_planning_commit must resolve to an exact commit" in error
            for error in report.errors
        ))

    def test_foreign_materialized_receipt_cannot_override_origin(self) -> None:
        build, manifest = materialized_pack()
        build, manifest = (
            replace_repository(item, "example/repo", "attacker/fork")
            for item in (build, manifest)
        )
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        receipt = fixture.commit_materialized()
        subprocess.run(
            [
                "git", "-C", str(fixture.base), "remote", "set-url", "origin",
                "git@github.com:aiur-team/aiur.git",
            ],
            check=True,
        )
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        materialized_publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        repository = materialized_build["repository"]
        root_id = materialized_build["build_order_id"]
        plan_version = materialized_build["plan_version"]
        approved = materialized_publication["approved_planning_commit"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            root_id, plan_version, approved, repository, receipt, receipt_url
        )
        report = Report()
        with patch("publication_comment.verify_live_graph", return_value=True):
            validate_final_comment_matches(
                root_id, plan_version, approved, receipt, receipt_url,
                root_url, repository, report,
                repository_anchor=fixture.build_path,
                remote_ref_contains=self.remote_ref_contains,
            )
        self.assertIn(
            "validated receipt repository must equal configured GitHub origin "
            "aiur-team/aiur",
            report.errors,
        )
