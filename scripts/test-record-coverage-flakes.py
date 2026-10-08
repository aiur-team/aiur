#!/usr/bin/env python3
"""Exercise the actual reporter CLI with failure and rerun logs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoverageFlakesTest(unittest.TestCase):
    def test_same_sha_rerun_records_failure_seed_and_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "test.log"
            env = dict(os.environ, GITHUB_RUN_ID="123", GITHUB_SHA="abc",
                       MIX_TEST_PARTITION="4", GITHUB_RUN_ATTEMPT="1")

            def run(attempt, outcome, output):
                env["GITHUB_RUN_ATTEMPT"] = str(attempt)
                subprocess.run([
                    "python3", str(ROOT / "scripts/record-coverage-flakes.py"),
                    str(log), outcome, str(root / "previous"), str(output),
                    str(root / "summary.md"),
                ], env=env, check=True)
                return [json.loads(line) for line in (output / "flakes.ndjson").read_text().splitlines()]

            log.write_text("Running ExUnit with seed: 42, max_cases: 4\n"
                           "  1) test deferred checkpoint (Aiur.CoreTest)\n"
                           "1 test, 1 failure\nRandomized with seed 42\n")
            self.assertEqual(run(1, "failure", root / "previous/attempt-1"), [])
            log.write_text("Running ExUnit with seed: 99, max_cases: 4\n1 test, 0 failures\n")
            expected = [{"test": "Aiur.CoreTest :: deferred checkpoint", "run_id": "123",
                         "sha": "abc", "shard": "4", "seed": 42, "failed_attempt": 1,
                         "passed_attempt": 2, "passed_seed": 99}]
            self.assertEqual(run(2, "success", root / "passed"), expected)
            self.assertIn("1 failure → rerun-pass", (root / "summary.md").read_text())
            for key, other in (("GITHUB_SHA", "other"), ("GITHUB_RUN_ID", "456"),
                               ("MIX_TEST_PARTITION", "2")):
                original = env[key]
                env[key] = other
                self.assertEqual(run(2, "success", root / "mismatch"), [])
                env[key] = original
            self.assertEqual(run(1, "success", root / "same-attempt"), [])
            self.assertEqual(run(2, "failure", root / "still-red"), [])
            (root / "previous/attempt-2").mkdir()
            (root / "previous/attempt-2/attempt.json").write_text((root / "passed/attempt.json").read_text())
            self.assertEqual(run(3, "success", root / "another-green"), [])
            log.write_text("Compilation stopped before ExUnit ran\n")
            self.assertEqual(run(2, "success", root / "incomplete"), [])

    def test_workflow_preserves_evidence_on_failure_and_rerun(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        shard = workflow.split("  coverage-partition:\n")[1].split("\n  coverage:\n")[0]
        self.assertIn("id: partition-tests", shard)
        self.assertIn("PARTITION_OUTCOME: ${{ steps.partition-tests.outcome }}", shard)
        self.assertIn("pattern: shard-flake-evidence-${{ matrix.partition }}-*", shard)
        self.assertIn("name: shard-flake-evidence-${{ matrix.partition }}-${{ github.run_attempt }}", shard)
        for name in ("Download previous shard attempts", "Record coverage flake ledger", "Upload coverage flake evidence"):
            step = shard.split(f"      - name: {name}\n")[1].split("      - name:")[0]
            self.assertIn("always()", step)
            self.assertIn("needs.changes.outputs.docs_only != 'true'", step)
        self.assertIn("run: python3 scripts/test-record-coverage-flakes.py", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
