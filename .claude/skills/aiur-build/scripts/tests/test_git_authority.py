"""Local publication-authority and receipt gate tests."""

import subprocess
from unittest.mock import patch

from git_authority_helpers import GitAuthorityCase, TRUSTED_REF
from helpers import EXAMPLE, SCRIPT_DIR
from validation_common import Report
from validation_git_authority import (
    _validate_trusted_repository_commits,
    validate_publication_commit_authority,
)


class TrustedRepositoryRefTests(GitAuthorityCase):
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

    def test_approval_must_precede_receipt_on_trusted_history(self) -> None:
        report = self.validate(self.receipt, self.approved)
        self.assertIn(
            "a clean GitHub clone must prove approved_planning_commit strictly "
            "precedes receipt_commit",
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
            self.github_order,
            self.clean_order,
        )
        self.assertIn(
            "receipt publication authority must equal its approved value",
            report.errors,
        )

    def test_receipt_cannot_change_canonical_root_path(self) -> None:
        self.git("switch", "-q", "--detach", self.receipt)
        self.write_manifest(TRUSTED_REF, root_document="pack/attacker.md")
        self.git("add", "pack/publication.json")
        self.git("commit", "-qm", "tamper root")
        tampered = self.sha()
        report = Report()
        validate_publication_commit_authority(
            self.root, "example/repo", "pack/publication.json", self.approved,
            tampered, report, lambda *_args: tampered,
            self.github_order, self.clean_order,
        )
        self.assertIn(
            "receipt publication authority must equal its approved value",
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
            self.github_order,
            self.clean_order,
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
            self.github_order,
            self.clean_order,
        )
        self.assertIn(
            "materialized repository must equal configured GitHub origin example/repo",
            report.errors,
        )


if __name__ == "__main__":
    import unittest

    unittest.main()
