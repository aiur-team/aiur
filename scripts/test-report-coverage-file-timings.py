#!/usr/bin/env python3
"""Test slow-file summaries and the coverage timing capture wiring."""

from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "coverage_file_timing_report", ROOT / "scripts/report-coverage-file-timings.py"
)
REPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORTER)
render_summary = REPORTER.render_summary


class CoverageFileTimingsTest(unittest.TestCase):
    def test_summary_ranks_files_by_summed_test_time_and_marks_partial_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "partition.log"
            timings = root / "timings.tsv"
            log.write_text("coverage-partition: shard 2/4 -> 400 test files\nFinished in 432.7 seconds\n")
            timings.write_text(
                "path\ttests\ttotal_us\tmax_us\n"
                "test/aiur/fast_test.exs\t8\t3000000\t900000\n"
                "test/aiur/slow_test.exs\t3\t9000000\t7000000\n"
            )

            summary = render_summary(2, log, timings)

            self.assertIn("coverage (2/4) shard composition", summary)
            self.assertIn("400 test files", summary)
            self.assertIn("ExUnit suite runtime: 432.7 seconds", summary)
            self.assertLess(summary.index("slow_test.exs"), summary.index("fast_test.exs"))
            self.assertIn("async tests overlap", summary)

    def test_cli_appends_the_partition_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "partition.log"
            timings = root / "timings.tsv"
            summary = root / "step-summary.md"
            log.write_text("Finished in 12.5 seconds\n")
            timings.write_text("path\ttests\ttotal_us\tmax_us\ntest/aiur/one_test.exs\t1\t1000000\t1000000\n")
            summary.write_text("workflow summary\n")

            subprocess.run([
                "python3", str(ROOT / "scripts/report-coverage-file-timings.py"),
                "3", str(log), str(timings), str(summary),
            ], check=True)

            result = summary.read_text()
            self.assertTrue(result.startswith("workflow summary\n"))
            self.assertIn("coverage (3/4) shard composition", result)
            self.assertIn("ExUnit suite runtime: 12.5 seconds", result)

    def test_workflow_keeps_the_bound_and_uploads_timing_data_with_flake_evidence(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        shard = workflow.split("  coverage-partition:\n")[1].split("\n  test:\n")[0]

        partition_script = (ROOT / "scripts/run-coverage-partition.sh").read_text()

        self.assertIn("scripts/run-coverage-partition.sh", shard)
        self.assertIn("--kill-after=60s 20m", partition_script)
        self.assertIn("AIUR_TEST_TIMINGS_PATH=", partition_script)
        self.assertIn("coverage-file-times.tsv", shard)
        self.assertIn("report-coverage-file-timings.py", shard)
        self.assertIn("path: ${{ runner.temp }}/shard-evidence/", shard)

    def test_workflow_security_runs_this_script_test(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("python3 scripts/test-report-coverage-file-timings.py", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
