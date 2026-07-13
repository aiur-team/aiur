from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_fixtures import Fixture  # noqa: E402
from publication_materialized_fixture import materialized_pack  # noqa: E402
from validate_publication import validate  # noqa: E402


class CoreReceiptV2Tests(unittest.TestCase):
    def report(self, mutate=None):
        data, build, manifest = materialized_pack()
        if mutate is not None:
            mutate(data, build, manifest)
        fixture = Fixture(data, build, manifest)
        self.addCleanup(fixture.close)
        return validate(
            fixture.companion_path, fixture.build_path, fixture.publication_path
        )

    def test_pinned_v2_contract_accepts_complete_receipt(self) -> None:
        self.assertEqual([], self.report().errors)

    def test_rejects_v1_core_receipt(self) -> None:
        def mutate(_data, build, _manifest):
            build["github_reconciliation"]["receipt_schema_version"] = 1

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("Build Order receipt v2", joined)
        self.assertIn("receipt_schema_version must be integer 2", joined)

    def test_core_receipt_requires_body_evidence(self) -> None:
        def mutate(_data, build, _manifest):
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
        def mutate(_data, build, _manifest):
            build["github_reconciliation"]["observed_labels"]["BO-001"].append(
                "agent:new-state"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("unexpected observed labels for BO-001: agent:new-state", joined)

    def test_core_projected_labels_are_exact(self) -> None:
        def mutate(_data, build, _manifest):
            build["github_reconciliation"]["projected_labels"]["BO-001"].append(
                "area:backend"
            )

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("unexpected projected labels for BO-001: area:backend", joined)

    def test_approval_commit_must_exist(self) -> None:
        missing = "0" * 40

        def mutate(data, build, manifest):
            data["approved_planning_commit"] = missing
            manifest["approved_planning_commit"] = missing
            receipt = build["github_reconciliation"]
            receipt["approved_planning_commit"] = missing
            for source in (
                receipt["observed_body_evidence"],
                data["github_reconciliation"]["observed_body_evidence"],
                manifest["github_reconciliation"]["observed_body_evidence"],
            ):
                for evidence in source.values():
                    evidence["approved_planning_commit"] = missing

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("must resolve to an exact commit in this repository", joined)


if __name__ == "__main__":
    unittest.main()
