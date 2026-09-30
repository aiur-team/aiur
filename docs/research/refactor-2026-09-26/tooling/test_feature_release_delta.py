#!/usr/bin/env python3
"""Parser guards for frozen feature citation normalization."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from feature_release_delta import cited_paths  # noqa: E402


class CitationTests(unittest.TestCase):
    def test_braced_paths_include_every_member(self):
        known = {
            "src/lib/aiur/github/cache_inspector/entry.ex",
            "src/lib/aiur/github/cache_inspector/events.ex",
        }
        found, missing = cited_paths(
            ["src/lib/aiur/github/cache_inspector/{entry,events}.ex"], known
        )
        self.assertEqual(found, sorted(known))
        self.assertEqual(missing, [])

    def test_src_relative_paths_and_elixir_arity(self):
        known = {"src/lib/aiur/init.ex"}
        found, missing = cited_paths(["lib/aiur/init.ex; analytics/1"], known)
        self.assertEqual(found, ["src/lib/aiur/init.ex"])
        self.assertEqual(missing, [])

    def test_build_order_pack_shorthand_resolves_four_tracked_files(self):
        known = {
            "src/priv/build_orders/README.md",
            "src/priv/build_orders/aiur-build-order.json",
            "src/priv/build_orders/analytics-optimizations.json",
            "src/priv/build_orders/croptracker-demo.json",
        }
        found, missing = cited_paths(
            ["src/priv/build_orders/{README.md, three demo pack JSON files}"], known
        )
        self.assertEqual(found, sorted(known))
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
