"""Canonical issue rendering and final-comment verification tests."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_comment import (  # noqa: E402
    render_pending_comment,
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report, valid_trusted_branch_ref  # noqa: E402
from publication_receipt_authority import (  # noqa: E402
    GITHUB_TIMEOUT_SECONDS,
    MAX_RECEIPT_FILE_BYTES,
    ReceiptBlobBudget,
    _commit_blob,
    _github_json,
    _github_repository_ref_contains,
    load_receipt_authority,
)
from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from publication_rendering import (  # noqa: E402
    AUTHORITY_GIT_TIMEOUT_SECONDS,
    approved_link,
    authority_preamble,
    inspect_issue_body,
    reject_legacy_grafts,
    render_approved_pack,
    render_approved_titles,
    run_authority_git,
)
from validate_publication import validate  # noqa: E402


REPOSITORY = "example/repo"
ROOT_ID = "example/repo:build-order-dashboard"
APPROVED = "a" * 40


def ref_payload(ref: str, target: str) -> dict[str, object]:
    return {"ref": ref, "object": {"type": "commit", "sha": target}}


def compare_payload(base: str, head: str, *, valid: bool = True) -> dict[str, object]:
    identical = base == head
    return {
        "base_commit": {"sha": base},
        "merge_base_commit": {"sha": base if valid else "0" * 40},
        "status": "identical" if identical else "ahead",
        "ahead_by": 0 if identical else 1,
        "behind_by": 0,
    }


def replace_repository(value, old: str, new: str):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_repository(item, old, new) for item in value]
    if isinstance(value, dict):
        return {
            replace_repository(key, old, new): replace_repository(item, old, new)
            for key, item in value.items()
        }
    return value


class IssueRenderingTests(unittest.TestCase):
    def canonical(self) -> str:
        return authority_preamble(REPOSITORY, ROOT_ID, 1, APPROVED) + "# Root\n"

    def errors(self, body: str) -> str:
        report = Report()
        inspect_issue_body(body, REPOSITORY, ROOT_ID, 1, APPROVED, report, "body")
        return "\n".join(report.errors)

    def test_missing_wrong_and_duplicate_markers_are_rejected(self) -> None:
        body = self.canonical()
        marker = body[body.index("<!-- aiur-planning-issue"):body.index("-->") + 3]
        self.assertIn("exactly one schema-2", self.errors(body.replace(marker, "")))
        self.assertIn("schema must equal 2", self.errors(body.replace('"schema":2', '"schema":1')))
        self.assertIn("exactly one schema-2", self.errors(body + marker))

    def test_missing_wrong_and_duplicate_approved_links_are_rejected(self) -> None:
        body = self.canonical()
        link = approved_link(REPOSITORY, APPROVED)
        self.assertIn("exactly one approved commit link", self.errors(body.replace(link, "")))
        self.assertIn(
            "approved link must equal",
            self.errors(body.replace(link, approved_link(REPOSITORY, "b" * 40))),
        )
        self.assertIn("exactly one approved commit link", self.errors(body + link))

    def test_absent_approved_pack_path_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        report = Report()
        expected = render_approved_pack(
            build, publication, fixture.build_path,
            fixture.base / "missing-publication.json",
            publication["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn("absent from approved commit", "\n".join(report.errors))

    def test_titles_are_derived_from_exact_approved_document_h1s(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        report = Report()
        titles = render_approved_titles(
            build, publication, fixture.build_path,
            fixture.publication_path,
            publication["approved_planning_commit"], report,
        )
        self.assertEqual([], report.errors)
        assert titles is not None
        self.assertEqual("Test root", titles[ROOT_ID])
        self.assertEqual("BO-001 — Build Order ticket 1", titles["BO-001"])
        self.assertEqual("DASH-001 — First companion", titles["DASH-001"])
        self.assertEqual("Test skill", titles["SKILL-DELIVERY-001"])
        self.assertEqual(46, len(titles))

    def test_post_approval_planning_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        build["tickets"][0]["depends_on"] = ["BO-999"]
        report = Report()
        expected = render_approved_pack(
            build, publication, fixture.build_path,
            fixture.publication_path,
            publication["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn(
            "planning fields must equal the approved commit",
            "\n".join(report.errors),
        )

    def test_post_approval_trusted_ref_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        publication["trusted_repository_ref"] = "refs/heads/other"
        fixture.publication_path.write_text(
            json.dumps(publication), encoding="utf-8"
        )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertIn(
            "materialized publication planning fields must equal the approved commit",
            report.errors,
        )

    def test_post_approval_ticket_document_drift_fails_closed(self) -> None:
        for relative, logical_id in (
            ("tickets/BO-001.md", "BO-001"),
            ("tickets/DASH-001.md", "DASH-001"),
        ):
            with self.subTest(logical_id=logical_id):
                fixture = Fixture(*materialized_pack())
                self.addCleanup(fixture.close)
                path = fixture.base / relative
                path.write_bytes(path.read_bytes() + b"\npost-approval scope drift\n")
                report = validate(fixture.build_path, fixture.publication_path)
                self.assertIn(
                    f"current {logical_id} document must equal the approved source byte-for-byte",
                    report.errors,
                )

    def test_post_approval_root_and_skill_document_drift_fails_closed(self) -> None:
        for relative, label in (
            ("root-issue.md", "root"),
            ("skill-delivery.md", "skill"),
        ):
            with self.subTest(label=label):
                fixture = Fixture(*materialized_pack())
                self.addCleanup(fixture.close)
                path = fixture.base / relative
                path.write_bytes(path.read_bytes() + b"\npost-approval scope drift\n")
                report = validate(fixture.build_path, fixture.publication_path)
                self.assertTrue(any(
                    "must equal the approved template after approval substitution" in error
                    for error in report.errors
                ))

    def test_current_templates_require_approval_substitution(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        approved = publication["approved_planning_commit"]
        for relative in ("root-issue.md", "skill-delivery.md"):
            path = fixture.base / relative
            path.write_text(
                path.read_text(encoding="utf-8").replace("<APPROVED_SHA>", approved),
                encoding="utf-8",
            )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

        root = fixture.base / "root-issue.md"
        root.write_text(
            root.read_text(encoding="utf-8").replace(approved, "<APPROVED_SHA>"),
            encoding="utf-8",
        )
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertTrue(any(
            "must equal the approved template after approval substitution" in error
            for error in report.errors
        ))

    def test_materialized_current_document_symlink_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        document = fixture.base / "tickets/DASH-001.md"
        target = fixture.base / "tickets/DASH-001-copy.md"
        target.write_bytes(document.read_bytes())
        document.unlink()
        document.symlink_to(target.name)
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertTrue(any(
            "current DASH-001 document must be a regular non-symlink file" in error
            for error in report.errors
        ))


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
            "publication_rendering.subprocess.run",
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


class FinalCommentTests(unittest.TestCase):
    @staticmethod
    def remote_ref_contains(
        _repository: str, _trusted_ref: str,
        _approved: str, _receipt: str,
    ) -> bool:
        return True

    @classmethod
    def setUpClass(cls) -> None:
        build, manifest = materialized_pack()
        cls.fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        cls.receipt = cls.fixture.commit_materialized()
        materialized_build = json.loads(
            cls.fixture.build_path.read_text(encoding="utf-8")
        )
        materialized_publication = json.loads(
            cls.fixture.publication_path.read_text(encoding="utf-8")
        )
        cls.repository = materialized_build["repository"]
        cls.root_id = materialized_build["build_order_id"]
        cls.plan_version = materialized_build["plan_version"]
        cls.approved = materialized_publication["approved_planning_commit"]
        cls.root_url = materialized_build["github_root"]["url"]
        cls.root_comment_url = materialized_publication["github_reconciliation"][
            "root_reconciliation_comment_matches"
        ][0]["url"]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture.close()

    def values(self):
        receipt_url = (
            f"https://github.com/{self.repository}/commit/{self.receipt}"
        )
        comment_url = self.root_comment_url
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            self.receipt, receipt_url,
        )
        return self.receipt, receipt_url, self.root_url, comment_url, body

    def report(
        self, matches, receipt=None, receipt_url=None, root_id=None,
        plan_version=None, approved=None, root_url=None, repository=None,
        repository_anchor=None, remote_ref_contains=None,
    ):
        baseline_receipt, baseline_url, _, _, _ = self.values()
        report = Report()
        def verify(authority, _receipt, expected_body, live_report):
            if not isinstance(matches, list) or len(matches) != 1:
                live_report.error(
                    "live GitHub reconciliation comment must contain exactly one "
                    "comment match"
                )
                return False
            item = matches[0]
            if not isinstance(item, dict):
                live_report.error("live GitHub reconciliation comment is malformed")
                return False
            if item.get("url") != authority.root_comment_url:
                live_report.error(
                    "live GitHub comment must equal the exact pending comment URL "
                    "recorded in the immutable receipt"
                )
            body = item.get("body")
            if body != expected_body:
                if isinstance(body, str) and body.count(
                    "<!-- aiur-build-order-reconciliation"
                ) != 1:
                    live_report.error(
                        "live GitHub comment must contain exactly one "
                        "aiur-build-order-reconciliation marker"
                    )
                else:
                    live_report.error(
                        "live GitHub comment must equal the canonical successful receipt"
                    )
            return not live_report.errors

        with patch("publication_comment.verify_live_graph", side_effect=verify):
            validate_final_comment_matches(
                self.root_id if root_id is None else root_id,
                self.plan_version if plan_version is None else plan_version,
                self.approved if approved is None else approved,
                baseline_receipt if receipt is None else receipt,
                baseline_url if receipt_url is None else receipt_url,
                self.root_url if root_url is None else root_url,
                self.repository if repository is None else repository,
                report,
                repository_anchor=repository_anchor or self.fixture.build_path,
                remote_ref_contains=(
                    remote_ref_contains or self.remote_ref_contains
                ),
            )
        return report

    def test_exact_successful_comment_is_clean(self) -> None:
        _, _, _, url, body = self.values()
        self.assertEqual([], self.report([{"url": url, "body": body}]).errors)

    def test_production_verifier_uses_exact_receipt_comment_url(self) -> None:
        _, _, _, url, body = self.values()
        report = self.report([{"url": url, "body": body}])
        self.assertEqual([], report.errors)

    def test_other_comment_on_same_root_cannot_replace_pending_comment(self) -> None:
        _, _, _, url, body = self.values()
        wrong_url = url.rsplit("-", 1)[0] + "-999"
        self.assertIn(
            "must equal the exact pending comment URL recorded in the immutable receipt",
            "\n".join(
                self.report([{"url": wrong_url, "body": body}]).errors
            ),
        )

    def test_duplicate_comment_matches_fail(self) -> None:
        _, _, _, url, body = self.values()
        item = {"url": url, "body": body}
        self.assertIn(
            "exactly one comment match", "\n".join(self.report([item, dict(item)]).errors)
        )

    def test_pending_state_and_duplicate_marker_fail_final_verification(self) -> None:
        _, _, _, url, body = self.values()
        pending = render_pending_comment(
            self.root_id, self.plan_version, self.approved, self.repository
        )
        self.assertIn(
            "canonical successful receipt",
            "\n".join(self.report([{"url": url, "body": pending}]).errors),
        )
        marker = body[body.index("<!-- aiur-build-order-reconciliation"):]
        self.assertIn(
            "exactly one aiur-build-order-reconciliation marker",
            "\n".join(self.report([{"url": url, "body": body + marker}]).errors),
        )

    def test_nonexistent_receipt_commit_fails_final_verification(self) -> None:
        missing = "0" * 40
        receipt_url = f"https://github.com/{self.repository}/commit/{missing}"
        _, _, _, comment_url, _ = self.values()
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            missing, receipt_url,
        )
        report = self.report(
            [{"url": comment_url, "body": body}],
            receipt=missing, receipt_url=receipt_url,
        )
        self.assertIn(
            "receipt_commit must resolve to an exact commit in this repository",
            report.errors,
        )

    def test_malformed_receipt_url_fails_final_verification(self) -> None:
        receipt, canonical_url, _, comment_url, _ = self.values()
        urls = (
            f"https://evil.example/receipts/{receipt}",
            canonical_url + "?not-the-commit-object",
        )
        for receipt_url in urls:
            with self.subTest(receipt_url=receipt_url):
                body = render_successful_comment(
                    self.root_id, self.plan_version, self.approved,
                    self.repository, receipt, receipt_url,
                )
                report = self.report(
                    [{"url": comment_url, "body": body}],
                    receipt_url=receipt_url,
                )
                self.assertIn(
                    f"receipt_url must equal {canonical_url}", report.errors
                )

    def test_caller_consistent_foreign_authority_is_rejected(self) -> None:
        foreign_repository = "attacker/fork"
        foreign_root_id = "attacker/fork:build-order-dashboard"
        foreign_root_url = "https://github.com/attacker/fork/issues/901"
        receipt_url = (
            f"https://github.com/{foreign_repository}/commit/{self.receipt}"
        )
        body = render_successful_comment(
            foreign_root_id, self.plan_version, self.approved,
            foreign_repository, self.receipt, receipt_url,
        )
        report = self.report(
            [{"url": foreign_root_url + "#issuecomment-123", "body": body}],
            receipt_url=receipt_url,
            root_id=foreign_root_id,
            root_url=foreign_root_url,
            repository=foreign_repository,
        )
        joined = "\n".join(report.errors)
        self.assertIn("repository must equal receipt authority value", joined)
        self.assertIn("root_id must equal receipt authority value", joined)
        self.assertIn("root_issue_url must equal receipt authority value", joined)

    def test_nonexistent_caller_approval_is_rejected(self) -> None:
        missing = "0" * 40
        _, receipt_url, _, comment_url, _ = self.values()
        body = render_successful_comment(
            self.root_id, self.plan_version, missing, self.repository,
            self.receipt, receipt_url,
        )
        report = self.report(
            [{"url": comment_url, "body": body}], approved=missing,
        )
        self.assertTrue(any(
            "approved planning commit must equal receipt authority value" in error
            for error in report.errors
        ))

    def test_receipt_with_nonexistent_approval_is_rejected(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        missing = "0" * 40
        path = fixture.publication_path
        value = json.loads(path.read_text(encoding="utf-8"))
        value["approved_planning_commit"] = missing
        path.write_text(json.dumps(value), encoding="utf-8")
        receipt = fixture.commit_materialized()
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        repository = build["repository"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            materialized_build["build_order_id"], build["plan_version"], missing,
            repository, receipt, receipt_url,
        )
        report = Report()
        with patch("publication_comment.verify_live_graph", return_value=True):
            validate_final_comment_matches(
                materialized_build["build_order_id"], build["plan_version"], missing,
                receipt, receipt_url, root_url, repository, report,
                repository_anchor=fixture.build_path,
                remote_ref_contains=self.remote_ref_contains,
            )
        self.assertTrue(any(
            "approved_planning_commit must resolve to an exact commit" in error
            for error in report.errors
        ))

    def test_foreign_materialized_receipt_cannot_override_origin(self) -> None:
        build, manifest = materialized_pack()
        build, manifest = (
            replace_repository(item, "example/repo", "attacker/fork")
            for item in (build, manifest)
        )
        fixture = Fixture(
            build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        receipt = fixture.commit_materialized()
        subprocess.run(
            [
                "git", "-C", str(fixture.base), "remote", "set-url", "origin",
                "git@github.com:its-everdred/aiur.git",
            ],
            check=True,
        )
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        materialized_publication = json.loads(
            fixture.publication_path.read_text(encoding="utf-8")
        )
        repository = materialized_build["repository"]
        root_id = materialized_build["build_order_id"]
        plan_version = materialized_build["plan_version"]
        approved = materialized_publication["approved_planning_commit"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            root_id, plan_version, approved, repository, receipt, receipt_url
        )
        report = Report()
        with patch("publication_comment.verify_live_graph", return_value=True):
            validate_final_comment_matches(
                root_id, plan_version, approved, receipt, receipt_url,
                root_url, repository, report,
                repository_anchor=fixture.build_path,
                remote_ref_contains=self.remote_ref_contains,
            )
        self.assertIn(
            "validated receipt repository must equal configured GitHub origin "
            "its-everdred/aiur",
            report.errors,
        )

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


if __name__ == "__main__":
    unittest.main()
