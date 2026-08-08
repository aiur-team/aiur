"""Tests for input discovery and state-node path resolution."""

import json
import tempfile
import unittest
from pathlib import Path

from analytics import sources

FIXTURES = Path(__file__).parent / "fixtures"
SESSION_A = FIXTURES / "session-a" / "telemetry.ndjson"


class DiscoveryTest(unittest.TestCase):
    def test_directory_input_finds_telemetry_recursively(self):
        files = sources.discover_telemetry_files([str(FIXTURES)])
        names = [path.name for path in files]
        self.assertIn("telemetry.ndjson", names)
        self.assertGreaterEqual(len(files), 2)

    def test_file_input_used_directly(self):
        files = sources.discover_telemetry_files([str(SESSION_A)])
        self.assertEqual(files, [SESSION_A.resolve()])

    def test_missing_input_yields_nothing(self):
        files = sources.discover_telemetry_files(["/nonexistent/path"])
        self.assertEqual(files, [])

    def test_empty_input_searches_default_logs_root(self):
        # Discovery over the (empty) default root must not crash.
        files = sources.discover_telemetry_files([])
        self.assertIsInstance(files, list)


class StateNodeTest(unittest.TestCase):
    def test_explicit_state_node_wins(self):
        root = sources.state_node_root(None, "/tmp/foo")
        self.assertEqual(str(root), "/tmp/foo")

    def test_repo_derives_state_node(self):
        root = sources.state_node_root("aiur-team/aiur")
        self.assertTrue(str(root).endswith("aiur-team/aiur"))

    def test_analytics_and_builds_layout(self):
        node = Path("/tmp/node")
        self.assertEqual(sources.analytics_root(node), node / "analytics")
        self.assertEqual(sources.runs_dir(node), node / "analytics" / "runs")
        self.assertEqual(sources.builds_dir(node), node / "builds")
        self.assertEqual(sources.run_summary_path(node, "boot-1"), node / "analytics" / "runs" / "boot-1" / "run-summary.json")
        self.assertEqual(sources.build_summary_path(node, "slug"), node / "builds" / "slug" / "build-summary.json")

    def test_safe_segment_sanitizes(self):
        self.assertEqual(sources._safe_segment("boot-1"), "boot-1")
        self.assertEqual(sources._safe_segment("../evil"), ".._evil")


class BuildOrderDiscoveryTest(unittest.TestCase):
    def test_find_build_order_from_state_node(self):
        with tempfile.TemporaryDirectory() as tmp:
            node = Path(tmp)
            pack_dir = node / "builds" / "test-build"
            pack_dir.mkdir(parents=True)
            (pack_dir / "build-order.json").write_text(json.dumps({"build_order_id": "x"}))

            found = sources.find_build_order(node, "test-build")
            self.assertIsNotNone(found)
            self.assertEqual(found.parent, pack_dir)

    def test_find_build_order_from_repo_packs(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            packs = repo / "src" / "priv" / "build_orders"
            packs.mkdir(parents=True)
            (packs / "analytics-optimizations.json").write_text("{}")

            found = sources.find_build_order(Path(tmp) / "node", "analytics-optimizations", repo_root=repo)
            self.assertIsNotNone(found)
            self.assertEqual(found.name, "analytics-optimizations.json")


if __name__ == "__main__":
    unittest.main()
