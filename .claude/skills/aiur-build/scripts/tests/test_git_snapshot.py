"""Resource-bound regression tests for receipt-pack materialization."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from helpers import SCRIPT_DIR  # installs the scripts import path
from validation_common import Report
from validation_git_snapshot import (
    MAX_PACK_BYTES,
    MAX_PACK_FILE_BYTES,
    MAX_PACK_FILES,
    _entries,
    materialize_receipt_pack,
)


class ReceiptSnapshotBoundsTests(unittest.TestCase):
    def test_existing_54_ticket_pack_capacity_is_preserved(self) -> None:
        raw = b"\0".join(
            f"100644 blob {'a' * 40}\tpack/tickets/BO-{index:03}.md".encode()
            for index in range(1, 55)
        ) + b"\0"
        result = subprocess.CompletedProcess(["git"], 0, raw, b"")
        report = Report()
        with patch("validation_git_snapshot._git", return_value=result):
            entries = _entries(Path("."), "a" * 40, "pack", report)
        self.assertEqual(54, len(entries or []))
        self.assertEqual([], report.errors)

    def test_tree_entry_count_is_bounded(self) -> None:
        raw = b"\0".join(
            f"100644 blob {'a' * 40}\tpack/{index}.md".encode()
            for index in range(MAX_PACK_FILES + 1)
        ) + b"\0"
        result = subprocess.CompletedProcess(["git"], 0, raw, b"")
        report = Report()
        with patch("validation_git_snapshot._git", return_value=result):
            entries = _entries(Path("."), "a" * 40, "pack", report)
        self.assertEqual(MAX_PACK_FILES, len(entries or []))
        self.assertIn("file-count bound", "\n".join(report.errors))

    def test_oversized_blob_is_rejected_before_write(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "snapshot"
            entries = [("pack/large.md", False)]
            report = Report()
            with (
                patch("validation_git_snapshot._clone", return_value=True),
                patch("validation_git_snapshot._entries", return_value=entries),
                patch(
                    "validation_git_snapshot._blob_size",
                    return_value=MAX_PACK_FILE_BYTES + 1,
                ),
                patch("validation_git_snapshot._write_blob") as write_blob,
            ):
                self.assertFalse(materialize_receipt_pack(
                    Path("."), "a" * 40, "pack", destination, report,
                ))
            joined = "\n".join(report.errors)
            self.assertIn("file exceeds byte bound", joined)
            write_blob.assert_not_called()

    def test_aggregate_blob_bytes_are_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            entries = [(f"pack/{index}.md", False) for index in range(17)]
            report = Report()
            with (
                patch("validation_git_snapshot._clone", return_value=True),
                patch("validation_git_snapshot._entries", return_value=entries),
                patch(
                    "validation_git_snapshot._blob_size",
                    return_value=MAX_PACK_FILE_BYTES,
                ),
                patch("validation_git_snapshot._write_blob", return_value=True) as write,
            ):
                self.assertFalse(materialize_receipt_pack(
                    Path("."), "a" * 40, "pack", Path(directory), report,
                ))
            self.assertIn("aggregate byte bound", "\n".join(report.errors))
            self.assertEqual(MAX_PACK_BYTES // MAX_PACK_FILE_BYTES, write.call_count)


if __name__ == "__main__":
    unittest.main()
