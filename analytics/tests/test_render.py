"""Tests for report rendering and the build-report aggregation."""

import json
import tempfile
import unittest
from pathlib import Path

from analytics import reduce as reducer
from analytics import render
from analytics import sources

FIXTURES = Path(__file__).parent / "fixtures"
SESSION_A = FIXTURES / "session-a" / "telemetry.ndjson"
SESSION_B = FIXTURES / "session-b" / "telemetry.ndjson"
BUILD_ORDER = FIXTURES / "build-order.json"


def _record(kind, ts, boot, seq, attrs):
    return {
        "schema_version": 2,
        "kind": kind,
        "timestamp": ts,
        "recorded_at": ts,
        "boot_id": boot,
        "sequence": seq,
        "record_id": "%s:%d" % (boot, seq),
        "attributes": attrs,
    }


def _write_busy_stream(path: Path) -> None:
    """Two agents at 100% CPU across ~600 samples (an hour of 5s samples)."""
    lines = [_record("restart", "2026-07-11T00:00:00Z", "boot-x", 1, {"event": "daemon_restart"})]
    seq = 1
    for minute in range(60):
        for agent, ticket in (("ticket:701", "701"), ("ticket:702", "702")):
            ts = "2026-07-11T00:%02d:%02dZ" % (minute, (seq * 3) % 59)
            seq += 1
            lines.append(
                _record(
                    "resource",
                    ts,
                    "boot-x",
                    seq,
                    {
                        "actor": agent,
                        "actor_type": "agent",
                        "ticket": ticket,
                        "availability": "measured",
                        "cpu_percent": 100.0,
                        "rss_bytes": 1000,
                    },
                )
            )
    path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")


def build_rollup():
    dataset = reducer.reduce_files([SESSION_A, SESSION_B])
    build_order = json.loads(BUILD_ORDER.read_text(encoding="utf-8"))
    return reducer._rollup_build(dataset, build_order, {"930", "931", "999"})


