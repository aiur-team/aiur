"""Fail-closed bounds for Git reads that carry publication authority."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from helpers import SCRIPT_DIR  # installs the scripts import path
from validation_common import Report
from validation_publication_authority import (
    GIT_AUTHORITY_TIMEOUT_SECONDS,
    _git,
    load_frozen_publication_authority,
)


class PublicationAuthorityIoTests(unittest.TestCase):
    def test_git_reads_have_a_finite_timeout(self) -> None:
        completed = subprocess.CompletedProcess(["git"], 0, "a" * 40 + "\n", "")
        with patch(
            "validation_publication_authority.subprocess.run",
            return_value=completed,
        ) as run:
            self.assertEqual(0, _git(Path("."), "rev-parse", "HEAD").returncode)
        self.assertEqual(
            GIT_AUTHORITY_TIMEOUT_SECONDS,
            run.call_args.kwargs["timeout"],
        )

    def test_timeout_and_os_error_fail_closed(self) -> None:
        for failure in (
            subprocess.TimeoutExpired(["git"], GIT_AUTHORITY_TIMEOUT_SECONDS),
            OSError("missing git"),
        ):
            with self.subTest(failure=type(failure).__name__):
                report = Report()
                with patch(
                    "validation_publication_authority.subprocess.run",
                    side_effect=failure,
                ):
                    authority = load_frozen_publication_authority(
                        Path("."), "pack/publication.json", "a" * 40,
                        "b" * 40, report,
                    )
                self.assertIsNone(authority)
                self.assertIn(
                    "approved_planning_commit must resolve to an exact commit",
                    report.errors,
                )


if __name__ == "__main__":
    unittest.main()
