"""Pinned reusable core receipt v3 contract tests."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
sys.path.insert(0, str(SKILL_PUBLICATION))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from validate_publication import validate  # noqa: E402


class CoreReceiptV3Tests(unittest.TestCase):
    def report(self, mutate=None):
        build, manifest = materialized_pack()
        if mutate is not None:
            mutate(build, manifest)
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        return validate(fixture.build_path, fixture.publication_path)

    def test_pinned_v3_contract_accepts_complete_receipt(self) -> None:
        self.assertEqual([], self.report().errors)

    def test_rejects_pre_v3_core_receipt(self) -> None:
        def mutate(build, _manifest):
            build["github_reconciliation"]["receipt_schema_version"] = 2

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("Build Order receipt v3", joined)
        self.assertIn("receipt_schema_version must be integer 3", joined)

    def test_core_receipt_requires_exact_open_state_partition(self) -> None:
        def mutate(build, _manifest):
            build["github_reconciliation"]["observed_issue_states"]["BO-001"] = (
                "CLOSED"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("observed_issue_states.BO-001 must equal OPEN", joined)

    def test_core_root_label_maps_use_logical_id(self) -> None:
        def mutate(build, _manifest):
            root_id = build["build_order_id"]
            for field in ("projected_labels", "observed_labels"):
                build["github_reconciliation"][field]["github_root"] = (
                    build["github_reconciliation"][field].pop(root_id)
                )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("keys must match root and tickets", joined)

    def test_core_receipt_requires_body_evidence(self) -> None:
        def mutate(build, _manifest):
            del build["github_reconciliation"]["observed_body_evidence"]

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("missing required key observed_body_evidence", joined)
        self.assertIn("Build Order receipt.observed_body_evidence must be an object", joined)

    def test_pinned_contract_unavailability_fails_closed(self) -> None:
        with patch(
            "publication_core_receipt.PINNED_SKILL_COMMIT",
            "0" * 40,
        ):
            joined = "\n".join(self.report().errors)
        self.assertIn("pinned aiur-build receipt contract commit is unavailable", joined)

    def test_core_observed_labels_reject_unknown_agent_family(self) -> None:
        def mutate(build, _manifest):
            build["github_reconciliation"]["observed_labels"]["BO-001"].append(
                "agent:new-state"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("unexpected observed labels for BO-001: agent:new-state", joined)

    def test_core_observed_labels_reject_human_routing_drift(self) -> None:
        def mutate(build, _manifest):
            build["github_reconciliation"]["observed_labels"]["BO-001"].append(
                "human:todo"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("unexpected observed labels for BO-001: human:todo", joined)

    def test_core_projected_labels_are_exact(self) -> None:
        def mutate(build, _manifest):
            build["github_reconciliation"]["projected_labels"]["BO-001"].append(
                "area:backend"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("unexpected projected labels for BO-001: area:backend", joined)

    def test_approval_commit_must_exist(self) -> None:
        missing = "0" * 40

        def mutate(build, manifest):
            manifest["approved_planning_commit"] = missing
            receipt = build["github_reconciliation"]
            receipt["approved_planning_commit"] = missing
            for source in (
                receipt["observed_body_evidence"],
                manifest["github_reconciliation"]["observed_body_evidence"],
            ):
                for evidence in source.values():
                    evidence["approved_planning_commit"] = missing

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("must resolve to an exact commit in this repository", joined)


if __name__ == "__main__":
    unittest.main()
