"""``build-order.v1`` document, review rendering and consistency checks."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parents[1]
REFERENCES = SCRIPT_DIR.parent / "references"
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_common import Report  # noqa: E402
from publication_graph_document import (  # noqa: E402
    DOCUMENT_DAEMON,
    DOCUMENT_PACK_WALK,
    GraphDocumentError,
    document_source,
    edges_of,
    load_document,
    pack_walk_document,
    read_daemon_document,
)
from publication_review import render_review  # noqa: E402
from publication_review_checks import check_document_against_pack  # noqa: E402
from publish_build_order import PublicationError, check_graph_review  # noqa: E402
from render_build_order_review import main  # noqa: E402

EXAMPLE = REFERENCES / "build-order.example.json"


def example() -> dict[str, Any]:
    return json.loads(EXAMPLE.read_text(encoding="utf-8"))


def known_document() -> dict[str, Any]:
    """A document whose tracker and progress reads succeeded."""
    document = pack_walk_document(example(), generated_at="2026-01-01T00:00:00Z")
    document["document_source"] = DOCUMENT_DAEMON
    document["sources"]["tracker"] = {
        "status": "known", "observed_at": "2026-01-01T00:00:00Z", "reason": None,
    }
    document["sources"]["progress"] = {
        "status": "known", "observed_at": "2026-01-01T00:00:00Z", "reason": None,
    }
    for edge in edges_of(document, "depends_on"):
        edge["state"] = "cleared"
    document["progress"] = {
        "status": "known",
        "total": 2,
        "done": 1,
        "open": 1,
        "failed": 0,
        "percent": 50,
        "by_status": {"done": 1, "open": 1},
        "observed_at": "2026-01-01T00:00:00Z",
        "reason": None,
    }
    return document


def errors_for(document: dict[str, Any], build: dict[str, Any] | None = None) -> list[str]:
    report = Report()
    check_document_against_pack(example() if build is None else build, document, report)
    return report.errors


class PackWalkDocumentTests(unittest.TestCase):
    def test_pack_walk_publishes_the_pack_graph(self) -> None:
        document = pack_walk_document(example())
        self.assertEqual("aiur.build_order", document["contract"])
        self.assertEqual(1, document["contract_version"])
        self.assertEqual(DOCUMENT_PACK_WALK, document_source(document))
        self.assertEqual(
            ["BO-001", "BO-002"],
            [ticket["id"] for ticket in document["tickets"]],
        )
        self.assertEqual(
            {1: ["BO-001"], 2: ["BO-002"]},
            {wave["index"]: wave["tickets"] for wave in document["waves"]},
        )
        self.assertEqual(["BO-002", "BO-001"], document["critical_path"]["tickets"])
        self.assertEqual(
            [("BO-002", "BO-001", "depends_on", "unknown")],
            [
                (edge["from"], edge["to"], edge["kind"], edge["state"])
                for edge in edges_of(document, "depends_on")
            ],
        )
        self.assertEqual(
            [("BO-001", "GATE-001")],
            [(edge["from"], edge["to"]) for edge in edges_of(document, "gates")],
        )
        self.assertEqual({"platform", "integration"}, {
            lane["key"] for lane in document["lanes"]
        })

    def test_pack_walk_marks_unread_sources_unknown(self) -> None:
        document = pack_walk_document(example())
        self.assertEqual("known", document["sources"]["pack"]["status"])
        for name in ("tracker", "progress"):
            self.assertEqual("unknown", document["sources"][name]["status"])
            self.assertTrue(document["sources"][name]["reason"])
        self.assertEqual("unknown", document["progress"]["status"])
        self.assertIsNone(document["progress"]["percent"])
        self.assertEqual(2, document["progress"]["total"])
        self.assertEqual(
            {"unknown"}, {edge["state"] for edge in edges_of(document, "depends_on")}
        )

    def test_dependency_cycle_is_refused(self) -> None:
        build = example()
        build["tickets"][0]["depends_on"] = ["BO-002"]
        with self.assertRaises(GraphDocumentError) as caught:
            pack_walk_document(build)
        self.assertIn("dependency cycle", str(caught.exception))

    def test_serializes_with_publishes_one_edge_per_pair(self) -> None:
        build = example()
        build["tickets"][0]["serializes_with"] = ["BO-002"]
        build["tickets"][1]["serializes_with"] = ["BO-001"]
        document = pack_walk_document(build)
        self.assertEqual(
            [("BO-001", "BO-002")],
            [(edge["from"], edge["to"]) for edge in edges_of(document, "serializes_with")],
        )

    def test_product_features_become_document_features(self) -> None:
        build = example()
        build["product_features"] = [{
            "slug": "dashboard",
            "label": "Dashboard",
            "ticket_ids": ["BO-001", "BO-002"],
        }]
        document = pack_walk_document(build)
        self.assertEqual(["dashboard"], [
            feature["key"] for feature in document["features"]
        ])
        self.assertEqual(["dashboard", "dashboard"], [
            ticket["feature"] for ticket in document["tickets"]
        ])
        self.assertEqual(["dashboard"], document["epics"][0]["features"])


class DocumentLoadTests(unittest.TestCase):
    def test_wrong_contract_and_missing_keys_are_refused(self) -> None:
        document = known_document()
        document["contract_version"] = 2
        with self.assertRaises(GraphDocumentError):
            load_document(document)
        document = known_document()
        del document["waves"]
        with self.assertRaises(GraphDocumentError) as caught:
            load_document(document)
        self.assertIn("waves", str(caught.exception))

    def test_daemon_document_is_read_through_the_cli(self) -> None:
        published = known_document()
        calls: list[list[str]] = []

        class Result:
            returncode = 0
            stdout = json.dumps(published)
            stderr = ""

        def runner(command, **_kwargs):
            calls.append(command)
            return Result()

        document = read_daemon_document(42, cli="aiur", runner=runner)
        self.assertEqual(DOCUMENT_DAEMON, document_source(document))
        self.assertEqual(
            [
                "aiur", "build-orders", "--json", "--contract", "build-order.v1", "42",
            ],
            calls[0],
        )

    def test_daemon_failure_is_refused(self) -> None:
        class Result:
            returncode = 1
            stdout = ""
            stderr = "aiur: no daemon"

        with self.assertRaises(GraphDocumentError) as caught:
            read_daemon_document(runner=lambda *_args, **_kwargs: Result())
        self.assertIn("aiur: no daemon", str(caught.exception))


class ReviewRenderingTests(unittest.TestCase):
    def test_review_renders_published_facts(self) -> None:
        body = render_review(known_document())
        self.assertIn("# Build Order review: Operator dashboard", body)
        self.assertIn("Document source: published daemon document.", body)
        self.assertIn("| 2 | BO-002 |", body)
        self.assertIn("| BO-002 | BO-001 | cleared |", body)
        self.assertIn("`BO-002 → BO-001`", body)
        self.assertIn("1 of 2 complete, 50%.", body)
        self.assertIn("| GATE-001 | Approve graph interaction contract | open | BO-001 |", body)
        self.assertIn("| Platform | build-lane:platform | 1 |", body)

    def test_unknown_sources_publish_a_notice_not_an_empty_table(self) -> None:
        body = render_review(pack_walk_document(example()))
        self.assertIn(
            "> Blocking state is unknown: pack walk: no tracker read, so blocking state is unknown.",
            body,
        )
        self.assertIn("> Progress is unknown: pack walk: no runtime progress read.", body)
        self.assertNotIn("| Ticket | Depends on | State |", body)
        self.assertNotIn("0%", body)
        self.assertNotIn("complete,", body)

    def test_sections_without_a_producer_are_omitted(self) -> None:
        body = render_review(known_document())
        self.assertNotIn("## Features", body)
        document = known_document()
        document["gates"] = []
        document["edges"] = [
            edge for edge in document["edges"] if edge["kind"] != "gates"
        ]
        self.assertNotIn("## Gates", render_review(document))


class ReviewCheckTests(unittest.TestCase):
    def test_example_pack_document_is_consistent(self) -> None:
        self.assertEqual([], errors_for(pack_walk_document(example())))

    def test_reversed_dependency_edge_fails(self) -> None:
        document = pack_walk_document(example())
        document["edges"] = [
            edge for edge in document["edges"] if edge["kind"] != "depends_on"
        ] + [{
            "from": "BO-001", "to": "BO-002", "kind": "depends_on",
            "state": "unknown", "source": "pack",
        }]
        errors = errors_for(document)
        self.assertIn(
            "review document: dependency BO-001 -> BO-002 is not in the pack", errors,
        )
        self.assertIn(
            "review document: dependency BO-001 -> BO-002 is reversed", errors,
        )

    def test_dropped_dependency_edge_fails(self) -> None:
        document = pack_walk_document(example())
        document["edges"] = [
            edge for edge in document["edges"] if edge["kind"] != "depends_on"
        ]
        self.assertIn(
            "review document: dependency BO-002 -> BO-001 is missing from the document",
            errors_for(document),
        )

    def test_wave_order_violation_fails(self) -> None:
        document = pack_walk_document(example())
        for wave in document["waves"]:
            wave["tickets"] = ["BO-001", "BO-002"]
        self.assertIn(
            "review document: wave 2 for BO-002 is not after wave 2 for its "
            "dependency BO-001",
            errors_for(document),
        )

    def test_known_blocking_state_under_an_unknown_tracker_fails(self) -> None:
        document = pack_walk_document(example())
        edges_of(document, "depends_on")[0]["state"] = "cleared"
        self.assertIn(
            "review document: dependency BO-002 -> BO-001 claims a blocking state "
            "while the tracker source is unknown",
            errors_for(document),
        )

    def test_critical_path_must_follow_published_dependencies(self) -> None:
        document = pack_walk_document(example())
        document["critical_path"]["tickets"] = ["BO-001", "BO-002"]
        self.assertIn(
            "review document: critical path BO-001 -> BO-002 is not a published dependency",
            errors_for(document),
        )

    def test_cyclic_pack_fails_even_with_a_supplied_document(self) -> None:
        build = example()
        build["tickets"][0]["depends_on"] = ["BO-002"]
        errors = " ".join(errors_for(pack_walk_document(example()), build))
        self.assertIn("review document: hard dependency cycle", errors)

    def test_missing_ticket_fails(self) -> None:
        document = pack_walk_document(example())
        document["tickets"] = [
            ticket for ticket in document["tickets"] if ticket["id"] != "BO-001"
        ]
        self.assertIn(
            "review document: ticket BO-001 is missing from the document",
            errors_for(document),
        )

    def test_unpublished_lane_fails(self) -> None:
        document = pack_walk_document(example())
        document["lanes"] = [
            lane for lane in document["lanes"] if lane["key"] != "platform"
        ]
        self.assertIn(
            "review document: ticket BO-001 names a lane the document does not publish",
            errors_for(document),
        )


class ReviewCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build-order.json"
        self.build.write_text(json.dumps(example()), encoding="utf-8")

    def run_cli(self, *arguments: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(["render_build_order_review.py", *arguments])
        return code, out.getvalue(), err.getvalue()

    def test_cli_writes_the_review_and_names_the_source(self) -> None:
        target = self.root / "graph-review.md"
        code, stdout, stderr = self.run_cli(
            "--build", str(self.build), "--out", str(target),
        )
        self.assertEqual(0, code)
        self.assertEqual("", stdout)
        self.assertIn("document source: pack-walk", stderr)
        self.assertIn("# Build Order review: Operator dashboard", target.read_text(encoding="utf-8"))

    def test_cli_check_mode_detects_a_stale_review(self) -> None:
        target = self.root / "graph-review.md"
        target.write_text("# stale review\n", encoding="utf-8")
        code, _stdout, stderr = self.run_cli(
            "--build", str(self.build), "--check", str(target),
        )
        self.assertEqual(1, code)
        self.assertIn("does not match the review rendered", stderr)

    def test_cli_refuses_an_inconsistent_document(self) -> None:
        document = pack_walk_document(example())
        document["edges"] = [
            edge for edge in document["edges"] if edge["kind"] != "depends_on"
        ]
        path = self.root / "document.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        target = self.root / "graph-review.md"
        code, _stdout, stderr = self.run_cli(
            "--build", str(self.build), "--document", str(path), "--out", str(target),
        )
        self.assertEqual(1, code)
        self.assertIn("is missing from the document", stderr)
        self.assertFalse(target.exists())


class PublicationGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build-order.json"
        self.build.write_text(json.dumps(example()), encoding="utf-8")
        self.review = self.root / "graph-review.md"

    def test_matching_review_passes_publication(self) -> None:
        self.review.write_text(
            render_review(pack_walk_document(example())), encoding="utf-8",
        )
        check_graph_review(self.build, self.review)

    def test_stale_review_fails_publication(self) -> None:
        self.review.write_text(
            "# Build Order review\n\n## Dependencies\n\n| Ticket | Depends on |\n",
            encoding="utf-8",
        )
        with self.assertRaises(PublicationError) as caught:
            check_graph_review(self.build, self.review)
        self.assertIn("does not match the review rendered", str(caught.exception))

    def test_review_of_a_cyclic_pack_fails_publication(self) -> None:
        build = example()
        build["tickets"][0]["depends_on"] = ["BO-002"]
        self.build.write_text(json.dumps(build), encoding="utf-8")
        self.review.write_text("", encoding="utf-8")
        with self.assertRaises(PublicationError) as caught:
            check_graph_review(self.build, self.review)
        self.assertIn("dependency cycle", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
