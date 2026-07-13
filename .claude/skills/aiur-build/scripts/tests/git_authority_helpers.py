"""Shared repository fixture for publication-authority tests."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import SCRIPT_DIR  # installs the scripts import path
from validation_common import Report
from validation_git_authority import (
    _validate_trusted_repository_commits,
    validate_publication_commit_authority,
)


TRUSTED_REF = "refs/heads/build-order-research"


class GitAuthorityCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.git("remote", "add", "origin", "git@github.com:example/repo.git")
        self.git("commit", "--allow-empty", "-qm", "base")
        self.manifest = self.root / "pack/publication.json"
        self.manifest.parent.mkdir()
        self.write_manifest(TRUSTED_REF)
        self.git("add", "pack/publication.json")
        self.git("commit", "-qm", "approved")
        self.approved = self.sha()
        self.git("commit", "--allow-empty", "-qm", "receipt")
        self.receipt = self.sha()
        self.git("commit", "--allow-empty", "-qm", "trusted tip")
        self.target = self.sha()
        self.git("branch", "build-order-research", self.target)
        self.git("switch", "-q", "--detach", self.approved)
        self.git("commit", "--allow-empty", "-qm", "fork approval")
        self.fork_approved = self.sha()
        self.git("commit", "--allow-empty", "-qm", "fork receipt")
        self.fork_receipt = self.sha()

    def validate(self, approved: object, receipt: object, ref: object = TRUSTED_REF) -> Report:
        report = Report()
        if ref == TRUSTED_REF:
            validate_publication_commit_authority(
                self.root, "example/repo", "pack/publication.json",
                approved, receipt, report,
                lambda _root, _ref, _report: self.target,
                self.github_order, self.clean_order,
            )
            return report
        _validate_trusted_repository_commits(
            self.root, "example/repo", ref, approved, receipt, report,
            lambda _root, _ref, _report: self.target,
            self.github_order, self.clean_order,
        )
        return report

    def unrelated_receipt_and_tip(self) -> tuple[str, str]:
        base = self.git_output("rev-parse", f"{self.approved}^")
        self.git("switch", "-q", "--detach", base)
        self.git("commit", "--allow-empty", "-qm", "unrelated receipt")
        unrelated_receipt = self.sha()
        self.git("switch", "-q", "--detach", self.target)
        self.git("merge", "--no-ff", "-q", "-m", "merge histories", unrelated_receipt)
        return unrelated_receipt, self.sha()

    @staticmethod
    def github_order(*_arguments: object) -> bool:
        return True

    def clean_order(
        self, _root: Path, _repository: str, _trusted_ref: str,
        approved: str, receipt: str, _report: Report,
    ) -> bool:
        return subprocess.run(
            ["git", "-C", str(self.root), "merge-base", "--is-ancestor", approved, receipt],
            check=False, capture_output=True,
        ).returncode == 0

    def git(self, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            check=True, capture_output=True,
        )

    def sha(self) -> str:
        return self.git_output("rev-parse", "HEAD")

    def git_output(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def write_manifest(
        self, trusted_ref: str, *, root_document: str = "pack/root.md",
    ) -> None:
        self.manifest.write_text(json.dumps({
            "trusted_repository_ref": trusted_ref,
            "root_document": root_document,
            "mutation_repositories": ["example/repo", "example/other"],
            "reference_only_issue_urls": [],
            "tracker_lifecycle_label_prefix": "agent",
        }) + "\n", encoding="utf-8")
