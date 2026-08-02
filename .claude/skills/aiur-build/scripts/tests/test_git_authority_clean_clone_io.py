"""Bounded clean-clone publication-authority I/O tests."""

import subprocess
from unittest.mock import patch

from git_authority_helpers import GitAuthorityCase, TRUSTED_REF
from validation_common import Report
from validation_git_bounded import GIT_OUTPUT_LIMIT_RETURN_CODE
from validation_git_remote import (
    GIT_AUTHORITY_TIMEOUT_SECONDS,
    GIT_CLEAN_OUTPUT_BYTES,
    _clean_clone_proves_ancestor,
)


class CleanCloneAuthorityIoTests(GitAuthorityCase):
    def test_clean_clone_proves_order_without_source_graph(self) -> None:
        unrelated_receipt, merged_target = self.unrelated_receipt_and_tip()
        self.git("branch", "-f", "build-order-research", merged_target)
        remote = self.base / "remote.git"
        subprocess.run(
            ["git", "clone", "--bare", "-q", str(self.root), str(remote)],
            check=True, capture_output=True,
        )
        with patch(
            "validation_git_remote._github_clone_url", return_value=str(remote),
        ):
            passing = Report()
            self.assertTrue(_clean_clone_proves_ancestor(
                self.root, "example/repo", TRUSTED_REF,
                self.approved, self.receipt, passing,
            ))
            failing = Report()
            self.assertFalse(_clean_clone_proves_ancestor(
                self.root, "example/repo", TRUSTED_REF,
                self.approved, unrelated_receipt, failing,
            ))
        self.assertEqual([], passing.errors)
        self.assertEqual([], failing.errors)

    def test_fetch_output_limit_fails_closed_with_180_second_bound(self) -> None:
        initialized = subprocess.CompletedProcess(["git"], 0, "", "")
        limited = subprocess.CompletedProcess(
            ["git"], GIT_OUTPUT_LIMIT_RETURN_CODE, "", "output limit",
        )
        report = Report()
        with patch(
            "validation_git_remote.run_bounded_git",
            side_effect=(initialized, limited),
        ) as run:
            self.assertIsNone(_clean_clone_proves_ancestor(
                self.root, "example/repo", TRUSTED_REF,
                self.approved, self.receipt, report,
            ))
        self.assertEqual(2, run.call_count)
        self.assertEqual("init", run.call_args_list[0].args[1])
        self.assertEqual("fetch", run.call_args_list[1].args[1])
        for call in run.call_args_list:
            self.assertEqual(
                GIT_AUTHORITY_TIMEOUT_SECONDS,
                call.kwargs["timeout_seconds"],
            )
            self.assertEqual(GIT_CLEAN_OUTPUT_BYTES, call.kwargs["stdout_limit"])
            self.assertEqual(GIT_CLEAN_OUTPUT_BYTES, call.kwargs["stderr_limit"])
        self.assertIn(
            "cannot fetch trusted branch", "\n".join(report.errors),
        )

    def test_fetch_timeout_and_os_error_fail_closed(self) -> None:
        real_popen = subprocess.Popen
        for failure in (
            subprocess.TimeoutExpired(["git", "fetch"], 180),
            OSError("git unavailable"),
        ):
            with self.subTest(failure=type(failure).__name__):
                def fail_fetch(command, *args, **kwargs):
                    if "fetch" in command:
                        raise failure
                    return real_popen(command, *args, **kwargs)

                report = Report()
                with patch(
                    "validation_git_bounded.subprocess.Popen",
                    side_effect=fail_fetch,
                ):
                    self.assertIsNone(_clean_clone_proves_ancestor(
                        self.root, "example/repo", TRUSTED_REF,
                        self.approved, self.receipt, report,
                    ))
                self.assertIn(
                    "cannot fetch trusted branch", "\n".join(report.errors),
                )


if __name__ == "__main__":
    import unittest

    unittest.main()
