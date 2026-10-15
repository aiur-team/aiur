"""Optimistic work is reported as evidence, without claiming time saved."""

import contextlib
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path

from analytics import build_report, reduce as reducer, render, render_build
from analytics.optimistic import optimistic_rollup, ticket_optimistic

FIXTURE = Path(__file__).parent / "fixtures" / "optimistic"


class OptimisticTest(unittest.TestCase):
    def setUp(self):
        self.dataset = reducer.reduce_files([FIXTURE / "telemetry.ndjson"])
        order = json.loads((FIXTURE / "build-order.json").read_text())
        self.summary = reducer._rollup_build(self.dataset, order, {"1", "2", "3"}, {"now": "fixed"})

    def test_fixture_reduces_merged_redone_and_discarded(self):
        tickets = self.summary["tickets"]
        self.assertEqual(tickets["1"]["optimistic"], {
            "start_trigger": "pr_opened", "blockers": ["9"], "pushes_absorbed": 1,
            "integrations": {"clean": 1, "conflict": 0, "unknown": 0}, "non_ff": 0,
            "parks": 0, "resumes": 0, "outcome": "merged", "head_start_ms": 10000, "waste_ms": None,
        })
        self.assertEqual(tickets["2"]["optimistic"], {
            "start_trigger": "pr_ci_green", "blockers": ["9"], "pushes_absorbed": 1,
            "integrations": {"clean": 0, "conflict": 1, "unknown": 0}, "non_ff": 1,
            "parks": 1, "resumes": 1, "outcome": "merged_after_redo", "head_start_ms": 5000, "waste_ms": None,
        })
        self.assertEqual(tickets["3"]["optimistic"], {
            "start_trigger": "pr_opened", "blockers": ["9"], "pushes_absorbed": 1,
            "integrations": {"clean": None, "conflict": None, "unknown": 1}, "non_ff": None,
            "parks": 1, "resumes": 0, "outcome": "discarded", "head_start_ms": None, "waste_ms": 18000,
        })
        self.assertEqual(reducer.boot_summary(self.dataset, "optimistic-boot")["tickets"]["3"]["optimistic"],
                         tickets["3"]["optimistic"])

    def test_build_report_text_and_cli_json_group_by_trigger(self):
        grouped = optimistic_rollup(self.summary)
        self.assertEqual(grouped["pr_ci_green"], {
            "starts": 1, "merged": 0, "redone": 1, "discarded": 0, "unknown": 0, "discard_rate": 0.0,
            "head_start_ms": 5000, "waste_ms": 0, "head_start_unknown": 0, "waste_unknown": 0,
            "integrations": {"clean": 0, "conflict": 1, "unknown": 0},
        })
        self.assertEqual(grouped["pr_opened"]["starts"], 2)
        self.assertEqual(grouped["pr_opened"]["discarded"], 1)
        self.assertEqual(grouped["pr_opened"]["discard_rate"], 0.5)
        self.assertEqual(grouped["pr_opened"]["head_start_ms"], 10000)
        self.assertEqual(grouped["pr_opened"]["waste_ms"], 18000)
        self.assertEqual(grouped["pr_opened"]["integrations"], {"clean": 1, "conflict": 0, "unknown": 1})
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            reducer.build_summary_for(root, self.dataset, "fixture", json.loads((FIXTURE / "build-order.json").read_text()))
            (root / "builds" / "fixture" / "build-order.json").write_bytes((FIXTURE / "build-order.json").read_bytes())
            for cached in (True, False):
                if not cached:
                    (root / "builds" / "fixture" / "build-summary.json").unlink()
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    result = build_report.main(["fixture", "--state-node", temp, "--telemetry", str(FIXTURE), "--json"])
                self.assertEqual(result, 0)
                payload = json.loads(output.getvalue())
                self.assertEqual(payload["optimistic"], grouped)
                reported = {row["ticket"]: row["optimistic"] for row in payload["report"]}
                self.assertEqual(reported, {key: ticket["optimistic"] for key, ticket in self.summary["tickets"].items()})
        text = render_build.render_build_report(self.summary, "fixture")
        self.assertIn("pr_ci_green: starts 1, merged 0, redone 1, discarded 0", text)
        self.assertIn("pr_opened: starts 2, merged 1, redone 0, discarded 1", text)
        self.assertIn("head start 10000ms, waste 18000ms", text)
        self.assertIn("Integration reports: clean 1, conflict 0, unknown 1", text)
        self.assertIn("Discard rate: 50.0%", text)
        self.assertIn("Optimistic starts: 3 (redone 1, discarded 1; head start 15000ms)",
                      render.render_run_summary(self.summary))
        self.assertEqual(render.run_summary_kpis(self.summary, 10)["optimistic"], grouped)

    def test_missing_evidence_remains_unknown_and_head_start_is_floored(self):
        ticket = copy.deepcopy(self.dataset["tickets"]["1"])
        events = [event for event in ticket["events"] if event["event"] not in ("blocker_push", "blocker_integrate", "optimistic_outcome")]
        evidence = ticket_optimistic(events, ticket["intervals"])["optimistic"]
        self.assertEqual(evidence["outcome"], "open")
        self.assertEqual(evidence["integrations"], {"clean": None, "conflict": None, "unknown": None})
        self.assertIsNone(evidence["non_ff"])
        open_summary = {"tickets": {"1": {"optimistic": evidence}}}
        self.assertIsNone(optimistic_rollup(open_summary)["pr_opened"]["discard_rate"])
        self.assertIn("Discard rate: unavailable", render_build.render_build_report(open_summary, "open"))
        ticket["events"][-2]["head_start_ms"] = -10
        self.assertEqual(ticket_optimistic(ticket["events"], ticket["intervals"])["optimistic"]["head_start_ms"], 0)

    def test_unreported_pushes_are_correlated_by_blocker_and_sha_not_counts(self):
        ticket = copy.deepcopy(self.dataset["tickets"]["1"])
        report = next(event for event in ticket["events"] if event["event"] == "blocker_integrate")
        original_source = report["source_id"]
        for blocker, source in [("other", "integration:other:" + "a" * 40),
                                ("9", "integration:9:" + "b" * 40), ("9", None)]:
            report.update(blocker=blocker, source_id=source)
            evidence = ticket_optimistic(ticket["events"], ticket["intervals"])["optimistic"]
            self.assertEqual(evidence["integrations"], {"clean": 1, "conflict": 0, "unknown": 1})
            self.assertIsNone(evidence["non_ff"])
        report.update(blocker="9", source_id=original_source, attempt_id="another-attempt")
        self.assertEqual(ticket_optimistic(ticket["events"], ticket["intervals"])["optimistic"]["integrations"]["unknown"], 1)
        report["attempt_id"] = "a1"
        push = next(event for event in ticket["events"] if event["event"] == "blocker_push")
        push["source_id"] = None
        self.assertEqual(ticket_optimistic(ticket["events"], ticket["intervals"])["optimistic"]["integrations"]["unknown"], 1)

    def test_discarded_waste_clips_each_attempt_and_preserves_missing_evidence(self):
        events = [
            {"event": "optimistic_start", "attempt_id": "a", "timestamp_ms": 10, "start_trigger": "pr_opened"},
            {"event": "optimistic_park", "attempt_id": "a", "timestamp_ms": 30},
            {"event": "optimistic_start", "attempt_id": "b", "timestamp_ms": 40, "start_trigger": "pr_opened"},
            {"event": "optimistic_park", "attempt_id": "b", "timestamp_ms": 60},
            {"event": "optimistic_outcome", "outcome": "discarded"},
        ]
        intervals = [
            {"phase": "implement", "attempt_id": "a", "start_ms": 0, "end_ms": 5},
            {"phase": "implement", "attempt_id": "a", "start_ms": 5, "end_ms": 20},
            {"phase": "implement", "attempt_id": "a", "start_ms": 25, "end_ms": 35},
            {"phase": "implement", "attempt_id": "b", "start_ms": 45, "end_ms": None},
            {"phase": "implement", "attempt_id": "other", "start_ms": 0, "end_ms": 1000},
        ]
        self.assertEqual(ticket_optimistic(events, intervals)["optimistic"]["waste_ms"], 30)
        self.assertIsNone(ticket_optimistic(events, [])["optimistic"]["waste_ms"])
        self.assertIsNone(ticket_optimistic(events, intervals[:1])["optimistic"]["waste_ms"])
        self.assertIsNone(ticket_optimistic(events, intervals[-1:])["optimistic"]["waste_ms"])
        self.assertIsNone(ticket_optimistic([event for event in events if event["event"] != "optimistic_park"],
                                          intervals)["optimistic"]["waste_ms"])

    def test_legacy_fixture_has_identical_reports_to_committed_goldens(self):
        base = Path(__file__).parent / "fixtures"
        dataset = reducer.reduce_files([base / "session-a" / "telemetry.ndjson", base / "session-b" / "telemetry.ndjson"])
        order = json.loads((base / "build-order.json").read_text())
        summary = reducer._rollup_build(dataset, order, {"930", "931", "999"}, {"now": "fixed"})
        # Normalise provenance path: the baseline came from a separate checkout.
        summary["provenance"]["files"] = ["session-a/telemetry.ndjson", "session-b/telemetry.ndjson"]
        self.assertEqual(render_build.render_build_report(summary, "fixture"), (FIXTURE / "legacy-build.txt").read_text())
        self.assertEqual(render.render_run_summary(summary), (FIXTURE / "legacy-run.txt").read_text())
        self.assertNotIn("optimistic", render.run_summary_kpis(summary, 10))
        self.assertTrue(all("optimistic" not in ticket for ticket in dataset["tickets"].values()))
