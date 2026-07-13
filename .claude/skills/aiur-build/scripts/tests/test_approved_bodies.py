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


if __name__ == "__main__":
    unittest.main()
