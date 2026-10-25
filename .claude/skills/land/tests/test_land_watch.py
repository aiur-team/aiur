"""Future regression guards for behavior preserved by the watcher split."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import land_github
import land_watch


class LandWatchTest(unittest.TestCase):
    def test_github_helpers_remain_available_from_entry_module(self):
        self.assertIs(land_watch.PrInfo, land_github.PrInfo)
        self.assertIs(land_watch.get_pr_info, land_github.get_pr_info)
        self.assertIs(land_watch.run_gh, land_github.run_gh)
        self.assertIs(land_watch.RateLimitError, land_github.RateLimitError)

    def test_future_guard_latest_check_run_supersedes_older_failure(self):
        checks = [
            {"name": "lint", "status": "completed", "conclusion": "failure",
             "completed_at": "2026-10-01T01:00:00Z"},
            {"name": "lint", "status": "completed", "conclusion": "success",
             "completed_at": "2026-10-01T02:00:00Z"},
            {"name": "test", "status": "in_progress", "conclusion": None},
        ]
        self.assertEqual(land_watch.summarize_checks(checks), (True, False, []))
        checks[1]["conclusion"] = "failure"
        self.assertEqual(land_watch.summarize_checks(checks),
                         (True, True, ["lint: failure"]))

    def test_future_guard_latest_review_and_codex_request_cutoff(self):
        reviews = [
            {"id": 1, "user": {"login": "owner"}, "state": "CHANGES_REQUESTED",
             "submitted_at": "2026-10-01T01:00:00Z"},
            {"id": 2, "user": {"login": "owner"}, "state": "APPROVED",
             "submitted_at": "2026-10-01T02:00:00Z"},
            {"id": 3, "user": {"login": "github-actions[bot]"},
             "state": "CHANGES_REQUESTED", "submitted_at": "2026-10-01T01:00:00Z"},
            {"id": 4, "user": {"login": "reviewer"}, "state": "CHANGES_REQUESTED",
             "submitted_at": "2026-10-01T02:00:00Z"},
        ]
        request = land_watch.parse_time("2026-10-01T01:30:00Z")
        self.assertEqual(land_watch.filter_blocking_reviews(reviews, request),
                         [reviews[3]])


if __name__ == "__main__":
    unittest.main()
