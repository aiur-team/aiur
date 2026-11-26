"""Feature-supply capture is parsed and exposed through the daily report."""
import json
import unittest
from analytics.parse import parse_line
from analytics.feature_supply import daily_supply, supply_lines
from analytics.render import run_summary_kpis, render_run_summary


class FeatureSupplyTest(unittest.TestCase):
    def record(self, attrs):
        record, warning = parse_line(json.dumps({"schema_version": 2, "kind": "feature_supply", "boot_id": "boot",
            "sequence": 1, "record_id": "boot:1", "timestamp": "2026-10-27T00:01:00Z", "attributes": attrs}), "fixture", 1)
        self.assertIsNone(warning)
        self.assertIsNotNone(record)
        return record

    def test_daily_report_splits_midnight_and_sums_boots(self):
        end = 1793059260000  # 2026-10-27 00:01 UTC
        attrs = {"event": "interval", "interval_start_ms": end - 120000, "interval_end_ms": end,
                 "feature_starved_slot_minutes": 4, "non_feature_during_starvation_minutes": 2, "observed_minutes": 2}
        record = self.record(attrs)
        summary = {"records": [record, self.record(dict(attrs, feature_starved_slot_minutes=2))]}
        rows = run_summary_kpis(summary, 3)["feature_supply_daily"]
        self.assertEqual(rows, [
            {"date": "2026-10-26", "feature_starved_slot_minutes": 3.0, "non_feature_during_starvation_minutes": 2.0, "observed_minutes": 2.0},
            {"date": "2026-10-27", "feature_starved_slot_minutes": 3.0, "non_feature_during_starvation_minutes": 2.0, "observed_minutes": 2.0}])
        text = render_run_summary(summary, 3)
        self.assertIn("2026-10-27: 3.00 feature-starved slot-minutes; 2.00 non-feature-during-starvation minutes", text)

    def test_absent_observations_are_unavailable_and_zero_is_measured(self):
        self.assertEqual(daily_supply([]), [])
        self.assertIn("unavailable", " ".join(supply_lines([])))
        record = self.record({"event": "interval", "interval_start_ms": 0, "interval_end_ms": 60000,
                              "feature_starved_slot_minutes": 0, "non_feature_during_starvation_minutes": 0, "observed_minutes": 1})
        self.assertEqual(daily_supply([record])[0]["feature_starved_slot_minutes"], 0)
        self.assertNotIn("unavailable", " ".join(supply_lines(daily_supply([record]))))
