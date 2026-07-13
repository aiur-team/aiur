"""Approved Git object and history checks for publication sources."""

import json
import subprocess

from approved_body_helpers import ApprovedCommitCase
from validation_common import Report
from validation_github_approved import render_approved_build_order


class ApprovedGitSourceTests(ApprovedCommitCase):
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

    def test_approved_documents_require_issue_title_h1(self) -> None:
        self.ticket_document.write_text("No H1\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "pack"], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "bad title"], check=True)
        bad_sha = subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        report = Report()
        self.assertIsNone(render_approved_build_order(
            self.root, bad_sha, "pack/build-order.json", "pack/root.md",
            self.current, report,
        ))
        self.assertIn(
            "must start with one non-empty H1 issue title",
            "\n".join(report.errors),
        )

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
    import unittest

    unittest.main()
