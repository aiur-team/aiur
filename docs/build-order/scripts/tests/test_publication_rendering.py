"""Canonical issue rendering tests."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
sys.path.insert(0, str(SKILL_PUBLICATION))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_common import Report  # noqa: E402
from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from publication_rendering import (  # noqa: E402
    approved_link,
    authority_preamble,
    inspect_issue_body,
    render_approved_pack,
    render_approved_titles,
)
from validate_publication import validate  # noqa: E402
from publication_rendering_case import APPROVED, REPOSITORY, ROOT_ID


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
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        report = Report()
        expected = render_approved_pack(
            build, publication, fixture.build_path,
            fixture.base / "missing-publication.json",
            publication["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn("absent from approved commit", "\n".join(report.errors))

    def test_titles_are_derived_from_exact_approved_document_h1s(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        report = Report()
        titles = render_approved_titles(
            build, publication, fixture.build_path,
            fixture.publication_path,
            publication["approved_planning_commit"], report,
        )
        self.assertEqual([], report.errors)
        assert titles is not None
        self.assertEqual("BO: Test root", titles[ROOT_ID])
        self.assertEqual("BO: BO-001 — Build Order ticket 1", titles["BO-001"])
        self.assertEqual("BO: DASH-001 — First companion", titles["DASH-001"])
        self.assertEqual("Test skill", titles["SKILL-DELIVERY-001"])
        self.assertEqual(46, len(titles))

    def test_post_approval_planning_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        build["tickets"][0]["depends_on"] = ["BO-999"]
        report = Report()
        expected = render_approved_pack(
            build, publication, fixture.build_path,
            fixture.publication_path,
            publication["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn(
            "planning fields must equal the approved commit",
            "\n".join(report.errors),
        )

    def test_post_approval_trusted_ref_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        publication["trusted_repository_ref"] = "refs/heads/other"
        fixture.publication_path.write_text(
            json.dumps(publication), encoding="utf-8"
        )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertIn(
            "materialized publication planning fields must equal the approved commit",
            report.errors,
        )

    def test_post_approval_ticket_document_drift_fails_closed(self) -> None:
        for relative, logical_id in (
            ("tickets/BO-001.md", "BO-001"),
            ("tickets/DASH-001.md", "DASH-001"),
        ):
            with self.subTest(logical_id=logical_id):
                fixture = Fixture(*materialized_pack())
                self.addCleanup(fixture.close)
                path = fixture.base / relative
                path.write_bytes(path.read_bytes() + b"\npost-approval scope drift\n")
                report = validate(fixture.build_path, fixture.publication_path)
                self.assertIn(
                    f"current {logical_id} document must equal the approved source byte-for-byte",
                    report.errors,
                )

    def test_post_approval_root_and_skill_document_drift_fails_closed(self) -> None:
        for relative, label in (
            ("root-issue.md", "root"),
            ("skill-delivery.md", "skill"),
        ):
            with self.subTest(label=label):
                fixture = Fixture(*materialized_pack())
                self.addCleanup(fixture.close)
                path = fixture.base / relative
                path.write_bytes(path.read_bytes() + b"\npost-approval scope drift\n")
                report = validate(fixture.build_path, fixture.publication_path)
                self.assertTrue(any(
                    "must equal the approved template after approval substitution" in error
                    for error in report.errors
                ))

    def test_current_templates_require_approval_substitution(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        approved = publication["approved_planning_commit"]
        for relative in ("root-issue.md", "skill-delivery.md"):
            path = fixture.base / relative
            path.write_text(
                path.read_text(encoding="utf-8").replace("<APPROVED_SHA>", approved),
                encoding="utf-8",
            )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

        root = fixture.base / "root-issue.md"
        root.write_text(
            root.read_text(encoding="utf-8").replace(approved, "<APPROVED_SHA>"),
            encoding="utf-8",
        )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertTrue(any(
            "must equal the approved template after approval substitution" in error
            for error in report.errors
        ))

    def test_materialized_current_document_symlink_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        document = fixture.base / "tickets/DASH-001.md"
        target = fixture.base / "tickets/DASH-001-copy.md"
        target.write_bytes(document.read_bytes())
        document.unlink()
        document.symlink_to(target.name)
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertTrue(any(
            "current DASH-001 document must be a regular non-symlink file" in error
            for error in report.errors
        ))


if __name__ == "__main__":
    unittest.main()
