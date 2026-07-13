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
