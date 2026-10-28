#!/usr/bin/env python3
"""Fixture-only newsletter report contract.

Keep shared fixtures and cross-metric invariants together in this contract suite.
"""
import copy
import json
from pathlib import Path
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).resolve().parent / "newsletter"))
from metrics import compute
from local_sources import iso

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def stamp(hours=0):
    return iso(NOW + timedelta(hours=hours))


def ticket(number, state="open", reason=None, **extra):
    return {"number": number, "state": state, "state_reason": reason, "lane": "feature:mail",
            "paused": False, "mobile": False, "closed_at": stamp(-1) if state == "closed" else None, **extra}


def merge(number, hours=-1, **extra):
    row = {"number": number, "merged_at": stamp(hours), "merge_sha": str(number),
           "class": "feature", "mobile": False, "closing_issue": number, **extra}
    row.setdefault("issue_labels", ["feature:mail"] if row["class"] == "feature" else [])
    row.setdefault("issue_title", "Work")
    return row


def snapshot(hours=0):
    return {"repo": "owner/repo", "captured_at": stamp(hours), "window_end": stamp(hours),
            "window_start": stamp(hours - 24), "sources": {}, "program": {"tickets": []},
            "merges": [], "running_build": {}, "allocation": {"units": None, "agent_hours": None},
            "meta": [], "executor_actions": []}


def value(node):
    return node["value"]


