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


class ApprovedCommitCase(unittest.TestCase):
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
