"""Adversarial schema and malformed-type tests."""

from __future__ import annotations

import copy

from helpers import ValidatorCase, example, report_for


class SchemaTests(ValidatorCase):
    def test_canonical_example_is_clean(self) -> None:
        self.assert_clean(example())

    def test_non_object_root_is_reported(self) -> None:
        self.assert_error([], "top level must be")

    def test_required_top_level_keys_are_strict(self) -> None:
        for key in (
            "workstreams", "ticket_prefix", "github_root", "feature_boundary",
            "label_projection", "external_gates",
        ):
            with self.subTest(key=key):
                data = example()
                del data[key]
                self.assert_error(data, f"missing required key {key}")

    def test_build_order_id_is_repository_qualified(self) -> None:
        data = example()
        data["build_order_id"] = "other/repo:operator-dashboard"
        self.assert_error(data, "repository:feature-slug")

    def test_unknown_keys_fail_at_each_schema_level(self) -> None:
        mutations = [
            lambda data: data.update({"mystery": 1}),
            lambda data: data["workstreams"][0].update({"mystery": 1}),
            lambda data: data["feature_boundary"].update({"mystery": 1}),
            lambda data: data["label_projection"].update({"mystery": 1}),
            lambda data: data["external_gates"][0].update({"mystery": 1}),
            lambda data: data["requirements"][0].update({"mystery": 1}),
            lambda data: data["tickets"][0].update({"mystery": 1}),
            lambda data: data["tickets"][0]["acceptance"].update({"mystery": 1}),
            lambda data: data["epic_acceptance"].update({"mystery": 1}),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                data = example()
                mutate(data)
                self.assert_error(data, "unknown key mystery")

    def test_required_ticket_contract_fields_are_strict(self) -> None:
        for key in (
            "outcome", "scope", "non_goals", "capability_requirements",
            "workstream", "acceptance", "contains", "external_gates",
            "discovered_from",
        ):
            with self.subTest(key=key):
                data = example()
                del data["tickets"][0][key]
                self.assert_error(data, f"missing required key {key}")

    def test_booleans_are_not_integers(self) -> None:
        mutations = {
            "schema_version": lambda data: data.update(schema_version=True),
            "plan_version": lambda data: data.update(plan_version=True),
            "introduced": lambda data: data["tickets"][0].update(introduced_in_plan_version=True),
            "phase": lambda data: data["tickets"][0].update(phase_hint=True),
            "complexity": lambda data: data["tickets"][0].update(complexity_points=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                data = example()
                mutate(data)
                self.assertTrue(report_for(data).errors)

    def test_malformed_collection_types_do_not_crash(self) -> None:
        top_fields = (
            "workstreams", "feature_boundary", "label_projection", "external_gates",
            "requirements", "tickets", "epic_acceptance",
        )
        for field in top_fields:
            with self.subTest(field=field):
                data = example()
                data[field] = "wrong"
                self.assertTrue(report_for(data).errors)
        ticket_fields = (
            "kind", "provenance", "workstream", "scope", "requirement_refs",
            "depends_on", "contains", "external_gates", "safety_surfaces",
            "conflict_exceptions", "acceptance", "github",
        )
        for field in ticket_fields:
            with self.subTest(field=field):
                data = example()
                data["tickets"][0][field] = {"wrong": True}
                self.assertTrue(report_for(data).errors)

    def test_requirement_disposition_types_do_not_crash(self) -> None:
        data = example()
        data["requirements"][0]["disposition"] = ["ticket"]
        self.assert_error(data, "invalid disposition")

    def test_ticket_kind_and_provenance_types_do_not_crash(self) -> None:
        data = example()
        data["tickets"][0]["kind"] = ["executable"]
        data["tickets"][0]["provenance"] = {"planned": True}
        self.assert_error(data, "invalid kind")
        self.assert_error(data, "provenance must be")

    def test_document_must_exist_and_match_ticket(self) -> None:
        data = example()
        data["tickets"][0]["document"] = "example-tickets/missing.md"
        self.assert_error(data, "document does not exist")
        data = example()
        data["tickets"][0]["document"] = data["tickets"][1]["document"]
        self.assert_error(data, "document heading")

    def test_deferred_requirements_need_reason_and_no_ticket(self) -> None:
        data = example()
        requirement = data["requirements"][0]
        requirement.update(disposition="deferred", reason=None)
        self.assert_error(data, "deferred disposition cannot have ticket_ids")
        self.assert_error(data, "deferred disposition requires reason")

    def test_mutating_fixture_does_not_leak(self) -> None:
        first = example()
        second = copy.deepcopy(first)
        second["tickets"].clear()
        self.assert_clean(first)


if __name__ == "__main__":
    import unittest

    unittest.main()
