"""Publisher finalize-stage tests."""

from __future__ import annotations

import copy
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from publication_operator_case import (
    APPROVED,
    AuthorityFreePublisher,
    context,
    FakeClient,
    RECEIPT,
    REPOSITORY,
    ROOT,
)
from publication_operator import Client, Context, PublicationError, Publisher
from publication_comment import render_pending_comment, render_successful_comment
from publication_receipt_authority import ReceiptAuthority


class FinalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.ctx = context(Path(self.temp.name))
        self.comment_url = (
            f"https://github.com/{REPOSITORY}/issues/1#issuecomment-44"
        )
        self.receipt_url = f"https://github.com/{REPOSITORY}/commit/{RECEIPT}"
        self.authority = ReceiptAuthority(
            repository=REPOSITORY,
            root_id=ROOT,
            plan_version=1,
            approved_commit=APPROVED,
            root_issue_url=f"https://github.com/{REPOSITORY}/issues/1",
            root_comment_url=self.comment_url,
            trusted_repository_ref="refs/heads/build-order-research",
            receipt_manifests={},
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _comment(self, state: str, comment_id: int | None = None) -> dict[str, Any]:
        comment_id = 44 if comment_id is None else comment_id
        comment_url = (
            f"https://github.com/{REPOSITORY}/issues/1"
            f"#issuecomment-{comment_id}"
        )
        body = (
            render_pending_comment(ROOT, 1, APPROVED, REPOSITORY)
            if state == "pending"
            else render_successful_comment(
                ROOT, 1, APPROVED, REPOSITORY, RECEIPT, self.receipt_url,
            )
        )
        return {"id": comment_id, "html_url": comment_url, "body": body}

    def _client(
        self, comments: list[dict[str, Any]], *, drift_after_scans: int | None = None,
    ) -> Client:
        pending_path = f"repos/{REPOSITORY}/issues/comments/44"
        comments_path = f"repos/{REPOSITORY}/issues/1/comments?per_page=100&page=1"
        create_path = f"repos/{REPOSITORY}/issues/1/comments"

        class CommentClient(FakeClient):
            scans = 0

            def request(inner, method: str, path: str, payload=None, *, allow_404=False):
                inner.calls.append((method, path, payload))
                if method == "GET" and path == pending_path:
                    return copy.deepcopy(comments[0])
                if method == "GET" and path == comments_path:
                    inner.scans += 1
                    if drift_after_scans is not None and inner.scans > drift_after_scans:
                        drifted = copy.deepcopy(comments)
                        drifted[0]["body"] = (
                            "Operator revoked finalization.\n\n" + drifted[0]["body"]
                        )
                        return drifted
                    return copy.deepcopy(comments)
                if method == "POST" and path == create_path:
                    successful = self._comment("successful", 45)
                    self.assertEqual(payload, {"body": successful["body"]})
                    comments.append(successful)
                    return copy.deepcopy(successful)
                raise AssertionError((method, path))

        return CommentClient({})

    def _publisher(
        self, client: Client, *, fail_successful_once: bool = False,
    ) -> Publisher:
        authority = self.authority

        class FinalizePublisher(AuthorityFreePublisher):
            def __init__(inner, fake: Client, ctx: Context) -> None:
                super().__init__(fake, ctx)
                inner.verifications: list[str] = []
                inner.fail_successful_once = fail_successful_once

            def _receipt_authority(inner, receipt_commit: str) -> ReceiptAuthority:
                self.assertEqual(receipt_commit, RECEIPT)
                return authority

            def _run_receipt_verifier(
                inner, state: str, value: ReceiptAuthority,
                receipt_commit: str, receipt_url: str,
            ) -> None:
                inner.verifications.append(state)
                if state == "successful" and inner.fail_successful_once:
                    inner.fail_successful_once = False
                    raise PublicationError("simulated post-create verifier failure")

        return FinalizePublisher(client, self.ctx)

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_mutable_checkout_receipt_cannot_redirect_successful_create(
        self, _git: Any, _commit: Any,
    ) -> None:
        self.ctx.publication["github_reconciliation"] = {
            "root_reconciliation_comment_matches": [{
                "url": f"https://github.com/{REPOSITORY}/issues/99#issuecomment-999",
            }],
        }
        comments = [self._comment("pending")]
        client = self._client(comments)
        result = self._publisher(client).finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["pending_comment"], self.comment_url)
        self.assertEqual(
            result["successful_comment"],
            f"https://github.com/{REPOSITORY}/issues/1#issuecomment-45",
        )
        self.assertNotIn("comments/999", [call[1] for call in client.calls])
        self.assertEqual(
            [call[1] for call in client.calls if call[0] == "POST"],
            [f"repos/{REPOSITORY}/issues/1/comments"],
        )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_already_successful_finalization_is_idempotent(
        self, _git: Any, _commit: Any,
    ) -> None:
        pending = self._comment("pending")
        successful = self._comment("successful", 45)
        client = self._client([pending, successful])
        publisher = self._publisher(client)
        result = publisher.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["mode"], "finalized")
        self.assertEqual(result["successful_comment"], successful["html_url"])
        self.assertEqual(publisher.verifications, ["successful"])
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_crash_after_create_resumes_from_successful_comment(
        self, _git: Any, _commit: Any,
    ) -> None:
        comments = [self._comment("pending")]
        client = self._client(comments)
        first = self._publisher(client, fail_successful_once=True)
        with self.assertRaisesRegex(PublicationError, "simulated post-create"):
            first.finalize(RECEIPT, self.receipt_url)
        second = self._publisher(client)
        result = second.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(result["mode"], "finalized")
        self.assertEqual(second.verifications, ["successful"])
        self.assertEqual(sum(call[0] == "POST" for call in client.calls), 1)

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_visible_pending_drift_before_create_fails_without_mutation(
        self, _git: Any, _commit: Any,
    ) -> None:
        client = self._client([self._comment("pending")], drift_after_scans=1)
        publisher = self._publisher(client)
        with self.assertRaisesRegex(
            PublicationError, "malformed or conflicting",
        ):
            publisher.finalize(RECEIPT, self.receipt_url)
        self.assertEqual(publisher.verifications, ["pending"])
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    @patch("publication_operator.exact_commit", return_value=True)
    @patch(
        "publication_operator.run_authority_git",
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    def test_malformed_conflicting_and_duplicate_evidence_fail_without_mutation(
        self, _git: Any, _commit: Any,
    ) -> None:
        pending = self._comment("pending")
        malformed = {
            "id": 45,
            "html_url": f"https://github.com/{REPOSITORY}/issues/1#issuecomment-45",
            "body": "<!-- aiur-build-order-reconciliation\nnot-json\n-->",
        }
        conflicting = self._comment("successful", 45)
        conflicting["body"] = conflicting["body"].replace(RECEIPT, "d" * 40)
        duplicate = [
            self._comment("successful", 45), self._comment("successful", 46),
        ]
        for label, evidence, message in (
            ("malformed", [malformed], "malformed or conflicting"),
            ("conflicting", [conflicting], "malformed or conflicting"),
            ("duplicate", duplicate, "duplicate successful"),
        ):
            with self.subTest(case=label):
                client = self._client([copy.deepcopy(pending), *copy.deepcopy(evidence)])
                with self.assertRaisesRegex(PublicationError, message):
                    self._publisher(client).finalize(RECEIPT, self.receipt_url)
                self.assertTrue(all(call[0] == "GET" for call in client.calls))
