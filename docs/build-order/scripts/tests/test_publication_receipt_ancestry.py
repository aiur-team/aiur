"""Final-comment verification tests: trusted branch, grafts and receipt ancestry."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import patch

from publication_rendering_case import FinalCommentCase
from publication_comment import (
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report
from publication_receipt_authority import (
    _commit_blob,
    load_receipt_authority,
    MAX_RECEIPT_FILE_BYTES,
    ReceiptBlobBudget,
)
from publication_fixtures import Fixture
from publication_materialized_fixture import materialized_pack


class ReceiptAncestryTests(FinalCommentCase):
    def test_receipt_and_approval_must_remain_on_trusted_branch(self) -> None:
        _, _, _, comment_url, body = self.values()
        checked: list[tuple[str, str, str, str]] = []

        def remote_ref_contains(
            repository: str, trusted_ref: str,
            approved: str, receipt: str,
        ) -> bool:
            checked.append((repository, trusted_ref, approved, receipt))
            return False

        report = self.report(
            [{"url": comment_url, "body": body}],
            remote_ref_contains=remote_ref_contains,
        )
        self.assertEqual(
            [
                (
                    self.repository,
                    "refs/heads/build-order-research",
                    self.approved,
                    self.receipt,
                ),
            ],
            checked,
        )
        self.assertIn(
            "receipt_commit must descend from approved_planning_commit and both "
            "must remain ancestors of configured GitHub repository branch "
            f"{self.repository}:refs/heads/build-order-research",
            report.errors,
        )

    def test_trusted_branch_change_during_live_verification_fails(self) -> None:
        _, _, _, comment_url, body = self.values()
        outcomes = iter((True, False))
        checks: list[tuple[str, str, str, str]] = []

        def remote_ref_contains(
            repository: str, trusted_ref: str,
            approved: str, receipt: str,
        ) -> bool:
            checks.append((repository, trusted_ref, approved, receipt))
            return next(outcomes)

        report = self.report(
            [{"url": comment_url, "body": body}],
            remote_ref_contains=remote_ref_contains,
        )
        self.assertEqual(2, len(checks))
        self.assertIn(
            "receipt_commit must descend from approved_planning_commit and both "
            "must remain ancestors of configured GitHub repository branch "
            f"{self.repository}:refs/heads/build-order-research",
            report.errors,
        )

    def test_replace_ref_cannot_promote_unmaterialized_commit(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        receipt = fixture.commit_materialized()
        assert fixture.approved_commit is not None
        unmaterialized = fixture.approved_commit
        subprocess.run(
            [
                "git", "-C", str(fixture.base), "replace",
                unmaterialized, receipt,
            ],
            check=True,
        )
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        repository = materialized_build["repository"]
        root_id = materialized_build["build_order_id"]
        plan_version = materialized_build["plan_version"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = (
            f"https://github.com/{repository}/commit/{unmaterialized}"
        )
        body = render_successful_comment(
            root_id, plan_version, unmaterialized, repository,
            unmaterialized, receipt_url,
        )
        report = Report()
        with patch("publication_comment.verify_live_graph", return_value=True):
            validate_final_comment_matches(
                root_id, plan_version, unmaterialized, unmaterialized,
                receipt_url, root_url, repository, report,
                repository_anchor=fixture.build_path,
                remote_ref_contains=self.remote_ref_contains,
            )
        self.assertIn(
            "receipt commit build-order.json github_reconciliation must be materialized",
            report.errors,
        )

    def test_unmaterialized_local_commit_cannot_be_receipt(self) -> None:
        assert self.fixture.approved_commit is not None
        receipt = self.fixture.approved_commit
        receipt_url = f"https://github.com/{self.repository}/commit/{receipt}"
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            receipt, receipt_url,
        )
        report = self.report(
            [{"url": self.root_url + "#issuecomment-123", "body": body}],
            receipt=receipt, receipt_url=receipt_url,
        )
        for name in ("build-order.json", "publication.json"):
            self.assertIn(
                f"receipt commit {name} github_reconciliation must be materialized",
                report.errors,
            )

        path = "docs/build-order/tickets/BO-001.md"
        tree = subprocess.CompletedProcess(
            ["git"], 0,
            f"100644 blob {'a' * 40}\t{path}\0".encode(), b"",
        )
        oversized = subprocess.CompletedProcess(
            ["git"], 0, str(MAX_RECEIPT_FILE_BYTES + 1), "",
        )
        report = Report()
        with patch(
            "publication_receipt_authority.run_authority_git",
            side_effect=[tree, oversized],
        ) as git_read:
            blob = _commit_blob(
                Path("."), "b" * 40, path, "ticket", ReceiptBlobBudget(), report,
            )
        self.assertIsNone(blob)
        self.assertIn("per-file byte bound", "\n".join(report.errors))
        self.assertEqual(2, git_read.call_count)

        for budget, needle in (
            (ReceiptBlobBudget(files_remaining=0), "file-count bound"),
            (ReceiptBlobBudget(bytes_remaining=0), "aggregate byte bound"),
        ):
            with self.subTest(bound=needle):
                report = Report()
                responses = [
                    tree,
                    subprocess.CompletedProcess(["git"], 0, "1", ""),
                ]
                with patch(
                    "publication_receipt_authority.run_authority_git",
                    side_effect=responses,
                ):
                    self.assertIsNone(_commit_blob(
                        Path("."), "b" * 40, path, "ticket", budget, report,
                    ))
                self.assertIn(needle, "\n".join(report.errors))

    def test_legacy_graft_cannot_promote_an_orphan_receipt(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        receipt = fixture.commit_materialized()
        assert fixture.approved_commit is not None
        tree = subprocess.run(
            ["git", "-C", str(fixture.base), "rev-parse", f"{receipt}^{{tree}}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        orphan = subprocess.run(
            ["git", "-C", str(fixture.base), "commit-tree", tree, "-m", "orphan receipt"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        graft = fixture.base / ".git" / "info" / "grafts"
        graft.write_text(
            f"{orphan} {fixture.approved_commit}\n", encoding="utf-8"
        )

        report = Report()
        authority = load_receipt_authority(
            orphan, fixture.build_path, report, lambda *_args: True,
        )
        self.assertIsNone(authority)
        self.assertTrue(any(
            "legacy Git graft authority is forbidden" in error
            for error in report.errors
        ))

    def test_graft_introduced_during_remote_proof_is_rejected(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        receipt = fixture.commit_materialized()
        graft = fixture.base / ".git" / "info" / "grafts"

        def introduce_graft(*_args) -> bool:
            graft.write_text("", encoding="utf-8")
            return True

        report = Report()
        authority = load_receipt_authority(
            receipt, fixture.build_path, report, introduce_graft,
        )
        self.assertIsNone(authority)
        self.assertTrue(any(
            "legacy Git graft authority is forbidden" in error
            for error in report.errors
        ))

    def test_receipt_commit_must_descend_from_approval(self) -> None:
        tree = subprocess.run(
            [
                "git", "-C", str(self.fixture.base), "rev-parse",
                f"{self.receipt}^{{tree}}",
            ],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        orphan = subprocess.run(
            [
                "git", "-C", str(self.fixture.base), "commit-tree", tree,
                "-m", "orphan receipt",
            ],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        receipt_url = f"https://github.com/{self.repository}/commit/{orphan}"
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            orphan, receipt_url,
        )
        report = self.report(
            [{"url": self.root_comment_url, "body": body}],
            receipt=orphan, receipt_url=receipt_url,
        )
        self.assertIn(
            "receipt_commit must descend from approved_planning_commit in the "
            "no-substitution repository graph",
            report.errors,
        )
