"""Terminal PR facts survive reduction and boot scoping."""
import json
import tempfile
import unittest
from pathlib import Path

from analytics import reduce as reducer
from analytics.materialize import boot_summary


class PrFactsTest(unittest.TestCase):
    def test_facts_survive_reduce_and_boot_summary(self):
        facts = {"ticket": "46", "event": "pr_facts", "boundary": "point",
                 "pr_ready_at": "2026-10-09T00:01:00Z", "approval_count": 1,
                 "reviewer_classes": ["trusted"], "epic": 3774}
        record = {"schema_version": 2, "kind": "lifecycle", "timestamp": "2026-10-09T00:05:00Z",
                  "boot_id": "facts-boot", "sequence": 1, "record_id": "facts-boot:1", "attributes": facts}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "telemetry.ndjson"
            path.write_text(json.dumps(record) + "\n")
            dataset = reducer.reduce_files([path])
        self.assertEqual(dataset["tickets"]["46"]["pr_facts"], facts)
        self.assertEqual(dataset["tickets"]["46"]["events"][0]["pr_facts"], facts)
        self.assertEqual(boot_summary(dataset, "facts-boot")["tickets"]["46"]["pr_facts"], facts)
