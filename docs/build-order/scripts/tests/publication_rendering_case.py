"""Shared constants, payload builders and the final-comment fixture."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
for _path in (SCRIPT_DIR, SKILL_PUBLICATION, Path(__file__).resolve().parent):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from publication_comment import (
    render_successful_comment,
    validate_final_comment_matches,
)
from publication_common import Report
from publication_fixtures import Fixture
from publication_materialized_fixture import materialized_pack


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


class FinalCommentCase(unittest.TestCase):
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
        comment_url = self.root_comment_url.rsplit("-", 1)[0] + "-999"
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
        def verify(authority, _receipt, expected_bodies, live_report):
            if not isinstance(matches, list) or len(matches) != 1:
                live_report.error(
                    "live GitHub reconciliation evidence must contain exactly one "
                    "successful comment"
                )
                return False
            item = matches[0]
            if not isinstance(item, dict):
                live_report.error("live GitHub reconciliation comment is malformed")
                return False
            success_url = item.get("url")
            prefix = authority.root_issue_url + "#issuecomment-"
            if (
                not isinstance(success_url, str) or not success_url.startswith(prefix)
                or success_url == authority.root_comment_url
            ):
                live_report.error(
                    "live GitHub successful receipt must be a distinct canonical "
                    "comment on the trusted root issue"
                )
            body = item.get("body")
            if body != expected_bodies["successful"]:
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
