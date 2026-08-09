"""GitHub receipt and reconciliation projection tests."""

import copy

from github_projection_helpers import GithubProjectionCase, github
from helpers import report_for


class GithubReconciliationTests(GithubProjectionCase):
    def test_reconciliation_rejects_root_only_label_on_members(self) -> None:
        for field in ("projected_labels", "observed_labels"):
            data = self.materialized()
            data["github_reconciliation"][field]["BO-001"].append("build-order")
            self.assert_error(data, "root-only label present for BO-001")

    def test_reconciliation_titles_match_approved_documents(self) -> None:
        for field in ("expected_issue_titles", "observed_issue_titles"):
            data = self.materialized()
            data["github_reconciliation"][field]["BO-001"] = "Drifted title"
            self.assert_error(data, "must match the independently rendered approved title")

    def test_reconciliation_requires_complete_title_maps(self) -> None:
        data = self.materialized()
        del data["github_reconciliation"]["observed_issue_titles"]["BO-001"]
        self.assert_error(data, "observed_issue_titles keys must match root and tickets")

    def test_reconciliation_requires_open_issue_states(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["observed_issue_states"]["BO-001"] = "CLOSED"
        self.assert_error(data, "BO-001 must equal OPEN at publication")
        data = self.materialized()
        del data["github_reconciliation"]["observed_issue_states"]["BO-001"]
        self.assert_error(data, "observed_issue_states keys must match root and tickets")

    def test_reconciliation_requires_v3_receipt(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["receipt_schema_version"] = 2
        self.assert_error(data, "receipt_schema_version must be integer 3")

    def test_reconciliation_allows_unrelated_labels_but_rejects_family_drift(self) -> None:
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append("enhancement")
        self.assert_clean(data)
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append("phase:2")
        self.assert_error(data, "unexpected observed labels for BO-001")

    def test_reconciliation_rejects_unprojected_routing_families(self) -> None:
        for label in (
            "agent:queued", "human:todo", "model:claude", "phase:999",
            "complexity:999",
        ):
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
        data = self.materialized()
        data["github_reconciliation"]["observed_body_evidence"]["BO-001"]["body_sha256"] = "0" * 64
        self.assert_error(data, "must match the independently rendered approved body")
        data = self.materialized()
        data["github_reconciliation"]["observed_body_evidence"]["BO-001"]["body_sha256"] = "0" * 63
        self.assert_error(data, "body_sha256 must be a lowercase SHA-256")

    def test_reconciliation_requires_independent_expectations(self) -> None:
        data = self.materialized()
        report = report_for(data)
        self.assertTrue(any("independently rendered" in item for item in report.errors))

    def test_marker_query_matches_are_unique_and_exact(self) -> None:
        data = self.materialized()
        matches = data["github_reconciliation"]["marker_query_matches"]["BO-001"]
        matches.append(copy.deepcopy(matches[0]))
        self.assert_error(data, "must contain exactly one issue match")
        data = self.materialized()
        data["github_reconciliation"]["marker_query_matches"]["BO-001"][0] = (
            copy.deepcopy(data["tickets"][1]["github"])
        )
        self.assert_error(data, "must equal the returned GitHub mapping")

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


if __name__ == "__main__":
    import unittest

    unittest.main()
