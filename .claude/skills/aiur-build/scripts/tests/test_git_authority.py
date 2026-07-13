"""Trusted GitHub branch reachability tests for live publication gates."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from helpers import EXAMPLE, SCRIPT_DIR  # installs the scripts import path
from validation_common import Report
from validation_github_api import GITHUB_API_VERSION, GITHUB_TIMEOUT_SECONDS
from validation_git_authority import (
    _clean_clone_proves_ancestor,
    _github_compare_proves_ancestor,
    _reject_legacy_grafts,
    _validate_trusted_repository_commits,
    validate_publication_commit_authority,
)


TRUSTED_REF = "refs/heads/build-order-research"


class TrustedRepositoryRefTests(unittest.TestCase):
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
                self.root,
                "example/repo",
                "pack/publication.json",
                approved,
                receipt,
                report,
                lambda _root, _ref, _report: self.target,
                self.github_order,
                self.clean_order,
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
            self.github_order,
            self.clean_order,
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

    def test_legacy_graft_file_cannot_authorize_history(self) -> None:
        unrelated_receipt, merged_target = self.unrelated_receipt_and_tip()
        grafts = self.root / ".git/info/grafts"
        grafts.parent.mkdir(parents=True, exist_ok=True)
        grafts.write_text(
            f"{unrelated_receipt} {self.approved}\n", encoding="utf-8"
        )
        report = Report()
        _validate_trusted_repository_commits(
            self.root,
            "example/repo",
            TRUSTED_REF,
            self.approved,
            unrelated_receipt,
            report,
            lambda _root, _ref, _report: merged_target,
            self.github_order,
            self.clean_order,
        )
        self.assertIn(
            "legacy Git graft entry is forbidden for publication authority",
            "\n".join(report.errors),
        )

    def test_linked_worktree_rejects_common_dir_graft_file(self) -> None:
        linked = self.base / "linked"
        self.git(
            "worktree", "add", "-q", "-b", "linked-authority",
            str(linked), self.target,
        )
        common_dir = Path(self.git_output("rev-parse", "--git-common-dir"))
        if not common_dir.is_absolute():
            common_dir = self.root / common_dir
        grafts = common_dir.resolve() / "info/grafts"
        grafts.parent.mkdir(parents=True, exist_ok=True)
        grafts.write_text(
            f"{self.receipt} {self.approved}\n", encoding="utf-8"
        )
        report = Report()
        _validate_trusted_repository_commits(
            linked,
            "example/repo",
            TRUSTED_REF,
            self.approved,
            self.receipt,
            report,
            lambda _root, _ref, _report: self.target,
            self.github_order,
            self.clean_order,
        )
        self.assertIn(
            str(grafts),
            "\n".join(report.errors),
        )

    def test_github_directly_rejects_unordered_publication_commits(self) -> None:
        unrelated_receipt, merged_target = self.unrelated_receipt_and_tip()
        comparisons: list[tuple[str, str, str]] = []

        def reject(
            _root: Path, repository: str, approved: str, receipt: str,
            _report: Report,
        ) -> bool:
            comparisons.append((repository, approved, receipt))
            return False

        report = Report()
        _validate_trusted_repository_commits(
            self.root,
            "example/repo",
            TRUSTED_REF,
            self.approved,
            unrelated_receipt,
            report,
            lambda _root, _ref, _report: merged_target,
            reject,
            self.clean_order,
        )
        self.assertFalse(
            any("reachable from trusted" in item for item in report.errors)
        )
        self.assertEqual(
            [("example/repo", self.approved, unrelated_receipt)], comparisons
        )
        self.assertIn(
            "GitHub must prove approved_planning_commit strictly precedes receipt_commit",
            report.errors,
        )

    def test_clean_clone_proves_order_without_source_graph(self) -> None:
        unrelated_receipt, merged_target = self.unrelated_receipt_and_tip()
        self.git("branch", "-f", "build-order-research", merged_target)
        remote = self.base / "remote.git"
        subprocess.run(
            ["git", "clone", "--bare", "-q", str(self.root), str(remote)],
            check=True,
            capture_output=True,
        )
        with patch(
            "validation_git_authority._github_clone_url",
            return_value=str(remote),
        ):
            passing = Report()
            self.assertTrue(_clean_clone_proves_ancestor(
                self.root, "example/repo", TRUSTED_REF,
                self.approved, self.receipt, passing,
            ))
            failing = Report()
            self.assertFalse(_clean_clone_proves_ancestor(
                self.root, "example/repo", TRUSTED_REF,
                self.approved, unrelated_receipt, failing,
            ))
        self.assertEqual([], passing.errors)
        self.assertEqual([], failing.errors)

    def test_nonregular_graft_entry_is_rejected(self) -> None:
        grafts = self.root / ".git/info/grafts"
        grafts.mkdir(parents=True)
        report = Report()
        self.assertFalse(_reject_legacy_grafts(self.root, report))
        self.assertIn(str(grafts), "\n".join(report.errors))

    def test_graft_lstat_error_fails_closed(self) -> None:
        real_lstat = os.lstat

        def fail_graft(path: object, *args: object, **kwargs: object) -> object:
            if Path(path).name == "grafts":
                raise PermissionError("graft raced unreadable")
            return real_lstat(path, *args, **kwargs)

        report = Report()
        with patch("validation_git_authority.os.lstat", side_effect=fail_graft):
            self.assertFalse(_reject_legacy_grafts(self.root, report))
        self.assertIn(
            "cannot inspect legacy Git graft entry", "\n".join(report.errors)
        )

    def test_github_compare_is_pinned_bounded_and_strict(self) -> None:
        payload = json.dumps(
            {
                "status": "ahead",
                "ahead_by": 1,
                "behind_by": 0,
                "base_commit": {"sha": self.approved},
                "merge_base_commit": {"sha": self.approved},
            }
        )
        completed = subprocess.CompletedProcess(["gh"], 0, payload, "")
        report = Report()
        with (
            patch.dict(os.environ, {"GH_HOST": "attacker.example"}),
            patch(
                "validation_github_api.subprocess.run",
                return_value=completed,
            ) as run,
        ):
            self.assertTrue(_github_compare_proves_ancestor(
                self.root, "example/repo", self.approved, self.receipt, report,
            ))
        self.assertEqual([], report.errors)
        arguments = run.call_args.args[0]
        self.assertEqual(
            ["--hostname", "github.com"],
            arguments[arguments.index("--hostname"):arguments.index("--hostname") + 2],
        )
        self.assertIn(f"X-GitHub-Api-Version: {GITHUB_API_VERSION}", arguments)
        self.assertEqual(GITHUB_TIMEOUT_SECONDS, run.call_args.kwargs["timeout"])
        self.assertTrue(arguments[-1].endswith(
            f"/compare/{self.approved}...{self.receipt}"
        ))
        for field, value in (
            ("status", "diverged"),
            ("ahead_by", 0),
            ("behind_by", 1),
            ("merge_base_commit", {"sha": self.receipt}),
        ):
            with self.subTest(field=field):
                rejected = json.loads(payload)
                rejected[field] = value
                completed = subprocess.CompletedProcess(
                    ["gh"], 0, json.dumps(rejected), "",
                )
                strict_report = Report()
                with patch(
                    "validation_github_api.subprocess.run",
                    return_value=completed,
                ):
                    self.assertFalse(_github_compare_proves_ancestor(
                        self.root, "example/repo", self.approved, self.receipt,
                        strict_report,
                    ))
                self.assertEqual([], strict_report.errors)

    def test_github_compare_timeout_and_os_error_fail_closed(self) -> None:
        for failure in (
            subprocess.TimeoutExpired(["gh"], GITHUB_TIMEOUT_SECONDS),
            OSError("missing gh"),
        ):
            with self.subTest(failure=type(failure).__name__):
                report = Report()
                with patch(
                    "validation_github_api.subprocess.run", side_effect=failure,
                ):
                    self.assertIsNone(_github_compare_proves_ancestor(
                        self.root, "example/repo", self.approved, self.receipt,
                        report,
                    ))
                self.assertIn("GitHub authority query failed", "\n".join(report.errors))

    def unrelated_receipt_and_tip(self) -> tuple[str, str]:
        base = self.git_output("rev-parse", f"{self.approved}^")
        self.git("switch", "-q", "--detach", base)
        self.git("commit", "--allow-empty", "-qm", "unrelated receipt")
        unrelated_receipt = self.sha()
        self.git("switch", "-q", "--detach", self.target)
        self.git(
            "merge", "--no-ff", "-q", "-m", "merge publication histories",
            unrelated_receipt,
        )
        return unrelated_receipt, self.sha()

    @staticmethod
    def github_order(
        _root: Path, _repository: str, _approved: str, _receipt: str,
        _report: Report,
    ) -> bool:
        return True

    def clean_order(
        self, _root: Path, _repository: str, _trusted_ref: str,
        approved: str, receipt: str, _report: Report,
    ) -> bool:
        return subprocess.run(
            [
                "git", "-C", str(self.root), "merge-base", "--is-ancestor",
                approved, receipt,
            ],
            check=False,
            capture_output=True,
        ).returncode == 0

    def git(self, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            check=True,
            capture_output=True,
        )

    def sha(self) -> str:
        return self.git_output("rev-parse", "HEAD")

    def git_output(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.root), *arguments],
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
