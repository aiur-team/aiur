"""Canonical issue rendering and final-comment verification tests."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_comment import (  # noqa: E402
    render_pending_comment,
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report  # noqa: E402
from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from publication_rendering import (  # noqa: E402
    approved_link,
    authority_preamble,
    inspect_issue_body,
    render_approved_pack,
)
from validate_publication import validate  # noqa: E402


REPOSITORY = "example/repo"
ROOT_ID = "example/repo:build-order-dashboard"
APPROVED = "a" * 40


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
        companions = json.loads(fixture.companion_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        report = Report()
        expected = render_approved_pack(
            build, companions, publication, fixture.build_path,
            fixture.companion_path, fixture.base / "missing-publication.json",
            companions["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn("absent from approved commit", "\n".join(report.errors))

    def test_post_approval_planning_drift_fails_closed(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        build = json.loads(fixture.build_path.read_text(encoding="utf-8"))
        companions = json.loads(fixture.companion_path.read_text(encoding="utf-8"))
        publication = json.loads(fixture.publication_path.read_text(encoding="utf-8"))
        build["tickets"][0]["depends_on"] = ["BO-999"]
        report = Report()
        expected = render_approved_pack(
            build, companions, publication, fixture.build_path,
            fixture.companion_path, fixture.publication_path,
            companions["approved_planning_commit"], report,
        )
        self.assertIsNone(expected)
        self.assertIn(
            "planning fields must equal the approved commit",
            "\n".join(report.errors),
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
                report = validate(
                    fixture.companion_path, fixture.build_path,
                    fixture.publication_path,
                )
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
                report = validate(
                    fixture.companion_path, fixture.build_path,
                    fixture.publication_path,
                )
                self.assertTrue(any(
                    "must equal the approved template after approval substitution" in error
                    for error in report.errors
                ))

    def test_current_templates_require_approval_substitution(self) -> None:
        fixture = Fixture(*materialized_pack())
        self.addCleanup(fixture.close)
        companions = json.loads(
            fixture.companion_path.read_text(encoding="utf-8")
        )
        approved = companions["approved_planning_commit"]
        for relative in ("root-issue.md", "skill-delivery.md"):
            path = fixture.base / relative
            path.write_text(
                path.read_text(encoding="utf-8").replace("<APPROVED_SHA>", approved),
                encoding="utf-8",
            )
        report = validate(
            fixture.companion_path, fixture.build_path, fixture.publication_path
        )
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

        root = fixture.base / "root-issue.md"
        root.write_text(
            root.read_text(encoding="utf-8").replace(approved, "<APPROVED_SHA>"),
            encoding="utf-8",
        )
        report = validate(
            fixture.companion_path, fixture.build_path, fixture.publication_path
        )
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
        report = validate(
            fixture.companion_path, fixture.build_path, fixture.publication_path
        )
        self.assertTrue(any(
            "current DASH-001 document must be a regular non-symlink file" in error
            for error in report.errors
        ))


class FinalCommentTests(unittest.TestCase):
    @staticmethod
    def remote_commit_exists(_repository: str, _commit: str) -> bool:
        return True

    @classmethod
    def setUpClass(cls) -> None:
        data, build, manifest = materialized_pack()
        cls.fixture = Fixture(
            data, build, manifest, pack_prefix="docs/build-order"
        )
        cls.receipt = cls.fixture.commit_materialized()
        materialized_build = json.loads(
            cls.fixture.build_path.read_text(encoding="utf-8")
        )
        materialized_companions = json.loads(
            cls.fixture.companion_path.read_text(encoding="utf-8")
        )
        cls.repository = materialized_companions["repository"]
        cls.root_id = materialized_build["build_order_id"]
        cls.plan_version = materialized_companions["plan_version"]
        cls.approved = materialized_companions["approved_planning_commit"]
        cls.root_url = materialized_build["github_root"]["url"]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture.close()

    def values(self):
        receipt_url = (
            f"https://github.com/{self.repository}/commit/{self.receipt}"
        )
        comment_url = self.root_url + "#issuecomment-123"
        body = render_successful_comment(
            self.root_id, self.plan_version, self.approved, self.repository,
            self.receipt, receipt_url,
        )
        return self.receipt, receipt_url, self.root_url, comment_url, body

    def report(
        self, matches, receipt=None, receipt_url=None, root_id=None,
        plan_version=None, approved=None, root_url=None, repository=None,
        repository_anchor=None, remote_commit_exists=None,
    ):
        baseline_receipt, baseline_url, _, _, _ = self.values()
        report = Report()
        validate_final_comment_matches(
            matches,
            self.root_id if root_id is None else root_id,
            self.plan_version if plan_version is None else plan_version,
            self.approved if approved is None else approved,
            baseline_receipt if receipt is None else receipt,
            baseline_url if receipt_url is None else receipt_url,
            self.root_url if root_url is None else root_url,
            self.repository if repository is None else repository,
            report,
            repository_anchor=repository_anchor or self.fixture.build_path,
            remote_commit_exists=(
                remote_commit_exists or self.remote_commit_exists
            ),
        )
        return report

    def test_exact_successful_comment_is_clean(self) -> None:
        _, _, _, url, body = self.values()
        self.assertEqual([], self.report([{"url": url, "body": body}]).errors)

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
        data, build, manifest = materialized_pack()
        fixture = Fixture(
            data, build, manifest, pack_prefix="docs/build-order"
        )
        self.addCleanup(fixture.close)
        missing = "0" * 40
        for path in (fixture.companion_path, fixture.publication_path):
            value = json.loads(path.read_text(encoding="utf-8"))
            value["approved_planning_commit"] = missing
            path.write_text(json.dumps(value), encoding="utf-8")
        receipt = fixture.commit_materialized()
        materialized_build = json.loads(
            fixture.build_path.read_text(encoding="utf-8")
        )
        repository = data["repository"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            materialized_build["build_order_id"], data["plan_version"], missing,
            repository, receipt, receipt_url,
        )
        report = Report()
        validate_final_comment_matches(
            [{"url": root_url + "#issuecomment-123", "body": body}],
            materialized_build["build_order_id"], data["plan_version"], missing,
            receipt, receipt_url, root_url, repository, report,
            repository_anchor=fixture.build_path,
            remote_commit_exists=self.remote_commit_exists,
        )
        self.assertTrue(any(
            "approved_planning_commit must resolve to an exact commit" in error
            for error in report.errors
        ))

    def test_foreign_materialized_receipt_cannot_override_origin(self) -> None:
        data, build, manifest = materialized_pack()
        data, build, manifest = (
            replace_repository(item, "example/repo", "attacker/fork")
            for item in (data, build, manifest)
        )
        fixture = Fixture(
            data, build, manifest, pack_prefix="docs/build-order"
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
        materialized_companions = json.loads(
            fixture.companion_path.read_text(encoding="utf-8")
        )
        repository = materialized_companions["repository"]
        root_id = materialized_build["build_order_id"]
        plan_version = materialized_companions["plan_version"]
        approved = materialized_companions["approved_planning_commit"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = f"https://github.com/{repository}/commit/{receipt}"
        body = render_successful_comment(
            root_id, plan_version, approved, repository, receipt, receipt_url
        )
        report = Report()
        validate_final_comment_matches(
            [{"url": root_url + "#issuecomment-123", "body": body}],
            root_id, plan_version, approved, receipt, receipt_url,
            root_url, repository, report,
            repository_anchor=fixture.build_path,
            remote_commit_exists=self.remote_commit_exists,
        )
        self.assertIn(
            "validated receipt repository must equal configured GitHub origin "
            "its-everdred/aiur",
            report.errors,
        )

    def test_receipt_and_approval_must_exist_in_origin(self) -> None:
        _, _, _, comment_url, body = self.values()
        checked: list[tuple[str, str]] = []

        def remote_commit_exists(repository: str, commit: str) -> bool:
            checked.append((repository, commit))
            return commit != self.approved

        report = self.report(
            [{"url": comment_url, "body": body}],
            remote_commit_exists=remote_commit_exists,
        )
        self.assertEqual(
            [
                (self.repository, self.receipt),
                (self.repository, self.approved),
            ],
            checked,
        )
        self.assertIn(
            "approved_planning_commit must exist in configured GitHub repository "
            f"{self.repository}",
            report.errors,
        )

    def test_replace_ref_cannot_promote_unmaterialized_commit(self) -> None:
        data, build, manifest = materialized_pack()
        fixture = Fixture(
            data, build, manifest, pack_prefix="docs/build-order"
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
        materialized_companions = json.loads(
            fixture.companion_path.read_text(encoding="utf-8")
        )
        repository = materialized_companions["repository"]
        root_id = materialized_build["build_order_id"]
        plan_version = materialized_companions["plan_version"]
        root_url = materialized_build["github_root"]["url"]
        receipt_url = (
            f"https://github.com/{repository}/commit/{unmaterialized}"
        )
        body = render_successful_comment(
            root_id, plan_version, unmaterialized, repository,
            unmaterialized, receipt_url,
        )
        report = Report()
        validate_final_comment_matches(
            [{"url": root_url + "#issuecomment-123", "body": body}],
            root_id, plan_version, unmaterialized, unmaterialized,
            receipt_url, root_url, repository, report,
            repository_anchor=fixture.build_path,
            remote_commit_exists=self.remote_commit_exists,
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
        for name in (
            "build-order.json", "dashboard-companions.json", "publication.json",
        ):
            self.assertIn(
                f"receipt commit {name} github_reconciliation must be materialized",
                report.errors,
            )


if __name__ == "__main__":
    unittest.main()
