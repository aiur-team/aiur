"""Remote GitHub compare publication-authority tests."""

import json
import os
import subprocess
from unittest.mock import patch

from git_authority_helpers import GitAuthorityCase
from validation_common import Report
from validation_github_api import GITHUB_API_VERSION, GITHUB_TIMEOUT_SECONDS
from validation_git_authority import _github_compare_proves_ancestor


class RemoteAuthorityTests(GitAuthorityCase):
    def test_github_compare_is_pinned_bounded_and_strict(self) -> None:
        payload = json.dumps(
            {
                "status": "ahead",
                "ahead_by": 1,
                "behind_by": 0,
                "base_commit": {"sha": self.approved},
                "merge_base_commit": {"sha": self.approved},
            }
        )
        completed = subprocess.CompletedProcess(["gh"], 0, payload, "")
        report = Report()
        with (
            patch.dict(os.environ, {"GH_HOST": "attacker.example"}),
            patch(
                "validation_github_api.subprocess.run",
                return_value=completed,
            ) as run,
        ):
            self.assertTrue(_github_compare_proves_ancestor(
                self.root, "example/repo", self.approved, self.receipt, report,
            ))
        self.assertEqual([], report.errors)
        arguments = run.call_args.args[0]
        self.assertEqual(
            ["--hostname", "github.com"],
            arguments[arguments.index("--hostname"):arguments.index("--hostname") + 2],
        )
        self.assertIn(f"X-GitHub-Api-Version: {GITHUB_API_VERSION}", arguments)
        self.assertEqual(GITHUB_TIMEOUT_SECONDS, run.call_args.kwargs["timeout"])
        self.assertTrue(arguments[-1].endswith(
            f"/compare/{self.approved}...{self.receipt}"
        ))
        for field, value in (
            ("status", "diverged"),
            ("ahead_by", 0),
            ("behind_by", 1),
            ("merge_base_commit", {"sha": self.receipt}),
        ):
            with self.subTest(field=field):
                rejected = json.loads(payload)
                rejected[field] = value
                completed = subprocess.CompletedProcess(
                    ["gh"], 0, json.dumps(rejected), "",
                )
                strict_report = Report()
                with patch(
                    "validation_github_api.subprocess.run",
                    return_value=completed,
                ):
                    self.assertFalse(_github_compare_proves_ancestor(
                        self.root, "example/repo", self.approved, self.receipt,
                        strict_report,
                    ))
                self.assertEqual([], strict_report.errors)

    def test_github_compare_timeout_and_os_error_fail_closed(self) -> None:
        for failure in (
            subprocess.TimeoutExpired(["gh"], GITHUB_TIMEOUT_SECONDS),
            OSError("missing gh"),
        ):
            with self.subTest(failure=type(failure).__name__):
                report = Report()
                with patch(
                    "validation_github_api.subprocess.run", side_effect=failure,
                ):
                    self.assertIsNone(_github_compare_proves_ancestor(
                        self.root, "example/repo", self.approved, self.receipt,
                        report,
                    ))
                self.assertIn("GitHub authority query failed", "\n".join(report.errors))


if __name__ == "__main__":
    import unittest

    unittest.main()
