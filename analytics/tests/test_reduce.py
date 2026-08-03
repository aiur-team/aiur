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


if __name__ == "__main__":
    unittest.main()
