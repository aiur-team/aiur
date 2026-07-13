"""GitHub mapping and immutable-authority projection tests."""

from github_projection_helpers import GithubProjectionCase, github
from helpers import example, report_for
from validation_publication_authority import PublicationAuthority


class GithubMappingTests(GithubProjectionCase):
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

    def test_immutable_authority_limits_mutations_and_lifecycle_labels(self) -> None:
        authority = PublicationAuthority(
            "refs/heads/main", "root.md", ("example/repo",),
            ("https://github.com/example/repo/issues/101",), "workflow",
        )
        data = self.materialized()
        data["github_reconciliation"]["observed_labels"]["BO-001"].append(
            "WoRkFlOw:ToDo"
        )
        report = report_for(data, self.approved_body_expectations, authority)
        joined = "\n".join(report.errors)
        self.assertIn("BO-002.github is outside immutable mutation authority", joined)
        self.assertIn("BO-001.github maps a reference-only issue", joined)
        self.assertIn("forbidden labels present for BO-001", joined)


if __name__ == "__main__":
    import unittest

    unittest.main()
