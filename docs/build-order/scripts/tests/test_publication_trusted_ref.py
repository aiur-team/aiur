"""Trusted repository ref and bounded authority read tests."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from publication_rendering_case import compare_payload, ref_payload, REPOSITORY
from publication_common import Report, valid_trusted_branch_ref
from publication_receipt_authority import (
    _github_json,
    _github_repository_ref_contains,
    GITHUB_TIMEOUT_SECONDS,
)
from publication_rendering import (
    AUTHORITY_GIT_TIMEOUT_SECONDS,
    reject_legacy_grafts,
    run_authority_git,
)


class TrustedRepositoryRefTests(unittest.TestCase):
    def test_only_exact_repository_branch_refs_are_accepted(self) -> None:
        self.assertTrue(valid_trusted_branch_ref("refs/heads/build-order-research"))
        for value in (
            "build-order-research", "refs/pull/1/head", "refs/tags/receipt",
            "refs/remotes/origin/main", "refs/heads/../main",
            "refs/heads/a..b", "refs/heads/a.lock", "refs/heads/a@{1}",
        ):
            with self.subTest(value=value):
                self.assertFalse(valid_trusted_branch_ref(value))

    @patch("publication_receipt_authority._github_json")
    def test_tip_and_ancestor_are_bound_to_one_unchanged_ref(self, query) -> None:
        trusted_ref = "refs/heads/build-order-research"
        approved, receipt = "a" * 40, "b" * 40
        query.side_effect = [
            ref_payload(trusted_ref, receipt),
            compare_payload(approved, receipt),
            compare_payload(approved, receipt),
            compare_payload(receipt, receipt),
            ref_payload(trusted_ref, receipt),
        ]
        self.assertTrue(_github_repository_ref_contains(
            REPOSITORY, trusted_ref, approved, receipt
        ))

    @patch("publication_receipt_authority._github_json")
    def test_unordered_receipt_is_rejected_even_when_both_reach_tip(self, query) -> None:
        trusted_ref = "refs/heads/trunk"
        approved, receipt, target = "a" * 40, "b" * 40, "c" * 40
        query.side_effect = [
            ref_payload(trusted_ref, target),
            compare_payload(approved, receipt, valid=False),
            compare_payload(approved, target),
            compare_payload(receipt, target),
            ref_payload(trusted_ref, target),
        ]
        self.assertFalse(_github_repository_ref_contains(
            REPOSITORY, trusted_ref, approved, receipt
        ))

    @patch("publication_receipt_authority._github_json")
    def test_diverged_commit_is_rejected_even_when_object_visible(self, query) -> None:
        trusted_ref = "refs/heads/trunk"
        approved, receipt, target = "a" * 40, "b" * 40, "c" * 40
        query.side_effect = [
            ref_payload(trusted_ref, target),
            compare_payload(approved, receipt),
            compare_payload(approved, target),
            compare_payload(receipt, target, valid=False),
            ref_payload(trusted_ref, target),
        ]
        self.assertFalse(_github_repository_ref_contains(
            REPOSITORY, trusted_ref, approved, receipt
        ))

    @patch("publication_receipt_authority._github_json")
    def test_ref_change_or_deletion_during_query_fails_closed(self, query) -> None:
        trusted_ref = "refs/heads/build-order-research"
        target = "e" * 40
        for final in (ref_payload(trusted_ref, "f" * 40), None):
            with self.subTest(final=final):
                query.reset_mock(side_effect=True)
                query.side_effect = [
                    ref_payload(trusted_ref, target),
                    compare_payload("a" * 40, "b" * 40),
                    compare_payload("a" * 40, target),
                    compare_payload("b" * 40, target),
                    final,
                ]
                self.assertFalse(_github_repository_ref_contains(
                    REPOSITORY, trusted_ref, "a" * 40, "b" * 40
                ))

    def test_authority_reads_pin_github_despite_gh_host_and_timeout(self) -> None:
        completed = subprocess.CompletedProcess([], 0, "{}", "")
        with patch.dict(os.environ, {"GH_HOST": "attacker.example"}), patch(
            "publication_receipt_authority.subprocess.run",
            return_value=completed,
        ) as run:
            self.assertEqual({}, _github_json("repos/example/repo"))
        argv = run.call_args.args[0]
        self.assertEqual("github.com", argv[argv.index("--hostname") + 1])
        self.assertEqual(GITHUB_TIMEOUT_SECONDS, run.call_args.kwargs["timeout"])

        with patch(
            "publication_receipt_authority.subprocess.run",
            side_effect=subprocess.TimeoutExpired(
                ["gh", "api"], GITHUB_TIMEOUT_SECONDS,
            ),
        ):
            self.assertIsNone(_github_json("repos/example/repo"))

        with patch(
            "publication_rendering_sections.subprocess.run",
            side_effect=subprocess.TimeoutExpired(
                ["git", "status"], AUTHORITY_GIT_TIMEOUT_SECONDS,
            ),
        ) as git_run:
            result = run_authority_git(
                ["git", "status"], check=False, capture_output=True,
            )
        self.assertEqual(124, result.returncode)
        self.assertEqual(
            AUTHORITY_GIT_TIMEOUT_SECONDS, git_run.call_args.kwargs["timeout"],
        )

    def test_graft_audit_covers_worktree_common_dir_and_entry_types(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name) / "repository"
            linked = Path(name) / "linked"
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "test@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Test"],
                check=True,
            )
            (root / "tracked").write_text("test\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "tracked"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "initial"], check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "worktree", "add", "-q", "--detach", str(linked)],
                check=True,
            )

            directories = subprocess.run(
                ["git", "-C", str(linked), "rev-parse", "--git-dir", "--git-common-dir"],
                check=True, capture_output=True, text=True,
            ).stdout.splitlines()
            paths = []
            for raw in directories:
                directory = Path(raw)
                if not directory.is_absolute():
                    directory = linked / directory
                paths.append(directory / "info" / "grafts")
            self.assertEqual(2, len(set(paths)))
            for index, graft in enumerate(paths):
                with self.subTest(index=index):
                    graft.parent.mkdir(parents=True, exist_ok=True)
                    if index == 0:
                        graft.symlink_to("missing-graft-target")
                    else:
                        graft.mkdir()
                    report = Report()
                    self.assertFalse(reject_legacy_grafts(linked, report))
                    self.assertTrue(any(
                        "legacy Git graft authority is forbidden" in error
                        for error in report.errors
                    ))
                    if graft.is_symlink():
                        graft.unlink()
                    else:
                        graft.rmdir()
