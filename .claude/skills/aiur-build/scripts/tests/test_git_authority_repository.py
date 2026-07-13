"""Repository and clean-clone publication-authority tests."""

import os
import subprocess
from pathlib import Path
from unittest.mock import patch

from git_authority_helpers import GitAuthorityCase, TRUSTED_REF
from validation_common import Report
from validation_git_authority import (
    _clean_clone_proves_ancestor,
    _reject_legacy_grafts,
    _validate_trusted_repository_commits,
)
from validation_git_repository import _github_origin_repository


class RepositoryAuthorityTests(GitAuthorityCase):
    def test_remote_lookup_timeout_fails_closed(self) -> None:
        report = Report()
        with patch(
            "validation_git_bounded.subprocess.Popen",
            side_effect=subprocess.TimeoutExpired(["git"], 30),
        ):
            self.assertIsNone(_github_origin_repository(self.root, report))
        self.assertIn(
            "requires a configured GitHub origin", "\n".join(report.errors),
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
            "validation_git_remote._github_clone_url",
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
        with patch("validation_git_repository.os.lstat", side_effect=fail_graft):
            self.assertFalse(_reject_legacy_grafts(self.root, report))
        self.assertIn(
            "cannot inspect legacy Git graft entry", "\n".join(report.errors)
        )


if __name__ == "__main__":
    import unittest

    unittest.main()