class MetricsTest(unittest.TestCase):
    def test_missing_baseline_has_no_numeric_delta_or_trend(self):
        today = snapshot()
        today["merges"] = [merge(1), merge(2, -25)]
        today["allocation"]["units"] = {"running": {"feature": 2, "tooling": 1}}
        report = compute(today, None)
        def check(node, path=""):
            if isinstance(node, dict):
                for key, child in node.items():
                    if "delta" in key or "trend" in key:
                        def leaves(item):
                            if isinstance(item, dict) and "value" not in item:
                                for sub in item.values():
                                    yield from leaves(sub)
                            else:
                                yield item
                        for leaf in leaves(child):
                            self.assertEqual(value(leaf), "unavailable", path + key)
                    check(child, path + key + ".")
        check(report)
        self.assertEqual(value(report["program"]["scope"]["completions"]), "unavailable")
        self.assertEqual(value(report["allocation"]["instant_context"]["agent_hours"]), "unavailable")
        self.assertEqual(value(report["outcomes"]["finished_verified"]), "unavailable")
        self.assertEqual(value(report["outcomes"]["live"]), "unavailable")

    def test_machine_duplicates_count_once_and_windows_do_not_overlap(self):
        today = snapshot()
        today["program"]["tickets"] = [ticket(1, machine="pc"), ticket(1, machine="nuc")]
        today["merges"] = [merge(1, machine="pc"), merge(1, machine="nuc"), merge(2, -24), merge(3, -48)]
        report = compute(today, snapshot(-24))
        self.assertEqual(value(report["program"]["total"]), 1)
        self.assertEqual(value(report["outcomes"]["merged"]), 1)
        self.assertEqual(value(report["outcomes"]["prior_merged"]), 1)
        self.assertEqual(value(report["outcomes"]["delta"]), 0)

    def test_scope_changes_are_separate_from_completions(self):
        today, yesterday = snapshot(), snapshot(-24)
        yesterday["program"]["tickets"] = [ticket(1), ticket(2), ticket(3, "closed", "COMPLETED"), ticket(4), ticket(5)]
        today["program"]["tickets"] = [ticket(3), ticket(4, "closed", "COMPLETED"), ticket(5, "closed", "NOT_PLANNED")]
        today["program"]["tickets"] += [ticket(n, "closed", "COMPLETED") if n == 10 else ticket(n)
                                         for n in range(10, 20)]
        report = compute(today, yesterday)["program"]
        self.assertEqual(value(report["total"]), 12)
        scope = report["scope"]
        self.assertEqual({k: value(scope[k]) for k in ("added", "removed", "reopened", "completions")},
                         {"added": 10, "removed": 3, "reopened": 1, "completions": 1})
        today["program"]["tickets"].append(ticket(20, "closed", "NOT_PLANNED"))
        report = compute(today, yesterday)["program"]
        self.assertEqual(value(report["total"]), 12)
        self.assertEqual([value(report["scope"][k]) for k in ("added", "removed")], [11, 4])
        today["program"]["tickets"] = [ticket(3), ticket(4), ticket(5)] + [ticket(n) for n in range(10, 20)]
        scope = compute(today, yesterday)["program"]["scope"]
        self.assertEqual([value(scope[k]) for k in ("added", "removed", "completions")], [10, 2, 0])

    def test_live_requires_ancestry_and_complete_negative_evidence(self):
        today = snapshot()
        today["merges"] = [merge(1), merge(2), merge(3)]
        today["running_build"] = {"pc": {"sha": "2", "ancestor_shas": ["1"]}}
        report = compute(today)["outcomes"]
        self.assertEqual(value(report["merged"]), 3)
        self.assertEqual(value(report["live"]), 2)
        del today["running_build"]["pc"]["ancestor_shas"]
        self.assertEqual(value(compute(today)["outcomes"]["live"]), "unavailable")
        today["sources"]["running_build_pc"] = {"state": "stale"}
        self.assertEqual(value(compute(today)["outcomes"]["live"]), "unavailable")

    def test_feature_share_and_allocation_are_separate(self):
        today, yesterday = snapshot(), snapshot(-24)
        today["merges"] = [merge(1), merge(2, mobile=True), merge(3, **{"class": "test_ci"}),
                            merge(4, -25, **{"class": "other"})]
        today["allocation"] = {"units": {"running": {"feature": 3, "tooling": 1}, "waiting": {"test_ci": 2}},
                               "agent_hours": {"feature": 7.5, "tooling": 2.5}}
        yesterday["allocation"]["units"] = {"running": {"feature": 1, "tooling": 1}}
        report = compute(today, yesterday)
        share = report["outcomes"]["feature_share"]
        self.assertAlmostEqual(value(share["percent"]), 200 / 3)
        self.assertAlmostEqual(value(share["trend_pp"]), 200 / 3)
        self.assertEqual(value(share["mobile_watch_feature"]), 1)
        self.assertEqual(value(share["without_mobile_watch_percent"]), 50)
        self.assertEqual(value(report["allocation"]["instant_context"]["feature_percent"]), 75)
        self.assertEqual(value(report["allocation"]["instant_context"]["trend_pp"]), 25)
        self.assertEqual(value(report["allocation"]["instant_context"]["held_slots"]["waiting"]["test_ci"]), 2)
        self.assertEqual(value(report["allocation"]["instant_context"]["agent_hours"]["feature"]), 7.5)
        today["sources"]["allocation"] = {"state": "stale"}
        self.assertEqual(value(compute(today, yesterday)["allocation"]["instant_context"]["running_agents"]), "unavailable")

    def test_verified_and_finished_lane_require_real_evidence(self):
        today, yesterday = snapshot(), snapshot(-24)
        today["program"]["tickets"] = [ticket(1, "closed", "COMPLETED")]
        yesterday["program"]["tickets"] = [ticket(1)]
        today["merges"] = [merge(1)]
        today["running_build"] = {"pc": {"sha": "1", "ancestor_shas": []}}
        today["features"] = [{"id": "mail", "members": [1], "merges_complete": True}]
        today["verification"] = [{"feature": "mail", "executor": "operator", "verified_at": stamp(-0.5)}]
        report = compute(today, yesterday)
        self.assertEqual(value(report["outcomes"]["finished_verified"]), 1)
        self.assertIs(value(report["program"]["lanes"]["feature:mail"]["finished"]), True)
        today["program"]["tickets"][0]["closed_at"] = stamp(-30)
        yesterday["program"]["tickets"] = [ticket(1, "closed", "COMPLETED", closed_at=stamp(-30)), ticket(2)]
        today["program"]["tickets"].append(ticket(2, "closed", "NOT_PLANNED"))
        lane = compute(today, yesterday)["program"]["lanes"]["feature:mail"]
        self.assertIs(value(lane["finished"]), True)
        self.assertEqual(value(lane["done_in_window"]), 0)
        today["sources"]["github_merges"] = {"state": "stale"}
        self.assertEqual(value(compute(today)["outcomes"]["finished_verified"]), "unavailable")
        today["sources"] = {}
        today["verification"] = []
        self.assertEqual(value(compute(today, yesterday)["outcomes"]["finished_verified"]), 0)
        today["features"][0]["merges_complete"] = False
        self.assertEqual(value(compute(today)["outcomes"]["finished_verified"]), "unavailable")

    def test_meta_patterns_actions_results_and_empty_window(self):
        today = snapshot()
        today["meta"] = [{"id": "a", "timestamp": stamp(-3), "theme": "review", "bottleneck": "Review backlog"},
                         {"id": "b", "timestamp": stamp(-2), "theme": "review", "bottleneck": "Still waiting"}]
        today["executor_actions"] = [{"id": "act", "at": stamp(-1), "outcome": "action", "bottleneck_id": "a"}]
        report = compute(today)
        self.assertEqual(value(report["meta_patterns"]["themes"]["review"]), 2)
        self.assertEqual(report["bottlenecks"][1]["actions"], "no action recorded")
        self.assertEqual(report["actions"][0]["result"], "impact not measured")
        today["measures"] = [{"action_id": "act", "at": stamp(-0.5), "result": "queue cleared"}]
        self.assertEqual(compute(today)["actions"][0]["result"][0]["result"], "queue cleared")
        today["executor_actions"] = None
        self.assertEqual(compute(today)["bottlenecks"][0]["actions"], "unavailable")
        today["meta"] = [{"timestamp": stamp(-25), "bottleneck": "old"}]
        report = compute(today)["meta_patterns"]
        self.assertEqual(report["status"], "no logs in window")
        self.assertEqual(report["newest_log_at"], stamp(-25))
        today["meta"] = []
        today["meta_latest_at"] = None
        self.assertEqual(compute(today)["meta_patterns"]["newest_log_at"], "unavailable")

    def test_unavailable_sources_provenance_json_and_purity(self):
        today = snapshot()
        today["merges"] = None
        today["program"]["tickets"] = None
        today["meta"] = None
        before = copy.deepcopy(today)
        report = compute(today)
        self.assertEqual(today, before)
        self.assertEqual(value(report["outcomes"]["merged"]), "unavailable")
        self.assertEqual(value(report["program"]["total"]), "unavailable")
        self.assertEqual(report["meta_patterns"]["status"], "unavailable")
        def trace(node):
            if isinstance(node, dict):
                if "value" in node:
                    self.assertTrue(node["sources"])
                    return
                for child in node.values():
                    trace(child)
            elif isinstance(node, list):
                for child in node:
                    trace(child)
            else:
                self.assertNotIsInstance(node, (int, float))
        trace(compute(snapshot(), snapshot(-24)))
        json.dumps(report, allow_nan=False)

    def test_bad_baselines_and_conflicting_duplicates_fail_loudly(self):
        with self.assertRaisesRegex(ValueError, "previous UTC date"):
            compute(snapshot(), snapshot(-48))
        other = snapshot(-24)
        other["repo"] = "other/repo"
        with self.assertRaisesRegex(ValueError, "same repository"):
            compute(snapshot(), other)
        today = snapshot()
        today["merges"] = [merge(1), merge(1, **{"class": "other"})]
        with self.assertRaisesRegex(ValueError, "conflicting observations"):
            compute(today)


if __name__ == "__main__":
    unittest.main(verbosity=2)
