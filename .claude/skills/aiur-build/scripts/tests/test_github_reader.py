"""Bounded GitHub API reader tests."""

import json
import os
import subprocess
from pathlib import Path
from unittest.mock import patch

from live_receipt_helpers import REPOSITORY
from validation_github_api import GITHUB_API_VERSION, GITHUB_TIMEOUT_SECONDS
from validation_github_live import GhApiReader, LiveGitHubError
from validation_github_reader import QueryBudget


class GhApiReaderTests(__import__("unittest").TestCase):
    def result(self, payload: str) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(["gh"], 0, payload, "")

    def test_paged_queries_reject_malformed_items_and_overflow(self) -> None:
        reader = GhApiReader(Path("."))
        with patch(
            "validation_github_api.subprocess.run",
            return_value=self.result("[1]"),
        ):
            with self.assertRaisesRegex(LiveGitHubError, "malformed item"):
                reader.repository_issues(REPOSITORY)
        with (
            patch("validation_github_reader.MAX_ITEMS", 1),
            patch(
                "validation_github_api.subprocess.run",
                return_value=self.result("[{},{}]"),
            ),
        ):
            with self.assertRaisesRegex(LiveGitHubError, "item verification bound"):
                reader.repository_issues(REPOSITORY)

    def test_explicit_paging_stops_after_first_short_page(self) -> None:
        full_page = [{} for _ in range(100)]
        reader = GhApiReader(Path("."))
        with patch(
            "validation_github_api.subprocess.run",
            side_effect=(self.result(json.dumps(full_page)), self.result("[]")),
        ) as run:
            self.assertEqual(full_page, reader.repository_issues(REPOSITORY))
        self.assertEqual(2, run.call_count)
        endpoints = [call.args[0][-1] for call in run.call_args_list]
        self.assertTrue(endpoints[0].endswith("page=1"))
        self.assertTrue(endpoints[1].endswith("page=2"))

    def test_page_ceiling_never_requests_an_unbounded_next_page(self) -> None:
        reader = GhApiReader(Path("."))
        page = self.result("[{},{}]")
        with (
            patch("validation_github_reader.PAGE_SIZE", 2),
            patch("validation_github_reader.MAX_PAGES", 2),
            patch("validation_github_reader.MAX_ITEMS", 4),
            patch(
                "validation_github_api.subprocess.run",
                side_effect=(page, page),
            ) as run,
        ):
            with self.assertRaisesRegex(LiveGitHubError, "page verification ceiling"):
                reader.repository_issues(REPOSITORY)
        self.assertEqual(2, run.call_count)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(commands[-1][-1].endswith("page=2"))
        self.assertFalse(any("--paginate" in command for command in commands))
        self.assertFalse(any("--slurp" in command for command in commands))

    def test_queries_pin_host_version_method_and_timeout(self) -> None:
        reader = GhApiReader(Path("."))
        with (
            patch.dict(os.environ, {"GH_HOST": "attacker.example"}),
            patch(
                "validation_github_api.subprocess.run",
                return_value=self.result("[]"),
            ) as run,
        ):
            self.assertEqual([], reader.repository_issues(REPOSITORY))
        arguments = run.call_args.args[0]
        self.assertIn(f"X-GitHub-Api-Version: {GITHUB_API_VERSION}", arguments)
        self.assertEqual(
            ["--hostname", "github.com"],
            arguments[arguments.index("--hostname"):arguments.index("--hostname") + 2],
        )
        self.assertEqual(
            ["--method", "GET"],
            arguments[arguments.index("--method"):arguments.index("--method") + 2],
        )
        self.assertEqual(GITHUB_TIMEOUT_SECONDS, run.call_args.kwargs["timeout"])

    def test_one_budget_is_shared_across_sequential_snapshot_reads(self) -> None:
        reader = GhApiReader(Path("."), budget=QueryBudget(
            requests_remaining=1, items_remaining=10,
        ))
        with patch(
            "validation_github_api.subprocess.run",
            return_value=self.result("[]"),
        ):
            self.assertEqual([], reader.repository_issues(REPOSITORY))
            with self.assertRaisesRegex(LiveGitHubError, "total request bound"):
                reader.repository_issues(REPOSITORY)

    def test_query_timeout_and_os_error_fail_closed(self) -> None:
        reader = GhApiReader(Path("."))
        for failure in (
            subprocess.TimeoutExpired(["gh"], GITHUB_TIMEOUT_SECONDS),
            OSError("missing gh"),
        ):
            with self.subTest(failure=type(failure).__name__):
                with patch(
                    "validation_github_api.subprocess.run", side_effect=failure,
                ):
                    with self.assertRaisesRegex(LiveGitHubError, "GitHub query failed"):
                        reader.repository_issues(REPOSITORY)

if __name__ == "__main__":
    import unittest

    unittest.main()
