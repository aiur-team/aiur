"""Trusted GitHub branch reachability tests for live publication gates."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import EXAMPLE, SCRIPT_DIR  # installs the scripts import path
from validation_common import Report
from validation_git_authority import (
    _validate_trusted_repository_commits,
    validate_publication_commit_authority,
)


TRUSTED_REF = "refs/heads/build-order-research"


class TrustedRepositoryRefTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.git("remote", "add", "origin", "git@github.com:example/repo.git")

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
                self.root,
                "example/repo",
                "pack/publication.json",
                approved,
                receipt,
                report,
                lambda _root, _ref, _report: self.target,
            )
            return report
        _validate_trusted_repository_commits(
            self.root,
            "example/repo",
            ref,
            approved,
            receipt,
            report,
            lambda _root, _ref, _report: self.target,
        )
        return report

    def test_commits_reachable_from_exact_trusted_branch_pass(self) -> None:
        self.assertEqual([], self.validate(self.approved, self.receipt).errors)

    def test_object_visible_fork_commits_do_not_gain_authority(self) -> None:
        report = self.validate(self.fork_approved, self.fork_receipt)
        self.assertIn(
            "approved_planning_commit must be reachable from trusted_repository_ref",
            "\n".join(report.errors),
        )

    def test_git_replace_cannot_rewrite_trusted_branch_ancestry(self) -> None:
        self.git("replace", self.target, self.fork_receipt)
        try:
            report = self.validate(self.fork_approved, self.fork_receipt)
        finally:
            self.git("replace", "-d", self.target)
        self.assertIn(
            "receipt_commit must be reachable from trusted_repository_ref",
            "\n".join(report.errors),
        )
        self.assertIn(
            "receipt_commit must be reachable from trusted_repository_ref",
            "\n".join(report.errors),
        )

    def test_approval_must_precede_receipt_on_trusted_history(self) -> None:
        report = self.validate(self.receipt, self.approved)
        self.assertIn(
            "approved_planning_commit must be an ancestor of receipt_commit",
            report.errors,
        )

    def test_receipt_cannot_change_approved_trusted_ref(self) -> None:
        self.git("switch", "-q", "--detach", self.receipt)
        self.write_manifest("refs/heads/attacker")
        self.git("add", "pack/publication.json")
        self.git("commit", "-qm", "tamper ref")
        tampered = self.sha()
        report = Report()
        validate_publication_commit_authority(
            self.root,
            "example/repo",
            "pack/publication.json",
            self.approved,
            tampered,
            report,
            lambda _root, _ref, _report: tampered,
        )
        self.assertIn(
            "receipt trusted_repository_ref must equal its approved value",
            report.errors,
        )

    def test_trusted_ref_movement_during_validation_fails_closed(self) -> None:
        targets = iter((self.target, self.fork_receipt))
        report = Report()
        validate_publication_commit_authority(
            self.root,
            "example/repo",
            "pack/publication.json",
            self.approved,
            self.receipt,
            report,
            lambda _root, _ref, _report: next(targets),
        )
        self.assertIn(
            "trusted_repository_ref changed or disappeared during validation",
            report.errors,
        )

    def test_start_gate_validates_pack_from_receipt_commit(self) -> None:
        current_build = self.root / "pack/build-order.json"
        current_build.write_bytes(EXAMPLE.read_bytes())
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT_DIR / "validate_build_order.py"),
                str(current_build),
                "--repository-root", str(self.root),
                "--root-document", "pack/root.md",
                "--receipt-commit", self.receipt,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("cannot read valid JSON", result.stdout)

    def test_pull_and_remote_tracking_refs_are_not_authority(self) -> None:
        for ref in ("refs/pull/1/head", "refs/remotes/origin/main", "main"):
            with self.subTest(ref=ref):
                self.assertIn(
                    "must be an exact refs/heads/... ref",
                    "\n".join(self.validate(self.approved, self.receipt, ref).errors),
                )

    def test_missing_and_non_commit_values_fail_closed(self) -> None:
        report = self.validate("not-a-sha", "f" * 40)
        self.assertIn(
            "approved_planning_commit must be a 40-character Git SHA",
            report.errors,
        )
        self.assertTrue(
            any(error.startswith("receipt_commit must resolve") for error in report.errors)
        )

    def test_materialized_repository_must_match_origin(self) -> None:
        report = Report()
        _validate_trusted_repository_commits(
            self.root,
            "attacker/repo",
            TRUSTED_REF,
            self.approved,
            self.receipt,
            report,
            lambda _root, _ref, _report: self.target,
        )
        self.assertIn(
            "materialized repository must equal configured GitHub origin example/repo",
            report.errors,
        )

    def git(self, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            check=True,
            capture_output=True,
        )

    def sha(self) -> str:
        return subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def write_manifest(self, trusted_ref: str) -> None:
        self.manifest.write_text(
            json.dumps({"trusted_repository_ref": trusted_ref}) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
