"""Feature-boundary, label-projection, and GitHub identity tests."""

from __future__ import annotations

import copy

from helpers import ValidatorCase, example, report_for
from validation_common import Report
from validation_github_approved import ApprovedIssueExpectations
from validation_github_rendering import render_ticket_body, inspect_issue_body
from validation_header import validate_label_projection
from validation_publication_authority import PublicationAuthority


def github(repository: str, number: int, node_id: str):
    return {
        "repository": repository,
        "number": number,
        "node_id": node_id,
        "url": f"https://github.com/{repository}/issues/{number}",
    }


class ProjectionTests(ValidatorCase):
    def test_executable_tickets_require_dispatch_without_dispatching_root(self) -> None:
        data = example()

        self.assertIn("agent:todo", data["label_projection"]["required_ticket_labels"])
        self.assertNotIn("agent:todo", data["label_projection"]["forbidden_labels"])
        self.assertEqual("build-order", data["label_projection"]["build_order"])

        data["label_projection"]["required_ticket_labels"].remove("agent:todo")
        self.assert_error(data, "must contain exactly one lifecycle todo label")

    def test_custom_lifecycle_todo_is_bound_by_publication_authority(self) -> None:
        data = example()
        required = data["label_projection"]["required_ticket_labels"]
        required[required.index("agent:todo")] = "workflow:todo"

        standalone = Report()
        validate_label_projection(data, standalone)
        self.assertEqual([], standalone.errors)

        bound = Report()
        validate_label_projection(data, bound, "agent")
        self.assertTrue(any("must equal agent:todo" in error for error in bound.errors))

    def test_projection_rejects_multiple_lifecycle_todo_labels(self) -> None:
        data = example()
        data["label_projection"]["required_ticket_labels"].append("workflow:todo")

        self.assert_error(data, "must contain exactly one lifecycle todo label")

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
        data = example()
        data["label_projection"]["required_ticket_labels"].append("build-order")
        self.assert_error(data, "reuses a label")


if __name__ == "__main__":
    import unittest

    unittest.main()
