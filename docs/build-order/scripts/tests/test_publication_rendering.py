"""Canonical issue rendering and final-comment verification tests."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_comment import (  # noqa: E402
    render_pending_comment,
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report  # noqa: E402
from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from publication_rendering import (  # noqa: E402
    approved_link,
    authority_preamble,
    inspect_issue_body,
    render_approved_pack,
)


REPOSITORY = "example/repo"
ROOT_ID = "example/repo:build-order-dashboard"
APPROVED = "a" * 40


class IssueRenderingTests(unittest.TestCase):
    def canonical(self) -> str:
        return authority_preamble(REPOSITORY, ROOT_ID, 1, APPROVED) + "# Root\n"

    def errors(self, body: str) -> str:
        report = Report()
        inspect_issue_body(body, REPOSITORY, ROOT_ID, 1, APPROVED, report, "body")
        return "\n".join(report.errors)

    def test_missing_wrong_and_duplicate_markers_are_rejected(self) -> None:
        body = self.canonical()
        marker = body[body.index("<!-- aiur-planning-issue"):body.index("-->") + 3]
        self.assertIn("exactly one schema-2", self.errors(body.replace(marker, "")))
        self.assertIn("schema must equal 2", self.errors(body.replace('"schema":2', '"schema":1')))
        self.assertIn("exactly one schema-2", self.errors(body + marker))

    def test_missing_wrong_and_duplicate_approved_links_are_rejected(self) -> None:
        body = self.canonical()
        link = approved_link(REPOSITORY, APPROVED)
        self.assertIn("exactly one approved commit link", self.errors(body.replace(link, "")))
        self.assertIn(
            "approved link must equal",
            self.errors(body.replace(link, approved_link(REPOSITORY, "b" * 40))),
        )
        self.assertIn("exactly one approved commit link", self.errors(body + link))

    def test_absent_approved_pack_path_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        companions = json.loads(fixture.companion_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        report = Report()
        expected = render_approved_pack(
            build, companions, publication, fixture.build_path,
            fixture.companion_path, fixture.base / "missing-publication.json",
            companions["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn("absent from approved commit", "\n".join(report.errors))

    def test_post_approval_planning_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        companions = json.loads(fixture.companion_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        build["tickets"][0]["depends_on"] = ["BO-999"]
        report = Report()
        expected = render_approved_pack(
            build, companions, publication, fixture.build_path,
            fixture.companion_path, fixture.publication_path,
            companions["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn(
            "planning fields must equal the approved commit",
            "\n".join(report.errors),
        )


class FinalCommentTests(unittest.TestCase):
    def values(self):
        receipt = "b" * 40
        receipt_url = f"https://github.com/{REPOSITORY}/commit/{receipt}"
        root_url = f"https://github.com/{REPOSITORY}/issues/901"
        comment_url = root_url + "#issuecomment-123"
        body = render_successful_comment(
            ROOT_ID, 1, APPROVED, REPOSITORY, receipt, receipt_url
        )
        return receipt, receipt_url, root_url, comment_url, body

    def report(self, matches, receipt=None, receipt_url=None):
        baseline_receipt, baseline_url, root_url, _, _ = self.values()
        report = Report()
        validate_final_comment_matches(
            matches, ROOT_ID, 1, APPROVED, receipt or baseline_receipt,
            receipt_url or baseline_url, root_url, REPOSITORY, report,
        )
        return report

    def test_exact_successful_comment_is_clean(self) -> None:
        _, _, _, url, body = self.values()
        self.assertEqual([], self.report([{"url": url, "body": body}]).errors)

    def test_duplicate_comment_matches_and_wrong_receipt_fail(self) -> None:
        _, _, _, url, body = self.values()
        item = {"url": url, "body": body}
        self.assertIn(
            "exactly one comment match", "\n".join(self.report([item, dict(item)]).errors)
        )
        wrong = "c" * 40
        wrong_url = f"https://github.com/{REPOSITORY}/commit/{wrong}"
        self.assertIn(
            "canonical successful receipt",
            "\n".join(self.report([item], wrong, wrong_url).errors),
        )

    def test_pending_state_and_duplicate_marker_fail_final_verification(self) -> None:
        _, _, _, url, body = self.values()
        pending = render_pending_comment(ROOT_ID, 1, APPROVED, REPOSITORY)
        self.assertIn(
            "canonical successful receipt",
            "\n".join(self.report([{"url": url, "body": pending}]).errors),
        )
        marker = body[body.index("<!-- aiur-build-order-reconciliation"):]
        self.assertIn(
            "exactly one aiur-build-order-reconciliation marker",
            "\n".join(self.report([{"url": url, "body": body + marker}]).errors),
        )


if __name__ == "__main__":
    unittest.main()
