"""Approved-commit body rendering and receipt-binding tests."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import SCRIPT_DIR  # also installs the scripts import path
from validation_common import Report
from validation_github_approved import render_approved_build_order
from validation_github_rendering import (
    approved_link,
    authority_preamble,
    inspect_issue_body,
)


APPROVED = "a" * 40
REPOSITORY = "example/repo"
ROOT_ID = "example/repo:root"


class RenderingTests(unittest.TestCase):
    def canonical(self) -> str:
        return authority_preamble(REPOSITORY, ROOT_ID, 1, APPROVED) + "# Root\n"

    def errors(self, body: str) -> str:
        report = Report()
        inspect_issue_body(body, REPOSITORY, ROOT_ID, 1, APPROVED, report, "body")
        return "\n".join(report.errors)

    def test_canonical_body_has_exact_marker_link_and_hash(self) -> None:
        report = Report()
        evidence = inspect_issue_body(
            self.canonical(), REPOSITORY, ROOT_ID, 1, APPROVED, report, "body"
        )
        self.assertEqual([], report.errors)
        self.assertEqual(1, evidence["marker_count"])
        self.assertEqual(1, evidence["approved_link_count"])
        self.assertEqual(64, len(evidence["body_sha256"]))

    def test_missing_wrong_and_duplicate_markers_fail(self) -> None:
        canonical = self.canonical()
        marker = canonical[canonical.index("<!-- aiur-planning-issue"):canonical.index("-->") + 3]
        self.assertIn("exactly one schema-2", self.errors(canonical.replace(marker, "")))
        self.assertIn("schema must equal 2", self.errors(canonical.replace('"schema":2', '"schema":1')))
        self.assertIn("exactly one schema-2", self.errors(canonical + "\n" + marker))

    def test_missing_wrong_and_duplicate_approved_links_fail(self) -> None:
        canonical = self.canonical()
        link = approved_link(REPOSITORY, APPROVED)
        self.assertIn("exactly one approved commit link", self.errors(canonical.replace(link, "")))
        self.assertIn(
            "approved link must equal",
            self.errors(canonical.replace(link, approved_link(REPOSITORY, "b" * 40))),
        )
        self.assertIn("exactly one approved commit link", self.errors(canonical + "\n" + link))


class ApprovedCommitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "Test"], check=True)
        pack = self.root / "pack"
        (pack / "tickets").mkdir(parents=True)
        self.ticket_document = pack / "tickets/BO-001.md"
        self.root_document = pack / "root.md"
        self.current = {
            "repository": REPOSITORY,
            "plan_version": 1,
            "build_order_id": ROOT_ID,
            "tickets": [{"id": "BO-001", "document": "tickets/BO-001.md"}],
        }
        (pack / "build-order.json").write_text(json.dumps(self.current), encoding="utf-8")
        self.ticket_document.write_text("# BO-001\n", encoding="utf-8")
        self.root_template = (
            "# Root\n\n"
            "[`<APPROVED_SHA>`](https://github.com/example/repo/commit/<APPROVED_SHA>)\n\n"
            "<!-- aiur-planning-issue\n"
            '{"schema":2,"logical_id":"example/repo:root","plan_version":1,'
            '"approved_planning_commit":"<APPROVED_SHA>"}\n'
            "-->\n"
        )
        self.root_document.write_text(self.root_template, encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "pack"], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "approved"], check=True)
        self.sha = subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        self.root_document.write_text(
            self.root_template.replace("<APPROVED_SHA>", self.sha), encoding="utf-8",
        )

    def render(self, root_document: str = "pack/root.md"):
        report = Report()
        expected = render_approved_build_order(
            self.root, self.sha, "pack/build-order.json", root_document,
            self.current, report,
        )
        return expected, report

    def test_loads_approved_sources_and_allows_root_substitution(self) -> None:
        expected, report = self.render()
        self.assertEqual([], report.errors)
        self.assertEqual({ROOT_ID, "BO-001"}, set(expected))

    def test_rejects_current_ticket_document_drift(self) -> None:
        self.ticket_document.write_text("# BO-001 drifted\n", encoding="utf-8")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn(
            "current BO-001 document must exactly match its approved source",
            "\n".join(report.errors),
        )

    def test_rejects_current_root_document_drift(self) -> None:
        self.root_document.write_text("# Root drifted\n", encoding="utf-8")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn(
            "current root document must exactly match its approved source",
            "\n".join(report.errors),
        )

    def test_missing_current_documents_fail_closed(self) -> None:
        for path, label in (
            (self.ticket_document, "current BO-001 document is absent"),
            (self.root_document, "current root document is absent"),
        ):
            with self.subTest(path=path):
                source = path.read_bytes()
                path.unlink()
                try:
                    expected, report = self.render()
                    self.assertIsNone(expected)
                    self.assertIn(label, "\n".join(report.errors))
                finally:
                    path.write_bytes(source)

    def test_rejects_unsafe_and_symlinked_current_paths(self) -> None:
        for path in ("../root.md", "./pack/root.md", "pack/../root.md", "/tmp/root.md", "."):
            with self.subTest(path=path):
                expected, report = self.render(path)
                self.assertIsNone(expected)
                self.assertIn(
                    "must be a safe repository-relative path", "\n".join(report.errors),
                )

        source = self.ticket_document.read_bytes()
        self.ticket_document.unlink()
        self.ticket_document.symlink_to(self.root_document)
        try:
            expected, report = self.render()
            self.assertIsNone(expected)
            self.assertIn("current BO-001 document must not be a symlink", "\n".join(report.errors))
        finally:
            self.ticket_document.unlink()
            self.ticket_document.write_bytes(source)

    def test_rejects_unreadable_current_document(self) -> None:
        self.ticket_document.write_bytes(b"\xff")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn("current BO-001 document must be readable UTF-8", "\n".join(report.errors))

    def test_missing_approved_pack_and_document_fail_closed(self) -> None:
        report = Report()
        self.assertIsNone(render_approved_build_order(
            self.root, self.sha, "missing/build-order.json", "pack/root.md",
            self.current, report,
        ))
        self.assertIn("absent from approved commit", "\n".join(report.errors))
        report = Report()
        self.assertIsNone(render_approved_build_order(
            self.root, self.sha, "pack/build-order.json", "pack/missing.md",
            self.current, report,
        ))
        self.assertIn("approved root document is absent", "\n".join(report.errors))

    def test_rejects_post_approval_planning_drift(self) -> None:
        changed = json.loads(json.dumps(self.current))
        changed["tickets"][0]["document"] = "tickets/changed.md"
        report = Report()
        render_approved_build_order(
            self.root, self.sha, "pack/build-order.json", "pack/root.md",
            changed, report,
        )
        self.assertIn(
            "planning fields must equal the approved commit",
            "\n".join(report.errors),
        )

    def test_git_replace_cannot_substitute_approved_sources(self) -> None:
        self.ticket_document.write_text("# BO-001 substituted\n", encoding="utf-8")
        self.root_document.write_text(self.root_template, encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "pack"], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "commit", "-qm", "substitute"],
            check=True,
        )
        substitute = subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        self.root_document.write_text(
            self.root_template.replace("<APPROVED_SHA>", self.sha),
            encoding="utf-8",
        )
        subprocess.run(
            ["git", "-C", str(self.root), "replace", self.sha, substitute],
            check=True, capture_output=True,
        )
        try:
            expected, report = self.render()
        finally:
            subprocess.run(
                ["git", "-C", str(self.root), "replace", "-d", self.sha],
                check=True, capture_output=True,
            )
        self.assertIsNone(expected)
        self.assertIn(
            "current BO-001 document must exactly match its approved source",
            report.errors,
        )


if __name__ == "__main__":
    unittest.main()
