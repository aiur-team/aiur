#!/usr/bin/env python3
"""Fixture-only allocation evidence, missing-source and wiring contracts."""
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "newsletter"))
from local_sources import iso
from metrics import compute
from metric_supply import METRICS

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def stamp(hours=0):
    return iso(NOW + timedelta(hours=hours))


def snapshot():
    return {"repo": "owner/repo", "captured_at": stamp(), "window_start": stamp(-24), "window_end": stamp(),
            "program": {"tickets": []}, "merges": [], "running_build": {}, "meta": [], "executor_actions": [],
            "allocation": {"units": {"running": {"feature": 0, "other": 10}}}, "allocation_evidence": {}}


def block(records, hours=168, **extra):
    return {"state": "available", "complete": True, "window_start": stamp(-hours), "window_end": stamp(),
            "records": records, **extra}


def turn(identity, number, start, end, labels=(), **extra):
    return {"attempt_id": identity, "number": number, "phase": "implement", "started_at": stamp(start),
            "ended_at": stamp(end), "labels": list(labels), "title": "Work", **extra}


def report(data):
    return compute(data)["allocation"]


def value(node):
    return node["value"]


class AllocationTest(unittest.TestCase):
    def test_seven_day_headline_and_ticket_share_are_per_machine_against_target(self):
        data = snapshot()
        data["allocation_evidence"] = {
            "pc": {"turns": block([turn("a", 1, -100, -96, ["feature:mail"]),
                                   turn("b", 2, -96, -92, ["build-order"]), turn("c", 3, -92, -90)])},
            "nuc": {"turns": block([turn("a", 1, -10, -9, ["build-lane:mail"]), turn("b", 4, -9, -6)])}}
        result = report(data)
        pc, nuc = (result["headline"][m]["rolling_7d"] for m in ("pc", "nuc"))
        self.assertEqual(value(pc["feature_turn_hours_percent"]), 80)
        self.assertEqual(value(nuc["feature_turn_hours_percent"]), 25)
        self.assertAlmostEqual(value(pc["feature_tickets_percent"]), 200 / 3)
        self.assertEqual(value(nuc["feature_tickets_percent"]), 50)
        self.assertEqual(value(pc["target_percent"]), 95)
        self.assertEqual(value(nuc["target_percent"]), 95)
        self.assertEqual(value(result["instant_context"]["feature_percent"]), 0)
        self.assertEqual(value(result["headline"]["pc"]["window_24h"]["turn_hours"]), 0)

    def test_missing_seven_day_evidence_is_unavailable_per_machine_not_daily_proxy(self):
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"turns": block([turn("a", 1, -2, -1, ["feature:mail"])], hours=24)}}
        result = report(data)["headline"]
        self.assertEqual(value(result["pc"]["window_24h"]["feature_turn_hours_percent"]), 100)
        for machine in ("pc", "nuc"):
            for key in ("turn_hours", "feature_turn_hours_percent", "tickets_worked", "feature_tickets_percent",
                        "main_fix_hours", "unlabelled_product_hours"):
                self.assertEqual(value(result[machine]["rolling_7d"][key]), "unavailable", (machine, key))
        data["allocation_evidence"]["pc"]["turns"] = block([], state="stale")
        self.assertEqual(value(report(data)["headline"]["pc"]["rolling_7d"]["turn_hours"]), "unavailable")
        data["allocation_evidence"]["pc"]["turns"] = block([], complete=False)
        self.assertEqual(value(report(data)["headline"]["pc"]["rolling_7d"]["turn_hours"]), "unavailable")

    def test_turn_hours_clip_window_and_deduplicate_attempts_not_tickets(self):
        data = snapshot()
        row = turn("a", 1, -169, -167, ["feature:mail"])
        records = [row, copy.deepcopy(row), turn("b", 1, -2, -1, ["feature:mail"]),
                   turn("c", 2, -1, 0, phase="review")]
        data["allocation_evidence"] = {"pc": {"turns": block(records, hours=200)}}
        result = report(data)["headline"]["pc"]["rolling_7d"]
        self.assertEqual(value(result["turn_hours"]), 2)
        self.assertEqual(value(result["feature_tickets_worked"]), 1)
        self.assertEqual(value(result["tickets_worked"]), 1)
        self.assertEqual(value(result["feature_turn_hours_percent"]), 100)

    def test_main_red_and_merge_blocking_hours_are_separate_nonfeature_work(self):
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"turns": block([
            turn("a", 1, -12, -3, ["feature:mail"]), turn("b", 2, -3, -2, ["main-fix"]),
            turn("c", 3, -2, -1, incident_kind="merge-blocking")])}}
        result = report(data)["headline"]["pc"]["rolling_7d"]
        self.assertEqual(value(result["main_fix_hours"]), 2)
        self.assertEqual(value(result["hours_by_class"]["test_ci"]), 0)
        self.assertEqual(value(result["hours_by_class"]["other"]), 0)
        self.assertEqual(value(result["turn_hours"]), 11)
        self.assertAlmostEqual(value(result["feature_turn_hours_percent"]), 900 / 11)

    def test_unlabelled_product_requires_explicit_evidence_and_stays_nonfeature(self):
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"turns": block([
            turn("a", 1, -10, -2, title="MP-12 Fix login", product_directive="operator-decision-123"),
            turn("b", 2, -2, -1, title="MP-13 Fix login"), turn("c", 3, -1, 0, ["feature:mail"])])}}
        result = report(data)["headline"]["pc"]["rolling_7d"]
        self.assertEqual(value(result["unlabelled_product_hours"]), 8)
        self.assertEqual(value(result["unlabelled_product_tickets"]), 1)
        self.assertEqual(value(result["hours_by_class"]["other"]), 1)
        self.assertEqual(value(result["feature_turn_hours_percent"]), 10)

    def test_nonfeature_intake_uses_first_dispatch_and_source_not_current_labels(self):
        def intake(number, source, **extra):
            return {"number": number, "created_at": stamp(-1), "first_dispatch_state": "todo", "labels": [],
                    "source": source, "title": "New work", **extra}
        rows = [intake(1, "flake_recorder"), intake(2, "agent", title="MP-12 Fix login"), intake(3, "executor"),
                intake(4, None), intake(5, "executor", labels=["feature:mail"]),
                intake(6, "agent", first_dispatch_state="parked", labels=["agent:todo"]),
                intake(7, "agent", created_at=stamp(-25))]
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"intake": block(rows + [copy.deepcopy(rows[0])], hours=24)}}
        result = report(data)["non_feature_intake"]
        self.assertEqual(value(result["pc"]["non_feature"]), 4)
        self.assertEqual(value(result["pc"]["all_direct_to_todo"]), 5)
        self.assertEqual(value(result["pc"]["non_feature_percent"]), 80)
        self.assertEqual({k: value(v) for k, v in result["pc"]["by_source"].items()},
                         {"flake_recorder": 1, "agent": 1, "executor": 1, "unknown": 1})
        self.assertEqual(value(result["nuc"]["non_feature"]), "unavailable")
        self.assertEqual(value(result["nuc"]["by_source"]["agent"]), "unavailable")

    def test_feature_starved_slot_minutes_use_native_intervals_and_keep_machines_separate(self):
        def interval(identity, start, end, slots, nonfeature):
            minutes = (end - start) * 60
            return {"event_id": identity, "kind": "feature_supply", "attributes": {
                "event": "interval", "interval_start_ms": (NOW + timedelta(hours=start)).timestamp() * 1000,
                "interval_end_ms": (NOW + timedelta(hours=end)).timestamp() * 1000,
                "feature_starved_slot_minutes": minutes * slots,
                "non_feature_during_starvation_minutes": minutes * nonfeature, "observed_minutes": minutes}}
        data = snapshot()
        row = interval("pc-1", -25, -23, 2, 1)
        data["allocation_evidence"] = {"pc": {"feature_supply": block([row, copy.deepcopy(row)], hours=24)},
                                       "nuc": {"feature_supply": block([interval("nuc-1", -1, 0, 1, 0)], hours=24)}}
        result = report(data)["feature_supply"]
        self.assertEqual(set(result["pc"]), set(METRICS))
        self.assertEqual(value(result["pc"]["feature_starved_slot_minutes"]), 120)
        self.assertEqual(value(result["nuc"]["feature_starved_slot_minutes"]), 60)
        self.assertEqual(value(result["pc"]["observed_minutes"]), 60)
        self.assertEqual(value(result["pc"]["non_feature_during_starvation_minutes"]), 60)
        del data["allocation_evidence"]["nuc"]
        self.assertEqual(value(report(data)["feature_supply"]["nuc"]["feature_starved_slot_minutes"]), "unavailable")
        data["allocation_evidence"]["pc"]["feature_supply"]["records"] = [row]
        del row["attributes"]["feature_starved_slot_minutes"]
        self.assertEqual(value(report(data)["feature_supply"]["pc"]["feature_starved_slot_minutes"]), "unavailable")

    def test_supply_requires_observed_intervals_to_distinguish_zero_from_unavailable(self):
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"feature_supply": block([], hours=24)}}
        self.assertEqual(value(report(data)["feature_supply"]["pc"]["feature_starved_slot_minutes"]), "unavailable")
        row = {"event_id": "observed", "kind": "feature_supply", "attributes": {
            "event": "interval", "interval_start_ms": (NOW - timedelta(hours=1)).timestamp() * 1000,
            "interval_end_ms": NOW.timestamp() * 1000, "feature_starved_slot_minutes": 0,
            "non_feature_during_starvation_minutes": 0, "observed_minutes": 60}}
        data["allocation_evidence"]["pc"]["feature_supply"]["records"] = [row]
        self.assertEqual(value(report(data)["feature_supply"]["pc"]["feature_starved_slot_minutes"]), 0)
        self.assertEqual(value(report(data)["feature_supply"]["pc"]["observed_minutes"]), 60)

    def test_merge_feature_share_reclassifies_cached_title_heuristics_from_real_labels(self):
        data = snapshot()
        data["merges"] = [{"number": n, "merged_at": stamp(-1), "merge_sha": str(n), "class": "feature",
                           "closing_issue": n, "issue_labels": labels, "issue_title": title, "mobile": False}
                          for n, labels, title in [(1, [], "Fix build-order banner refresh"),
                                                   (2, [], "MP-12 Fix login"),
                                                   (3, ["tooling"], "Document feature: flags")]]
        result = compute(data)["outcomes"]["feature_share"]
        self.assertEqual(value(result["feature"]), 0)
        self.assertEqual(value(result["percent"]), 0)
        del data["merges"][0]["issue_labels"]
        self.assertEqual(value(compute(data)["outcomes"]["feature_share"]["percent"]), "unavailable")

    def test_every_new_number_names_sources_and_compute_does_not_mutate_evidence(self):
        data = snapshot()
        data["allocation_evidence"] = {"pc": {"turns": block([turn("a", 1, -1, 0, ["feature:mail"])])}}
        before = copy.deepcopy(data)
        result = report(data)
        def check(node):
            if isinstance(node, dict):
                if "value" in node:
                    self.assertTrue(node["sources"])
                else:
                    for child in node.values():
                        check(child)
            elif isinstance(node, (float, int)):
                self.fail(f"untraced number: {node}")
        check(result)
        self.assertEqual(data, before)
        json.dumps(result, allow_nan=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
