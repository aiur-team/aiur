"""Cohort preservation across the versioned capture and summary contracts."""
import json
import tempfile
import unittest
from pathlib import Path
from analytics import reduce as reducer


class CohortTest(unittest.TestCase):
    def test_v3_context_and_attempt_survive_with_v2_restart(self):
        cohort = dict(backend="codex", model="m", effort="high", feature=None,
                      epic=3774, tags=["experiment:x"], blockers=["3755"], start_mode="normal")
        values = [(2, "restart", {"event": "daemon_restart"}),
                  (3, "run_context", {"config_hash": "hash", "build_sha": "abc"}),
                  (3, "lifecycle", dict(ticket="3794", event="dispatch", boundary="point", **cohort))]
        records = [dict(schema_version=v, kind=k, attributes=a, sequence=i,
                        boot_id="cohort", record_id=f"cohort:{i}", timestamp="2026-10-09T00:00:00Z")
                   for i, (v, k, a) in enumerate(values, 1)]
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "telemetry.ndjson"
            path.write_text("\n".join(map(json.dumps, records)) + "\n")
            dataset = reducer.reduce_files([str(path)])
        self.assertEqual(dataset["warnings"], [])
        event = dataset["tickets"]["3794"]["events"][0]
        self.assertEqual({key: event[key] for key in cohort}, cohort)
        summary = reducer.boot_summary(dataset, "cohort")
        self.assertEqual(summary["run_contexts"][0]["attributes"], {"config_hash": "hash", "build_sha": "abc"})
        self.assertEqual(summary["provenance"]["schema_versions"], [2, 3])
