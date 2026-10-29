#!/usr/bin/env python3
"""Allocation-evidence contracts for telemetry and durable run summaries."""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "newsletter"))
import collect
from allocation_sources import allocation_evidence
from local_sources import iso

NOW = datetime.now(timezone.utc).replace(microsecond=0)
STAMP = iso(NOW)


def lifecycle(at, ticket, attempt, operation, boundary, record_id=None):
    row = {"attributes": {"ticket": str(ticket), "attempt_id": attempt, "operation_id": operation,
                           "event": "implement", "boundary": boundary},
           "boot_id": "boot-a", "kind": "lifecycle", "timestamp": iso(at)}
    if record_id:
        row["record_id"] = record_id
    return row


def run_context(at):
    return {"attributes": {}, "boot_id": "boot-a", "kind": "run_context", "timestamp": iso(at)}


def write_telemetry(root, rows):
    root.mkdir(parents=True, exist_ok=True)
    (root / "telemetry.ndjson").write_text("".join(json.dumps(row) + "\n" for row in rows))


def write_summary(state, rows):
    path = state / "analytics" / "runs" / "boot-a" / "run-summary.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema_version": 1, "boot_id": "boot-a", "generated_at": STAMP,
                                "records": rows}, indent=2) + "\n")
    return path


def daemon(_args):
    return json.dumps({"sources": {"units_catalog": {"state": "available", "observed_at": STAMP}},
                       "data": {"view": {"rows": []}},
                       "auxiliary": {"running_build": {"sha": "b" * 40, "built_at": STAMP}}})


class TrackingGitHub:
    cost, calls, cost_complete = 1, 1, True

    def __init__(self):
        self.issue_batches = []

    def phase_labels(self):
        return []

    def search(self, _expression, _fields, _kind):
        return []

    def issues(self, numbers):
        numbers = set(numbers)
        self.issue_batches.append(numbers)
        return {number: {"number": number, "title": f"Issue {number}",
                         "labels": {"nodes": [{"name": "feature:newsletter"}],
                                    "pageInfo": {"hasNextPage": False}}}
                for number in numbers}