class RunSummaryKpisTest(unittest.TestCase):
    def setUp(self):
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])
        self.summary = reducer.boot_summary(dataset, "boot-a")

    def test_headline_numbers(self):
        kpis = render.run_summary_kpis(self.summary, cap=10)
        self.assertEqual(kpis["boot_id"], "boot-a")
        # 930 dispatched (complexity 2) + 931 dispatched (complexity 1).
        self.assertEqual(kpis["dispatched"], 2)
        self.assertEqual(kpis["merged"], 1)
        self.assertEqual(kpis["open"], 1)
        self.assertGreaterEqual(kpis["cpu_hours"], 0)
        self.assertEqual(kpis["peak_concurrency"], 1)
        self.assertEqual(kpis["cap"], 10)
        self.assertGreaterEqual(kpis["wasted_slot_hours"], 0)

    def test_cpu_seconds_and_concurrency_on_a_bigger_stream(self):
        # A stream large enough that CPU-hours and wasted slot-hours survive
        # rounding exercises the real numbers, not just zero-placeholders.
        dataset = reducer.reduce_files([SESSION_A, SESSION_B])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "big.ndjson"
            _write_busy_stream(path)
            big = reducer.reduce_files([path])
            summary = reducer.boot_summary(big, "boot-x")
        kpis = render.run_summary_kpis(summary, cap=2)
        self.assertGreater(kpis["cpu_hours"], 0)
        self.assertGreater(kpis["wasted_slot_hours"], 0)
        self.assertEqual(kpis["peak_concurrency"], 2)

    def test_top_cost_includes_ticket_actors(self):
        kpis = render.run_summary_kpis(self.summary, cap=10)
        labels = [render._actor_label(key) for key, _ in kpis["top_cost"]]
        self.assertIn("#930", labels)

    def test_render_output(self):
        text = render.render_run_summary(self.summary, cap=10)
        self.assertIn("boot-a", text)
        self.assertIn("CPU burned", text)
        self.assertIn("Source files", text)

    def test_fleet_pressure_uses_source_states_independently_of_procfs(self):
        summary = {
            "actors": {
                "_daemon": {
                    "samples": [
                        {
                            "timestamp_ms": 1000,
                            "availability": "unavailable",
                            "fleet_capacity_status": "current",
                            "fleet_agents_occupied": 13,
                            "fleet_agents_effective": 12,
                            "fleet_agents_max": 16,
                            "fleet_agents_configured": 16,
                            "fleet_capacity_observed_at_ms": 900,
                            "fleet_capacity_age_ms": 0,
                            "fleet_admission_signal": "build",
                            "fleet_load": 3.77,
                            "fleet_load_threshold": 24,
                            "fleet_schedulers": 16,
                            "build_gate_status": "measured",
                            "build_gate_capacity": 2,
                            "build_gate_observed_at_ms": 950,
                            "build_gate_active": 2,
                            "build_gate_queued": 8,
                            "build_queue_oldest_wait_seconds": 189,
                        },
                        {
                            "timestamp_ms": 2000,
                            "availability": "measured",
                            "fleet_capacity_status": "stale",
                            "fleet_agents_occupied": 99,
                            "build_gate_status": "degraded",
                            "build_gate_active": 99,
                        },
                    ]
                }
            }
        }

        pressure = render.fleet_pressure(summary)
        self.assertEqual(pressure["peak_occupied"], 13)
        self.assertEqual(pressure["peak_active_builds"], 2)
        self.assertEqual(pressure["peak_queued_builds"], 8)
        self.assertEqual(pressure["longest_wait_seconds"], 189)
        self.assertEqual(pressure["latest_effective_capacity"], 12)
        self.assertEqual(pressure["latest_build_capacity"], 2)
        self.assertEqual(pressure["latest_fleet_observed_at_ms"], 900)
        self.assertEqual(pressure["latest_build_observed_at_ms"], 950)
        # The binding admission signal and host load let an operator tell a
        # build-gate-saturated fleet from a host-saturated one.
        self.assertEqual(pressure["latest_admission_signal"], "build")
        self.assertEqual(pressure["latest_load"], 3.77)
        self.assertEqual(pressure["latest_load_threshold"], 24)
        self.assertFalse(pressure["legacy_fallback"])

        text = render.render_run_summary(summary)
        self.assertIn("capacity 2", text)
        self.assertIn("Binding admission signal: build; load 3.77 / threshold 24", text)
        self.assertIn("fleet 1970-01-01T00:00:00.900000Z (aged 0s old); build 1970-01-01T00:00:00.950000Z", text)

    def test_peak_capacity_range_renders_when_capacity_changed_mid_run(self):
        summary = {
            "actors": {
                "_daemon": {
                    "samples": [
                        {
                            "timestamp_ms": 1000,
                            "fleet_capacity_status": "current",
                            "fleet_agents_occupied": 3,
                            "fleet_capacity_observed_at_ms": 900,
                            "build_gate_status": "measured",
                            "build_gate_capacity": 2,
                            "build_gate_active": 2,
                            "build_gate_queued": 6,
                            "build_gate_observed_at_ms": 950,
                        },
                        {
                            "timestamp_ms": 2000,
                            "fleet_capacity_status": "current",
                            "fleet_agents_occupied": 3,
                            "fleet_capacity_observed_at_ms": 1900,
                            "build_gate_status": "measured",
                            "build_gate_capacity": 4,
                            "build_gate_active": 3,
                            "build_gate_queued": 1,
                            "build_gate_observed_at_ms": 1950,
                        },
                    ]
                }
            }
        }

        pressure = render.fleet_pressure(summary)
        self.assertEqual(pressure["min_build_capacity"], 2)
        self.assertEqual(pressure["max_build_capacity"], 4)
        self.assertEqual(pressure["peak_queued_builds"], 6)
        self.assertEqual(pressure["latest_build_capacity"], 4)

        text = render.render_run_summary(summary)
        # The queued peak (6) occurred under capacity 2; the range makes that
        # visible instead of presenting the latest 4 as the peak's capacity.
        self.assertIn("capacity 2..4 (latest 4)", text)
        self.assertIn("queued 6; capacity 2..4", text)

    def test_missing_peak_concurrency_renders_unavailable_never_zero(self):
        summary = {
            "actors": {
                "_daemon": {
                    "samples": [
                        {
                            "timestamp_ms": 1000,
                            "availability": "measured",
                            "fleet_capacity_status": "current",
                            "fleet_capacity_observed_at_ms": 900,
                            "fleet_agents_configured": 16,
                            "fleet_agents_max": 16,
                            "fleet_agents_effective": 12,
                            "build_gate_status": "unavailable",
                        }
                    ]
                }
            }
        }
        # The exact-fleet path is taken but no numeric occupied was ever
        # recorded, so the peak is unknown. Zero is a legitimate peak ("idle");
        # a missing peak must stay None so the reader can tell the difference.
        kpis = render.run_summary_kpis(summary, cap=10)
        self.assertIsNone(kpis["peak_concurrency"])
        text = render.render_run_summary(summary, cap=10)
        self.assertIn("Peak concurrency: unavailable of 10 cap", text)

    def test_partial_build_with_missing_wait_and_observation_renders_unavailable(self):
        summary = {
            "actors": {
                "_daemon": {
                    "samples": [
                        {
                            "timestamp_ms": 1000,
                            "fleet_capacity_status": "unavailable",
                            "build_gate_status": "partial",
                            "build_gate_capacity": 4,
                            "build_gate_active": 1,
                            "build_gate_queued": 2,
                            "build_queue_oldest_wait_seconds": None,
                            "build_gate_observed_at_ms": None,
                        },
                        {
                            "timestamp_ms": 2000,
                            "fleet_capacity_status": "stale",
                            "build_gate_status": "degraded",
                            "build_gate_capacity": 99,
                            "build_gate_active": 99,
                            "build_gate_queued": 99,
                            "build_queue_oldest_wait_seconds": 99,
                            "build_gate_observed_at_ms": 1999,
                        },
                    ]
                }
            }
        }

        pressure = render.fleet_pressure(summary)
        self.assertEqual(pressure["latest_build_capacity"], 4)
        self.assertEqual(pressure["peak_active_builds"], 1)
        self.assertEqual(pressure["peak_queued_builds"], 2)
        self.assertIsNone(pressure["longest_wait_seconds"])
        self.assertIsNone(pressure["latest_build_observed_at_ms"])

        text = render.render_run_summary(summary)
        self.assertIn("longest live wait: unavailable", text)
        self.assertNotIn("unavailables", text)
        self.assertIn("fleet unavailable (aged unavailable); build unavailable", text)

    def test_legacy_concurrency_fallback_is_explicitly_labelled(self):
        pressure = render.fleet_pressure(self.summary, cap=10)
        self.assertTrue(pressure["legacy_fallback"])
        self.assertIn("CPU-derived legacy fallback", render.render_run_summary(self.summary, cap=10))


