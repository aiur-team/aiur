"""Adversarial typed-edge, hierarchy, conflict, and acceptance tests."""

from __future__ import annotations

from helpers import ValidatorCase, example, executable, umbrella


def append_executable(data, *, independent: bool = False):
    ticket = executable()
    if independent:
        ticket["depends_on"] = []
    data["tickets"].append(ticket)
    data["requirements"][0]["ticket_ids"].append("BO-003")
    return ticket


class TraceabilityTests(ValidatorCase):
    def test_requirement_to_ticket_trace_is_bidirectional(self) -> None:
        data = example()
        data["requirements"][0]["ticket_ids"] = ["BO-002"]
        self.assert_error(data, "requirement REQ-001 does not trace back")
        data = example()
        data["tickets"][0]["requirement_refs"] = ["REQ-002"]
        self.assert_error(data, "ticket BO-001 does not trace back")

    def test_unknown_requirement_and_ticket_are_errors(self) -> None:
        data = example()
        data["tickets"][0]["requirement_refs"] = ["REQ-999"]
        self.assert_error(data, "unknown requirement ref REQ-999")
        data = example()
        data["requirements"][0]["ticket_ids"] = ["BO-999"]
        self.assert_error(data, "references unknown ticket BO-999")


class EdgeTests(ValidatorCase):
    def test_duplicate_and_contradictory_edges_fail(self) -> None:
        data = example()
        data["tickets"][1]["depends_on"] = ["BO-001", "BO-001"]
        self.assert_error(data, "contains duplicate value BO-001")
        data = example()
        data["tickets"][1]["suggested_after"] = ["BO-001"]
        self.assert_error(data, "contradictory edge types")

    def test_serialization_must_be_symmetric(self) -> None:
        data = example()
        data["tickets"][0]["serializes_with"] = ["BO-002"]
        self.assert_error(data, "must be symmetric")

    def test_hard_dependency_cycle_fails(self) -> None:
        data = example()
        data["tickets"][0]["depends_on"] = ["BO-002"]
        self.assert_error(data, "hard dependency cycle")

    def test_same_phase_dependency_is_valid(self) -> None:
        data = example()
        data["tickets"][1]["phase_hint"] = 1
        del data["label_projection"]["phases"]["2"]
        self.assert_clean(data)

    def test_earlier_dependent_phase_fails(self) -> None:
        data = example()
        data["tickets"][0]["phase_hint"] = 2
        data["tickets"][1]["phase_hint"] = 1
        self.assert_error(data, "is earlier than dependency")

    def test_external_gate_must_resolve(self) -> None:
        data = example()
        data["tickets"][0]["external_gates"] = ["GATE-999"]
        self.assert_error(data, "unknown external gate GATE-999")

    def test_discovered_ticket_requires_valid_provenance(self) -> None:
        data = example()
        data["tickets"][0].update(provenance="discovered", discovered_from=None)
        self.assert_error(data, "requires a ticket ID in discovered_from")
        data = example()
        data["tickets"][0].update(provenance="discovered", discovered_from="BO-999")
        self.assert_error(data, "discovered_from references unknown ticket")
        data = example()
        data["tickets"][0].update(provenance="discovered", discovered_from="incident text")
        self.assert_error(data, "requires a ticket ID")


class HierarchyTests(ValidatorCase):
    def test_one_umbrella_can_own_children(self) -> None:
        data = example()
        data["tickets"].append(
            umbrella("BO-003", "example-tickets/BO-003-example-umbrella.md", ["BO-001", "BO-002"])
        )
        self.assert_clean(data)

    def test_only_umbrella_can_contain(self) -> None:
        data = example()
        data["tickets"][0]["contains"] = ["BO-002"]
        self.assert_error(data, "only umbrella tickets may contain")

    def test_child_has_one_owner(self) -> None:
        data = example()
        data["tickets"].extend(
            [
                umbrella("BO-003", "example-tickets/BO-003-example-umbrella.md", ["BO-001"]),
                umbrella("BO-004", "example-tickets/BO-004-example-umbrella.md", ["BO-001"]),
            ]
        )
        self.assert_error(data, "contained by both")

    def test_hierarchy_cycle_fails(self) -> None:
        data = example()
        data["tickets"].extend(
            [
                umbrella("BO-003", "example-tickets/BO-003-example-umbrella.md", ["BO-004"]),
                umbrella("BO-004", "example-tickets/BO-004-example-umbrella.md", ["BO-003"]),
            ]
        )
        self.assert_error(data, "hierarchy cycle")


class ConflictAndAcceptanceTests(ValidatorCase):
    def safety_conflict_fixture(self):
        data = example()
        ticket = append_executable(data, independent=True)
        ticket["write_surfaces"] = ["Dependency truth projection"]
        ticket["contract_surfaces"] = ["SecondarySnapshot"]
        ticket["safety_surfaces"] = ["Dependency truth projection"]
        data["tickets"][1]["depends_on"].append("BO-003")
        return data

    def test_parallel_safety_conflict_is_error(self) -> None:
        self.assert_error(self.safety_conflict_fixture(), "parallel safety-surface conflict")

    def test_structured_safety_exception_is_accepted(self) -> None:
        data = self.safety_conflict_fixture()
        data["tickets"][0]["conflict_exceptions"] = [
            {
                "ticket_id": "BO-003",
                "surfaces": ["Dependency truth projection"],
                "reason": "The work is coordinated through immutable fixtures.",
            }
        ]
        self.assert_clean(data)

    def test_exception_must_name_real_overlap_and_ticket(self) -> None:
        data = self.safety_conflict_fixture()
        data["tickets"][0]["conflict_exceptions"] = [
            {"ticket_id": "BO-003", "surfaces": ["Other"], "reason": "Reviewed."}
        ]
        self.assert_error(data, "exception names non-overlapping surfaces")
        data = example()
        data["tickets"][0]["conflict_exceptions"] = [
            {"ticket_id": "BO-999", "surfaces": ["Other"], "reason": "Reviewed."}
        ]
        self.assert_error(data, "references unknown ticket")

    def test_capstone_must_cover_every_runnable_ticket(self) -> None:
        data = example()
        append_executable(data, independent=True)
        self.assert_error(data, "capstone does not transitively cover: BO-003")

    def test_critical_path_must_include_capstone(self) -> None:
        data = example()
        data["feature_boundary"]["critical_path_ticket_ids"] = ["BO-001"]
        self.assert_error(data, "critical path must include the capstone")

    def test_capstone_transitive_coverage_is_valid(self) -> None:
        data = example()
        append_executable(data)
        data["tickets"][1]["depends_on"] = ["BO-003"]
        self.assert_clean(data)


if __name__ == "__main__":
    import unittest

    unittest.main()
