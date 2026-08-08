#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import rename_preflight


class RenamePreflightTest(unittest.TestCase):
    def test_reports_literal_misses_and_mix_partitions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "src/test/a_test.exs": 'assert "old-owner/old-name"\n',
                "src/test/b_test.exs": 'owner: "old-owner"\nrepository: "old-name"\n',
                "src/test/c_test.exs": '"old-owner-old-name"\n',
                "src/test/d_test.exs": '"old-owner/"\n"old-name"\n',
                "src/test/e_test.exs": 'owner = "old-owner"\n"#{owner}/#{name}"\n',
                "src/test/support/helpers.exs": 'owner: "old-owner"\n',
            }
            for relative, contents in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)

            output = subprocess.run(
                [sys.executable, str(Path(rename_preflight.__file__)), "--root", str(root), "--old", "old-owner/old-name", "--new", "new-owner/new-name"],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout

            self.assertIn("Literal joined-value matches: 1", output)
            self.assertIn("src/test/b_test.exs:1 [partition 2] owner-component", output)
            self.assertIn("src/test/c_test.exs:1 [partition 3] separator-variant", output)
            self.assertIn("src/test/d_test.exs:1 [partition 4] split-across-adjacent-lines", output)
            self.assertIn("src/test/e_test.exs:2 [partition 1] interpolation", output)
            self.assertIn("src/test/support/helpers.exs:1 [all test partitions] owner-component", output)


if __name__ == "__main__":
    unittest.main()
