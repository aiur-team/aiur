from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_fixtures import Fixture, build_order, publication  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from validate_publication import validate  # noqa: E402


class PublicationBoundaryTests(unittest.TestCase):
    def report(self, build=None, manifest=None):
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        return validate(fixture.build_path, fixture.publication_path)

    def test_requires_exact_unique_dashboard_requirement_set(self) -> None:
        build = build_order()
        build["tickets"][-1]["requirement_refs"] = ["DREQ-014"]
        joined = "\n".join(self.report(build).errors)
        self.assertIn("requirement coverage missing: DREQ-025", joined)
        self.assertIn("requirement references must be unique: DREQ-014", joined)

    def test_requires_matching_approval_and_plan_versions(self) -> None:
        build, manifest = materialized_pack()
        manifest["approved_planning_commit"] = "c" * 40
        manifest["plan_version"] = 2
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("plan versions must match", joined)
        self.assertIn("must resolve to an exact commit in this repository", joined)

    def test_requires_root_reconciliation_comment_on_mapped_root(self) -> None:
        build, manifest = materialized_pack()
        manifest["github_reconciliation"]["root_reconciliation_comment_matches"][0]["url"] = (
            "https://github.com/example/repo/issues/999#issuecomment-1"
        )
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("must point to the mapped root issue", joined)

    def test_requires_exact_root_and_skill_label_denylist(self) -> None:
        manifest = publication()
        manifest["root_issue"]["forbidden_label_prefixes"].append("area:")
        manifest["skill_issue"]["forbidden_labels"] = []
        joined = "\n".join(self.report(manifest=manifest).errors)
        self.assertIn("root_issue.forbidden_label_prefixes must equal", joined)
        self.assertIn("skill_issue.forbidden_labels must equal build-order", joined)

    def test_trusted_repository_ref_must_be_an_exact_branch_ref(self) -> None:
        manifest = publication()
        manifest["trusted_repository_ref"] = "refs/pull/1064/head"
        joined = "\n".join(self.report(manifest=manifest).errors)
        self.assertIn(
            "trusted_repository_ref must be an exact refs/heads/...", joined
        )

    def test_member_tickets_are_not_standalone_parent_observations(self) -> None:
        build, manifest = materialized_pack()
        manifest["github_reconciliation"]["observed_parent_issues"]["DASH-001"] = None
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("keys must match standalone issues", joined)

    def test_proves_root_and_skill_have_no_parent(self) -> None:
        build, manifest = materialized_pack()
        root_id = "example/repo:build-order-dashboard"
        manifest["github_reconciliation"]["observed_parent_issues"][root_id] = (
            "example/repo#2"
        )
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn(f"{root_id} must remain standalone", joined)

    def test_global_materialization_requires_the_core_receipt(self) -> None:
        build, manifest = materialized_pack()
        for ticket in build["tickets"]:
            ticket["github"] = None
        build["github_root"] = None
        build["github_reconciliation"] = None
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("materialized Build Order data requires github_reconciliation", joined)
        self.assertIn("materialized Build Order receipt requires github_reconciliation", joined)

    def test_materialized_pack_requires_build_order_identity(self) -> None:
        build, manifest = materialized_pack()
        del build["build_order_id"]
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("build-order.build_order_id must be a non-empty string", joined)

    def test_reconciliation_times_are_rfc3339_utc(self) -> None:
        build, manifest = materialized_pack()
        build["github_reconciliation"]["checked_at"] = "now"
        manifest["github_reconciliation"]["checked_at"] = "2026-99-99T00:00:00Z"
        joined = "\n".join(self.report(build, manifest).errors)
        self.assertIn("github_reconciliation.checked_at must be an RFC3339 UTC", joined)
        self.assertIn(
            "publication.github_reconciliation.checked_at must be an RFC3339 UTC", joined
        )


if __name__ == "__main__":
    unittest.main()