class BuildReportTest(unittest.TestCase):
    def test_member_rows(self):
        rollup = build_rollup()
        rows = render.build_report_rows(rollup)
        by_ticket = {row["ticket"]: row for row in rows}

        self.assertEqual(len(rows), 3)

        row_930 = by_ticket["930"]
        self.assertEqual(row_930["status"], "merged")
        self.assertGreater(row_930["wall_clock_ms"], 0)
        self.assertGreater(row_930["active_ms"], 0)
        # 930 has build_test cycles in both boots: one failed, one passed.
        self.assertEqual(row_930["ci_cycles"], 2)
        self.assertEqual(row_930["ci_failed"], 1)
        self.assertEqual(row_930["rework"], 1)
        self.assertGreater(row_930["cpu_seconds"], 0)
        self.assertTrue(row_930["observed"])

        row_931 = by_ticket["931"]
        self.assertEqual(row_931["status"], "active")
        self.assertEqual(row_931["ci_cycles"], 0)
        self.assertTrue(row_931["observed"])

        row_999 = by_ticket["999"]
        self.assertEqual(row_999["status"], "open")
        self.assertFalse(row_999["observed"])
        self.assertEqual(row_999["cpu_seconds"], 0.0)

    def test_backends_collected(self):
        rollup = build_rollup()
        rows = render.build_report_rows(rollup)
        by_ticket = {row["ticket"]: row for row in rows}
        backends = {entry["backend"] for entry in by_ticket["930"]["backends"]}
        self.assertEqual(backends, {"codex", "claude"})

    def test_render_build_report(self):
        rollup = build_rollup()
        text = render.render_build_report(rollup, "test-build")
        self.assertIn("Test build", text)
        self.assertIn("#930", text)
        self.assertIn("Merged: 1/3", text)


class ToolIntegrationTest(unittest.TestCase):
    def test_reduce_and_build_report_roundtrip(self):
        from analytics import build_report, reduce_cmd

        with tempfile.TemporaryDirectory() as tmp:
            state_node = Path(tmp) / "node"
            # Place the build order where the state node expects it
            # (builds/<slug>/build-order.json) — the Executor-placed layout.
            pack_dir = state_node / "builds" / "test-build"
            pack_dir.mkdir(parents=True)
            (pack_dir / "build-order.json").write_bytes(BUILD_ORDER.read_bytes())

            exit_code = reduce_cmd.main(
                [
                    "--telemetry", str(FIXTURES),
                    "--state-node", str(state_node),
                    "--build", "test-build",
                    "--json",
                ]
            )
            self.assertEqual(exit_code, 0)

            run = sources.run_summary_path(state_node, "boot-a")
            self.assertTrue(run.is_file())
            build = sources.build_summary_path(state_node, "test-build")
            self.assertTrue(build.is_file())

            # build-report reads the materialized summary (no raw re-parse path).
            exit_code = build_report.main(
                ["test-build", "--telemetry", str(FIXTURES), "--state-node", str(state_node)]
            )
            self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
