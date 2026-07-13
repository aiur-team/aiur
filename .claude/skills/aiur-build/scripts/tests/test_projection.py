"""Feature-boundary, label-projection, and GitHub identity tests."""

from __future__ import annotations

from helpers import ValidatorCase, example, report_for


def github(repository: str, number: int, node_id: str):
    return {
        "repository": repository,
        "number": number,
        "node_id": node_id,
        "url": f"https://github.com/{repository}/issues/{number}",
    }


class ProjectionTests(ValidatorCase):
    def test_critical_path_must_resolve_to_runnable_ticket(self) -> None:
        data = example()
        data["feature_boundary"]["critical_path_ticket_ids"] = ["BO-999"]
        self.assert_error(data, "unknown critical-path ticket BO-999")

    def test_label_projection_must_exactly_cover_graph_values(self) -> None:
        data = example()
        del data["label_projection"]["workstreams"]["platform"]
        self.assert_error(data, "workstreams missing key platform")
        data = example()
        data["label_projection"]["phases"]["9"] = "phase:9"
        self.assert_error(data, "phases has unused key 9")

    def test_ticket_workstream_must_resolve(self) -> None:
        data = example()
        data["tickets"][0]["workstream"] = "unknown"
        self.assert_error(data, "unknown workstream")

    def test_labels_cannot_be_reused(self) -> None:
        data = example()
        data["label_projection"]["phases"]["1"] = data["label_projection"]["build_order"]
        self.assert_error(data, "reuses a label")


class GithubTests(ValidatorCase):
    def materialized(self):
        data = example()
        data["github_root"] = github("example/repo", 100, "ROOT")
        data["tickets"][0]["github"] = github("example/repo", 101, "ONE")
        data["tickets"][1]["github"] = github("example/other", 102, "TWO")
        data["github_reconciliation"] = {
            "receipt_schema_version": 2,
            "checked_at": "2026-01-01T00:00:00Z",
            "approved_planning_commit": "b" * 40,
            "root_node_id": "ROOT",
            "member_ticket_ids": ["BO-001", "BO-002"],
            "dependency_edges": [{"ticket_id": "BO-002", "depends_on": "BO-001"}],
            "observed_labels": {
                "github_root": ["build-order"],
                "BO-001": ["build-lane:platform", "phase:1", "complexity:3", "model:codex"],
                "BO-002": ["build-lane:integration", "phase:2", "complexity:2", "model:codex"],
            },
            "projected_labels": {
                "github_root": ["build-order"],
                "BO-001": ["build-lane:platform", "phase:1", "complexity:3", "model:codex"],
                "BO-002": ["build-lane:integration", "phase:2", "complexity:2", "model:codex"],
            },
            "observed_body_evidence": {
                identity: {
                    "marker_logical_id": identity,
                    "approved_planning_commit": "b" * 40,
                    "body_sha256": f"{index:064x}",
                }
                for index, identity in enumerate(
                    ("example/repo:operator-dashboard", "BO-001", "BO-002"), 1
                )
            },
        }
        return data

    def test_valid_same_owner_mapping(self) -> None:
        self.assert_clean(self.materialized())

    def test_mapping_url_and_repository_are_validated(self) -> None:
        data = self.materialized()
        data["tickets"][0]["github"]["url"] = "https://github.com/example/repo/issues/999"
        self.assert_error(data, "url must equal")
        data = self.materialized()
        data["github_root"]["repository"] = "example/other"
        self.assert_error(data, "repository must equal example/repo")

    def test_mapping_requires_root_and_same_owner(self) -> None:
        data = example()
        data["tickets"][0]["github"] = github("example/repo", 101, "ONE")
        self.assert_error(data, "without github_root")
        data = self.materialized()
        data["tickets"][1]["github"] = github("outsider/repo", 102, "TWO")
        self.assert_error(data, "share the GitHub owner")

    def test_materialization_requires_complete_reconciliation(self) -> None:
        data = example()
        data["github_root"] = github("example/repo", 100, "ROOT")
        self.assert_error(data, "require github_reconciliation")
        data = self.materialized()
        data["tickets"][1]["github"] = None
        self.assert_error(data, "missing ticket mappings")
        data = self.materialized()
        data["github_reconciliation"]["dependency_edges"] = []
        self.assert_error(data, "dependencies must exactly match")

    def test_reconciliation_requires_routing_and_forbids_dispatch_labels(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].remove("model:codex")
        self.assert_error(data, "observed labels missing for BO-001")
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append("agent:todo")
        self.assert_error(data, "forbidden labels present for BO-001")

    def test_reconciliation_allows_unrelated_labels_but_rejects_family_drift(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append("enhancement")
        self.assert_clean(data)
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append("phase:2")
        self.assert_error(data, "unexpected observed labels for BO-001")

    def test_reconciliation_rejects_unprojected_routing_families(self) -> None:
        for label in ("agent:queued", "model:claude", "phase:999", "complexity:999"):
            data = self.materialized()
            data["github_reconciliation"]["observed_labels"]["BO-001"].append(label)
            self.assert_error(data, "unexpected observed labels for BO-001")

    def test_reconciliation_is_strict_and_malformed_safe(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["mystery"] = True
        self.assert_error(data, "unknown key mystery")
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"] = []
        self.assert_error(data, "observed_labels must be an object")

    def test_reconciliation_requires_fresh_time_and_bound_body_markers(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["checked_at"] = "now"
        self.assert_error(data, "checked_at must be an RFC3339 UTC")
        data = self.materialized()
        del data["github_reconciliation"]["observed_body_evidence"]["BO-001"]
        self.assert_error(data, "keys must match root and tickets")
        data = self.materialized()
        data["github_reconciliation"]["observed_body_evidence"]["BO-001"]["marker_logical_id"] = "BO-002"
        self.assert_error(data, "marker_logical_id must equal BO-001")
        data = self.materialized()
        data["github_reconciliation"]["observed_body_evidence"]["BO-001"]["approved_planning_commit"] = "c" * 40
        self.assert_error(data, "approved_planning_commit must match the receipt")

    def test_mapping_identity_must_be_unique(self) -> None:
        data = self.materialized()
        data["tickets"][1]["github"] = github("example/repo", 101, "TWO")
        self.assert_error(data, "duplicates issue identity")
        data = self.materialized()
        data["tickets"][1]["github"]["node_id"] = "ONE"
        self.assert_error(data, "duplicates node_id")

    def test_mapping_is_strict_and_boolean_is_not_number(self) -> None:
        data = self.materialized()
        data["github_root"]["mystery"] = True
        self.assert_error(data, "unknown key mystery")
        data = self.materialized()
        data["github_root"]["number"] = True
        self.assert_error(data, "number must be a positive integer")

    def test_malformed_mapping_types_do_not_crash(self) -> None:
        data = self.materialized()
        data["github_root"]["number"] = []
        data["github_root"]["repository"] = []
        data["tickets"][0]["github"]["node_id"] = {}
        self.assertTrue(report_for(data).errors)


if __name__ == "__main__":
    import unittest

    unittest.main()
