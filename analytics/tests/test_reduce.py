"""Tests for the tolerant offline reducer."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from analytics import reduce as reducer
from analytics import sources

FIXTURES = Path(__file__).parent / "fixtures"
SESSION_A = FIXTURES / "session-a" / "telemetry.ndjson"
SESSION_B = FIXTURES / "session-b" / "telemetry.ndjson"
BUILD_ORDER = FIXTURES / "build-order.json"


class ReduceFilesTest(unittest.TestCase):
    def test_reduces_fixture_stream(self):
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])

        # 17 valid records in session-a (one malformed line is a warning) + 7 in
        # session-b.
        self.assertEqual(dataset["provenance"]["record_count"], 24)
        self.assertIn("boot-a", {r["boot_id"] for r in dataset["records"]})
        self.assertIn("boot-b", {r["boot_id"] for r in dataset["records"]})

        # Tolerant parse: the malformed line became a warning, not a crash.
        self.assertTrue(any(w["type"] == "malformed_line" for w in dataset["warnings"]))

        # Actors: daemon, operator, and the two ticket actors.
        self.assertIn("_daemon", dataset["actors"])
        self.assertIn("ticket:930", dataset["actors"])
        self.assertIn("ticket:931", dataset["actors"])

        # Tickets keyed by bare number.
        self.assertIn("930", dataset["tickets"])
        self.assertIn("931", dataset["tickets"])

    def test_profile_statistics(self):
        dataset = reducer.reduce_files([SESSION_A])
        actor = dataset["actors"]["ticket:930"]
        profile = actor["profile"]
        self.assertEqual(profile["cpu_percent"]["count"], 2)
        self.assertEqual(profile["cpu_percent"]["min"], 50.0)
        self.assertEqual(profile["cpu_percent"]["max"], 80.0)
        self.assertAlmostEqual(profile["cpu_percent"]["mean"], 65.0)
        # median of [50, 80] interpolates to 65.0
        self.assertAlmostEqual(profile["cpu_percent"]["median"], 65.0)
        # p95 nearest rank of 2 values = max
        self.assertAlmostEqual(profile["cpu_percent"]["p95"], 80.0)

    def test_availability_counts(self):
        dataset = reducer.reduce_files([SESSION_A])
        daemon = dataset["actors"]["_daemon"]
        self.assertEqual(daemon["availability"], {"measured": 1, "unavailable": 0})
        operator = dataset["actors"]["_operator"]
        self.assertEqual(operator["availability"], {"measured": 0, "unavailable": 1})

    def test_ticket_930_has_merged_status_events(self):
        dataset = reducer.reduce_files([SESSION_A])
        ticket = dataset["tickets"]["930"]
        phases = [interval["phase"] for interval in ticket["intervals"]]
        self.assertIn("pr_merged", phases)
        self.assertEqual(ticket["complexity"], 2)

    def test_build_test_interval_closed(self):
        dataset = reducer.reduce_files([SESSION_A])
        ticket = dataset["tickets"]["930"]
        build_interval = next(iv for iv in ticket["intervals"] if iv["phase"] == "build_test")
        self.assertEqual(build_interval["status"], "closed")
        self.assertEqual(build_interval["outcome"], "failed")
        self.assertEqual(build_interval["duration_ms"], 2000)

    def test_open_interval_for_unfinished_work(self):
        # Ticket 931's implement start is never ended within boot-a.
        dataset = reducer.reduce_files([SESSION_A])
        ticket = dataset["tickets"]["931"]
        impl = next(iv for iv in ticket["intervals"] if iv["phase"] == "implement")
        self.assertEqual(impl["status"], "open")
        self.assertIsNone(impl["end_ms"])

    def test_unsupported_schema_record_is_warned(self):
        lines = [
            json.dumps(
                {
                    "schema_version": 99,
                    "kind": "resource",
                    "timestamp": "2026-07-11T00:00:00Z",
                    "boot_id": "x",
                    "sequence": 1,
                    "record_id": "x:1",
                    "attributes": {},
                }
            ),
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "lifecycle",
                    "timestamp": "2026-07-11T00:00:01Z",
                    "boot_id": "x",
                    "sequence": 2,
                    "record_id": "x:2",
                    "attributes": {"ticket": "1", "event": "dispatch", "boundary": "point"},
                }
            ),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "telemetry.ndjson"
            path.write_text("\n".join(lines) + "\n")
            dataset = reducer.reduce_files([path])
        self.assertEqual(dataset["provenance"]["record_count"], 1)
        self.assertTrue(any(w["type"] == "unsupported_schema" for w in dataset["warnings"]))
        self.assertEqual(dataset["tickets"]["1"]["complexity"], None)


class BootSummaryTest(unittest.TestCase):
    def test_boot_summary_rescopes_actors_and_tickets(self):
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])
        summary = reducer.boot_summary(dataset, "boot-b")

        self.assertEqual(summary["schema_version"], 1)
        self.assertEqual(summary["boot_id"], "boot-b")
        self.assertTrue(all(r["boot_id"] == "boot-b" or r["boot_id"] == "github" for r in summary["records"]))
        # boot-b actor samples only.
        self.assertEqual(summary["actors"]["ticket:930"]["profile"]["cpu_percent"]["count"], 1)
        # Ticket 931 did not run in boot-b; dropped.
        self.assertNotIn("931", summary["tickets"])
        # Provenance identifies sources.
        self.assertIn("source_files", summary)
        self.assertIn("source_bytes", summary)
        self.assertGreater(summary["source_bytes"], 0)
        self.assertIn("generated_at", summary)

    def test_run_summary_materializes_and_reloads(self):
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])
        with tempfile.TemporaryDirectory() as tmp:
            state_node = Path(tmp) / "repo" / "owner" / "name"
            written = reducer.write_all_run_summaries(state_node, dataset, ["boot-a", "boot-b"])
            self.assertEqual(len(written), 2)

            path = sources.run_summary_path(state_node, "boot-a")
            self.assertTrue(path.is_file())
            loaded = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(loaded["boot_id"], "boot-a")
            self.assertEqual(loaded["schema_version"], 1)
            self.assertIn("930", loaded["tickets"])

    def test_boot_summary_keeps_only_that_boots_scoped_warnings(self):
        # Two boots each with a sequence gap: a per-boot summary must not carry
        # the other boot's gap.
        lines = [
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "lifecycle",
                    "timestamp": "2026-07-11T01:00:00Z",
                    "boot_id": "boot-a",
                    "sequence": 1,
                    "record_id": "boot-a:1",
                    "attributes": {"ticket": "1", "event": "dispatch", "boundary": "point"},
                }
            ),
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "lifecycle",
                    "timestamp": "2026-07-11T01:00:02Z",
                    "boot_id": "boot-a",
                    "sequence": 3,
                    "record_id": "boot-a:3",
                    "attributes": {"ticket": "1", "event": "agent_pause", "boundary": "point"},
                }
            ),
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "lifecycle",
                    "timestamp": "2026-07-11T02:00:00Z",
                    "boot_id": "boot-b",
                    "sequence": 1,
                    "record_id": "boot-b:1",
                    "attributes": {"ticket": "2", "event": "dispatch", "boundary": "point"},
                }
            ),
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "lifecycle",
                    "timestamp": "2026-07-11T02:00:02Z",
                    "boot_id": "boot-b",
                    "sequence": 3,
                    "record_id": "boot-b:3",
                    "attributes": {"ticket": "2", "event": "agent_pause", "boundary": "point"},
                }
            ),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "telemetry.ndjson"
            path.write_text("\n".join(lines) + "\n")
            dataset = reducer.reduce_files([path])

        gaps_by_boot = {w["boot_id"] for w in dataset["warnings"] if w["type"] == "sequence_gap"}
        self.assertEqual(gaps_by_boot, {"boot-a", "boot-b"})

        summary_a = reducer.boot_summary(dataset, "boot-a")
        self.assertEqual(
            {w["boot_id"] for w in summary_a["warnings"] if w["type"] == "sequence_gap"}, {"boot-a"}
        )
        summary_b = reducer.boot_summary(dataset, "boot-b")
        self.assertEqual(
            {w["boot_id"] for w in summary_b["warnings"] if w["type"] == "sequence_gap"}, {"boot-b"}
        )


class BuildSummaryTest(unittest.TestCase):
    def test_build_summary_rolls_up_members(self):
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])
        build_order = json.loads(BUILD_ORDER.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            state_node = Path(tmp) / "node"
            path = reducer.build_summary_for(state_node, dataset, "test-build", build_order)
            self.assertTrue(Path(path).is_file())
            loaded = json.loads(Path(path).read_text(encoding="utf-8"))
            self.assertEqual(loaded["build_order"]["member_count"], 3)
            self.assertIn("930", loaded["tickets"])
            self.assertIn("931", loaded["tickets"])
            # Member that never ran is not in tickets.
            self.assertNotIn("999", loaded["tickets"])
            # Cross-boot: ticket 930 has events from both boots.
            boots = {e["boot_id"] for e in loaded["tickets"]["930"]["events"]}
            self.assertEqual(boots, {"boot-a", "boot-b"})


class SchemaConformanceTest(unittest.TestCase):
    """Both materialized shapes must stay within the declared schema.

    The schema sets ``additionalProperties: false``, so any top-level key the
    reducer emits but the schema does not declare is a silent contract break --
    exactly how the ``build_order`` rollup key drifted out of the schema. These
    checks are stdlib-only (no jsonschema dependency) and assert the two
    properties that drift actually violates: every declared ``required`` key is
    emitted, and every emitted key is declared.
    """

    def setUp(self):
        schema_path = Path(__file__).resolve().parents[1] / "schema" / "run-summary.v1.json"
        self.schema = json.loads(schema_path.read_text(encoding="utf-8"))
        self.assertFalse(
            self.schema.get("additionalProperties", True),
            "schema must forbid undeclared top-level keys for this check to mean anything",
        )
        self.dataset = reducer.reduce_files([SESSION_A, SESSION_B])

    def assert_conforms(self, summary):
        declared = set(self.schema["properties"])
        self.assertEqual(
            set(summary) - declared,
            set(),
            "summary emits top-level keys the schema does not declare",
        )
        self.assertEqual(
            set(self.schema["required"]) - set(summary),
            set(),
            "summary omits keys the schema marks required",
        )

    def test_run_summary_conforms(self):
        summary = reducer.boot_summary(self.dataset, "boot-a")
        self.assertNotIn("build_order", summary, "build_order belongs only to build rollups")
        self.assert_conforms(summary)

    def test_build_rollup_conforms(self):
        build_order = json.loads(BUILD_ORDER.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            path = reducer.build_summary_for(Path(tmp) / "node", self.dataset, "test-build", build_order)
            summary = json.loads(Path(path).read_text(encoding="utf-8"))

        self.assertIn("build_order", summary)
        self.assert_conforms(summary)


if __name__ == "__main__":
    unittest.main()