class AllocationTest(unittest.TestCase):
    def test_missing_sources_are_unavailable_in_reader_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = allocation_evidence(root, NOW, {}, telemetry_root=root / "missing")
        self.assertEqual(set(result), {"pc", "nuc"})
        for machine in ("pc", "nuc"):
            self.assertEqual(set(result[machine]), {"turns", "intake", "feature_supply"})
            for block in result[machine].values():
                self.assertEqual((block["state"], block["complete"], block["records"]),
                                 ("unavailable", False, None))

    def test_summary_history_hydrates_tickets_deduplicates_and_clips_open_turns(self):
        start7 = NOW - timedelta(days=8)
        opened = lifecycle(NOW - timedelta(minutes=3), 43, "open", "turn:1", "start", "open-start")
        duplicate = lifecycle(NOW - timedelta(minutes=5), 42, "closed", "turn:2", "start", "duplicate-start")
        ended = lifecycle(NOW - timedelta(minutes=4), 42, "closed", "turn:2", "end", "closed-end")
        future = lifecycle(NOW + timedelta(minutes=1), 44, "future", "turn:1", "start", "future-start")
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            telemetry = Path(tmp) / "telemetry"
            write_summary(state, [run_context(start7), duplicate, ended, opened])
            write_telemetry(telemetry, [duplicate, opened, future,
                                        {"attributes": {}, "kind": "resource", "timestamp": STAMP}])
            result = collect.collect("owner/repo", state, NOW, TrackingGitHub(), daemon,
                                     telemetry_root=telemetry)

        block = result["allocation_evidence"]["pc"]["turns"]
        self.assertEqual((block["state"], block["complete"]), ("available", True))
        self.assertEqual(block["window_start"], iso(start7))
        self.assertEqual(block["active_turns_clipped"], 1)
        self.assertEqual(len(block["records"]), 2)
        closed = next(row for row in block["records"] if row["number"] == 42)
        active = next(row for row in block["records"] if row["number"] == 43)
        self.assertEqual(closed["attempt_id"], "closed:turn:2")
        self.assertEqual(active["ended_at"], iso(NOW))
        self.assertNotIn(44, {row["number"] for row in block["records"]})

    def test_turn_window_is_widest_available_instead_of_forcing_seven_days(self):
        coverage_start = NOW - timedelta(days=3)
        rows = [run_context(coverage_start),
                lifecycle(NOW - timedelta(minutes=2), 42, "a", "turn:1", "start"),
                lifecycle(NOW - timedelta(minutes=1), 42, "a", "turn:1", "end"),
                {"attributes": {}, "kind": "resource", "timestamp": STAMP}]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_telemetry(root / "telemetry", rows)
            result = allocation_evidence(root, NOW, {42: {"labels": ["feature:newsletter"], "title": "Issue 42"}},
                                         telemetry_root=root / "telemetry")
        block = result["pc"]["turns"]
        self.assertEqual(block["state"], "available")
        self.assertEqual(block["window_start"], iso(coverage_start))
        self.assertLessEqual(datetime.fromisoformat(block["window_start"].replace("Z", "+00:00")),
                             NOW - timedelta(days=1))
        self.assertGreater(datetime.fromisoformat(block["window_start"].replace("Z", "+00:00")),
                           NOW - timedelta(days=7))

    def test_clean_day_remains_available_when_older_seven_day_events_are_incomplete(self):
        coverage_start = NOW - timedelta(days=8)
        rows = [run_context(coverage_start),
                lifecycle(NOW - timedelta(days=2), 41, "orphan", "turn:old", "end"),
                lifecycle(NOW - timedelta(days=2), 42, "recent", "turn:new", "start"),
                lifecycle(NOW - timedelta(hours=3), 42, "recent", "turn:new", "start"),
                lifecycle(NOW - timedelta(minutes=2), 42, "recent", "turn:new", "start"),
                lifecycle(NOW - timedelta(minutes=2) + timedelta(milliseconds=1),
                          42, "recent", "turn:new", "start", "duplicate-start"),
                lifecycle(NOW - timedelta(minutes=1), 42, "recent", "turn:new", "end")]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_telemetry(root / "telemetry", rows)
            result = allocation_evidence(root, NOW,
                {42: {"labels": ["feature:newsletter"], "title": "Issue 42"}},
                telemetry_root=root / "telemetry")
        block = result["pc"]["turns"]
        self.assertEqual(block["state"], "available")
        self.assertEqual(block["window_start"], iso(NOW - timedelta(days=1)))
        self.assertEqual([row["number"] for row in block["records"]], [42])

    def test_supply_accepts_one_ms_seams_and_reports_restart_gap_observation(self):
        start = NOW - timedelta(days=1)
        base = int(start.timestamp() * 1000)
        ten_minutes = 10 * 60_000

        def interval(event_id, lower, upper, observed):
            return {"attributes": {"event": "interval", "event_key": event_id,
                                    "interval_start_ms": lower, "interval_end_ms": upper,
                                    "feature_starved_slot_minutes": 2.0,
                                    "non_feature_during_starvation_minutes": 1.0,
                                    "observed_minutes": observed},
                    "kind": "feature_supply", "timestamp": STAMP}

        rows = [run_context(start - timedelta(seconds=1)),
                interval("a", base - 1, base + ten_minutes, 10.0),
                interval("b", base + ten_minutes + 1, base + 2 * ten_minutes, 10.0),
                interval("c", base + 2 * ten_minutes + 5 * 60_000,
                         int(NOW.timestamp() * 1000), 25.0)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_telemetry(root / "telemetry", rows)
            result = allocation_evidence(root, NOW, {}, telemetry_root=root / "telemetry")
        block = result["pc"]["feature_supply"]
        self.assertEqual((block["state"], block["complete"]), ("available", True))
        self.assertEqual(len(block["records"]), 3)
        self.assertAlmostEqual(block["observed_minutes"], 45.0, places=3)
        self.assertGreater(block["unobserved_minutes"], 1_390)

    def test_malformed_telemetry_is_not_silently_reported_as_available(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            telemetry = root / "telemetry"
            telemetry.mkdir()
            (telemetry / "telemetry.ndjson").write_text("{not-json}\n")
            with self.assertRaises(json.JSONDecodeError):
                allocation_evidence(root, NOW, {}, telemetry_root=telemetry)
            snapshot = collect.collect("owner/repo", root, NOW, TrackingGitHub(), daemon,
                                       telemetry_root=telemetry)
        self.assertEqual(snapshot["sources"]["allocation_evidence"]["state"], "unavailable")
        self.assertIn("property name", snapshot["sources"]["allocation_evidence"]["reason"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
