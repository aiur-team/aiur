from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_fixtures import (  # noqa: E402
    Fixture,
    build_order,
    github,
    publication,
)
from publication_materialized_fixture import materialized_pack  # noqa: E402
from validate_publication import validate  # noqa: E402


class PublicationValidationTests(unittest.TestCase):
    def test_valid_prepublication_graph(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def test_requires_exact_bounded_agent_label_denylist(self) -> None:
        build = build_order()
        build["label_projection"]["forbidden_labels"] = ["agent:todo"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        self.assertTrue(any("exactly match the bounded agent-state" in error for error in report.errors))

    def test_rejects_bad_schema_complexity_document_and_unknown_gate(self) -> None:
        build = build_order()
        ticket = next(item for item in build["tickets"] if item["id"] == "DASH-001")
        ticket["complexity_points"] = 6
        ticket["document"] = "missing.md"
        ticket["external_gates"] = ["GATE-UNKNOWN"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        (fixture.base / "missing.md").unlink()
        report = validate(fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("complexity_points must be integer 1..5", joined)
        self.assertIn("document does not resolve", joined)
        self.assertIn("references unknown gate GATE-UNKNOWN", joined)

    def test_rejects_unresolved_dependencies_and_merged_cycles(self) -> None:
        build = build_order()
        ticket = next(item for item in build["tickets"] if item["id"] == "DASH-001")
        ticket["depends_on"] = ["MISSING-999", "DASH-002"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("depends on unknown ticket MISSING-999", joined)
        self.assertIn("hard dependency graph has a cycle", joined)

    def test_resolves_named_external_gates(self) -> None:
        build = build_order()
        build["external_gates"] = []
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        self.assertTrue(any("GATE-HUMAN-AUTHORITY" in error for error in report.errors))

    def test_rejects_unordered_parallel_safety_surface(self) -> None:
        build = build_order()
        tickets = {item["id"]: item for item in build["tickets"]}
        tickets["DASH-001"]["safety_surfaces"] = ["shared authorization"]
        tickets["DASH-003"]["write_surfaces"] = ["shared authorization"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.build_path).errors)
        self.assertIn(
            "DASH-001 and DASH-003: parallel safety-surface conflict: shared authorization",
            joined,
        )

    def test_warns_for_unordered_parallel_write_surface(self) -> None:
        build = build_order()
        tickets = {item["id"]: item for item in build["tickets"]}
        tickets["DASH-001"]["write_surfaces"] = ["shared composition"]
        tickets["DASH-003"]["write_surfaces"] = ["shared composition"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        self.assertIn(
            "DASH-001 and DASH-003: overlapping parallel surfaces: shared composition",
            report.warnings,
        )

    def test_serialization_covers_shared_surface(self) -> None:
        build = build_order()
        tickets = {item["id"]: item for item in build["tickets"]}
        tickets["DASH-001"]["write_surfaces"] = ["shared composition"]
        tickets["DASH-003"]["write_surfaces"] = ["shared composition"]
        tickets["DASH-001"]["serializes_with"] = ["DASH-003"]
        tickets["DASH-003"]["serializes_with"] = ["DASH-001"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def test_cross_family_serialization_must_be_symmetric(self) -> None:
        build = build_order()
        tickets = {item["id"]: item for item in build["tickets"]}
        tickets["DASH-003"]["serializes_with"] = ["BO-012"]
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.build_path).errors)
        self.assertIn("DASH-003.serializes_with BO-012 must be symmetric", joined)

    def test_validates_auxiliary_manifest_contract(self) -> None:
        manifest = publication()
        manifest["read_only_issue_refs"] = ["example/repo#132"]
        manifest["skill_issue"]["forbidden_label_prefixes"] = []
        manifest["external_blocker_relations"] = []
        fixture = Fixture(publication_data=manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.build_path, fixture.publication_path).errors)
        self.assertIn("#132, #845, #1033, #1034, and #1067", joined)
        self.assertIn("forbidden_label_prefixes must equal", joined)
        self.assertIn(
            "BO-004 and BO-008 blocked by SKILL-DELIVERY-001", joined
        )

    def test_auxiliary_receipt_rejects_agent_labels(self) -> None:
        build, manifest = materialized_pack()
        manifest["github_reconciliation"]["observed_labels"][
            "SKILL-DELIVERY-001"
        ].append("agent:future-state")
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.build_path, fixture.publication_path).errors)
        self.assertIn("unexpected routing labels: agent:future-state", joined)
        self.assertNotIn("number", joined)

    def test_auxiliary_receipt_rejects_human_routing_drift(self) -> None:
        build, manifest = materialized_pack()
        root_id = "example/repo:build-order-dashboard"
        manifest["github_reconciliation"]["observed_labels"][root_id].append(
            "human:todo"
        )
        manifest["github_reconciliation"]["observed_labels"][
            "SKILL-DELIVERY-001"
        ].append("human:done")
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(
            fixture.build_path, fixture.publication_path
        ).errors)
        self.assertIn("unexpected routing labels: human:todo", joined)
        self.assertIn("unexpected routing labels: human:done", joined)

    def test_materialization_is_complete_and_all_or_nothing(self) -> None:
        build = build_order()
        build["tickets"][0]["github"] = github(701, "NODE_1")
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("materialized publication requires publication.github_reconciliation", joined)
        self.assertIn("materialized Build Order data requires github_reconciliation", joined)
        self.assertIn("approved body expectations", joined)

    def test_reconciliation_accepts_nonadjacent_github_numbers(self) -> None:
        build, manifest = materialized_pack()
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path, fixture.publication_path)
        self.assertEqual([], report.errors)

    def test_core_receipt_requires_exact_edges_and_full_observed_labels(self) -> None:
        build, manifest = materialized_pack()
        receipt = build["github_reconciliation"]
        receipt["dependency_edges"] = []
        receipt["observed_labels"]["BO-001"] = [
            "model:codex-gpt-5.6-sol", "agent:paused",
        ]
        fixture = Fixture(build, manifest)
        self.addCleanup(fixture.close)
        report = validate(fixture.build_path, fixture.publication_path)
        joined = "\n".join(report.errors)
        self.assertIn("dependencies must exactly match depends_on", joined)
        self.assertIn("forbidden labels present for BO-001: agent:paused", joined)
        self.assertIn("labels missing for BO-001", joined)

    def test_cli_has_stable_counts_and_nonzero_errors(self) -> None:
        build = build_order()
        build["label_projection"]["forbidden_labels"].remove("agent:paused")
        fixture = Fixture(build)
        self.addCleanup(fixture.close)
        result = subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "validate_publication.py"), str(fixture.build_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("validation: 1 error(s), 0 warning(s)", result.stdout.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
