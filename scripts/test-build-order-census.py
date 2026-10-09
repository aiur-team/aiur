#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("census", Path(__file__).with_name("build-order-census.py"))
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)


def page(number, count, next_page):
    return json.dumps({"data": {"repository": {"issues": {
        "totalCount": 2, "nodes": [{"number": number, "subIssues": {"totalCount": count}}],
        "pageInfo": {"hasNextPage": next_page, "endCursor": "next"}}}, "rateLimit": {"cost": 1}}})


class CensusTest(unittest.TestCase):
    def test_pages_every_root_and_counts_membership_links(self):
        responses = iter([page(1, 0, True), page(2, 97, False)])
        commands = []

        def run(args, **kwargs):
            commands.append(args)
            return next(responses)

        result = census.census("owner/repo", run)
        self.assertEqual(result["root_count"], 2)
        self.assertEqual(result["membership_links"], 97)
        self.assertEqual(result["median_members"], 48.5)
        self.assertEqual(result["query_points"], 2)
        self.assertIn("cursor=next", commands[1])

    def test_rejects_partial_population(self):
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            census.census("owner/repo", lambda *a, **kw: page(1, 5, False))


if __name__ == "__main__":
    unittest.main()
