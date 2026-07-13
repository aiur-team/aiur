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
    companions,
    github,
    publication,
)
from publication_materialized_fixture import materialized_pack  # noqa: E402
from validate_publication import validate  # noqa: E402


class PublicationValidationTests(unittest.TestCase):
    def test_valid_prepublication_graph(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def test_requires_exact_bounded_agent_label_denylist(self) -> None:
        data = companions()
        data["forbidden_labels"] = ["agent:todo"]
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        self.assertTrue(any("exactly match the bounded agent-state" in error for error in report.errors))

    def test_rejects_bad_schema_complexity_document_and_external_blocker(self) -> None:
        data = companions()
        ticket = data["tickets"][0]
        ticket["complexity_points"] = 6
        ticket["document"] = "missing.md"
        ticket["external_blockers"] = ["#12"]
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        (fixture.base / "missing.md").unlink()
        report = validate(fixture.companion_path, fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("complexity_points must be integer 1..5", joined)
        self.assertIn("document does not resolve", joined)
        self.assertIn("external_blockers has invalid identity", joined)

    def test_rejects_unresolved_dependencies_and_combined_cycles(self) -> None:
        data = companions()
        data["tickets"][0]["depends_on"] = ["MISSING-999", "DASH-002"]
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("depends on unknown ticket MISSING-999", joined)
        self.assertIn("combined hard dependency graph has a cycle", joined)

    def test_resolves_named_external_gates(self) -> None:
        data = companions()
        data["external_gates"] = []
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        self.assertTrue(any("GATE-HUMAN-AUTHORITY" in error for error in report.errors))

    def test_validates_auxiliary_manifest_contract(self) -> None:
        manifest = publication()
        manifest["read_only_issue_refs"] = ["example/repo#132"]
        manifest["skill_issue"]["forbidden_label_prefixes"] = []
        manifest["external_blocker_relations"] = []
        fixture = Fixture(publication_data=manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("#132, #845, #1033, #1034, and #1067", joined)
        self.assertIn("forbidden_label_prefixes must equal", joined)
        self.assertIn(
            "BO-001, BO-004, and BO-008 blocked by SKILL-DELIVERY-001", joined
        )

    def test_auxiliary_receipt_rejects_agent_labels(self) -> None:
        data, build, manifest = materialized_pack()
        manifest["github_reconciliation"]["observed_labels"][
            "SKILL-DELIVERY-001"
        ].append("agent:future-state")
        fixture = Fixture(data, build, manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("unexpected routing labels: agent:future-state", joined)
        self.assertNotIn("number", joined)

    def test_materialization_is_complete_and_identity_unique(self) -> None:
        data = companions()
        data["tickets"][0]["github"] = github(701, "DASH_NODE_1")
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("require all DASH mappings", joined)
        self.assertIn("require referenced BO mappings", joined)
        self.assertIn("require approved_planning_commit", joined)
        self.assertIn("require github_reconciliation", joined)

    def test_reconciliation_accepts_nonadjacent_github_numbers(self) -> None:
        data, build, manifest = materialized_pack()
        fixture = Fixture(data, build, manifest)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        self.assertEqual([], report.errors)

    def test_reconciliation_requires_exact_edges_and_full_observed_labels(self) -> None:
        data = companions()
        build = build_order()
        data["approved_planning_commit"] = "b" * 40
        data["tickets"][0]["github"] = github(11, "DASH_NODE_1")
        data["tickets"][1]["github"] = github(29, "DASH_NODE_2")
        build["tickets"][0]["github"] = github(47, "BO_NODE_1")
        data["github_reconciliation"] = {
            "checked_at": "now",
            "dependency_edges": [],
            "observed_labels": {
                "DASH-001": ["model:codex", "complexity:3", "agent:paused"],
                "DASH-002": ["model:codex"],
            },
        }
        fixture = Fixture(data, build)
        self.addCleanup(fixture.close)
        report = validate(fixture.companion_path, fixture.build_path)
        joined = "\n".join(report.errors)
        self.assertIn("dependencies must exactly match", joined)
        self.assertIn("unexpected routing labels: agent:paused, complexity:3", joined)
        self.assertIn("routing labels missing: complexity:4", joined)

    def test_cli_has_stable_counts_and_nonzero_errors(self) -> None:
        data = companions()
        data["forbidden_labels"].remove("agent:paused")
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        result = subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "validate_publication.py"), str(fixture.companion_path), str(fixture.build_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("validation: 1 error(s), 0 warning(s)", result.stdout.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
