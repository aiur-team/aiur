"""CLI and declarative extension tests for authorized publication."""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from publish_build_order import _load_extension, main  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40


class Driver:
    def __init__(self) -> None:
        self.calls: list[object] = []

    def dry_run(self):
        self.calls.append("dry-run")
        return {"mode": "dry-run", "tickets": 3}

    def apply(self):
        self.calls.append("apply")
        return {"mode": "apply-pending", "tickets": 3}

    def finalize(self, receipt_commit, receipt_url):
        self.calls.append((receipt_commit, receipt_url))
        return {"mode": "finalized", "tickets": 3}


class PublishBuildOrderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.pack = Path(self.temp.name)
        self.build = self.pack / "build-order.json"
        self.publication = self.pack / "publication.json"
        self.build.write_text("{}", encoding="utf-8")
        self.publication.write_text("{}", encoding="utf-8")
        self.driver = Driver()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_main(self, *extra: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("publish_build_order.load_driver", return_value=self.driver), (
            contextlib.redirect_stdout(stdout)
        ), contextlib.redirect_stderr(stderr):
            code = main([
                "publish_build_order.py", "--build", str(self.build),
                "--approved-sha", SHA_A, "--green-authority-sha", SHA_B,
                *extra,
            ])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_default_is_dry_run_and_core_accepts_program_independent_counts(self) -> None:
        code, stdout, stderr = self.run_main()
        self.assertEqual((0, ""), (code, stderr))
        self.assertIn('"tickets": 3', stdout)
        self.assertEqual(["dry-run"], self.driver.calls)

    def test_apply_and_finalize_require_explicit_distinct_modes(self) -> None:
        code, _, stderr = self.run_main("--apply")
        self.assertEqual((0, ""), (code, stderr))
        self.assertEqual(["apply"], self.driver.calls)
        self.driver.calls.clear()
        code, _, stderr = self.run_main("--finalize")
        self.assertEqual(1, code)
        self.assertIn("requires --receipt-commit", stderr)
        receipt_url = f"https://github.com/example/repo/commit/{SHA_B}"
        code, _, stderr = self.run_main(
            "--finalize", "--receipt-commit", SHA_B,
            "--receipt-url", receipt_url,
        )
        self.assertEqual((0, ""), (code, stderr))
        self.assertEqual([(SHA_B, receipt_url)], self.driver.calls)

    def test_adapter_is_optional_and_declarative_only(self) -> None:
        self.assertEqual({}, _load_extension(self.pack))
        scripts = self.pack / "scripts"
        scripts.mkdir()
        adapter = scripts / "publication_adapter.py"
        adapter.write_text(
            "AIUR_BUILD_PUBLICATION_ADAPTER_VERSION = 1\n"
            "def publication_extension():\n"
            "    return {'reconciliation_comment': True}\n",
            encoding="utf-8",
        )
        self.assertEqual(
            {"reconciliation_comment": True}, _load_extension(self.pack),
        )
        adapter.write_text(
            "AIUR_BUILD_PUBLICATION_ADAPTER_VERSION = 1\n"
            "def create_publisher(*args):\n    raise AssertionError\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(RuntimeError, "publication_extension"):
            _load_extension(self.pack)

    def test_receipt_arguments_are_rejected_without_finalize(self) -> None:
        code, _, stderr = self.run_main("--receipt-commit", SHA_B)
        self.assertEqual(1, code)
        self.assertIn("accepted only with --finalize", stderr)


if __name__ == "__main__":
    unittest.main()
