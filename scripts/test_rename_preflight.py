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
            # Fixture names are chosen so the five test files land in four
            # different shards: an all-in-one-shard fixture would pass even if
            # the shard rule were off by one.
            files = {
                "src/test/a_test.exs": 'assert "old-owner/old-name"\n',
                "src/test/t_test.exs": 'owner: "old-owner"\nrepository: "old-name"\n',
                "src/test/f_test.exs": '"old-owner-old-name"\n',
                "src/test/i_test.exs": '"old-owner/"\n"old-name"\n',
                "src/test/e_test.exs": '"#{owner}/#{name}"\n',
                "src/test/support/helpers.exs": 'owner: "old-owner"\n',
            }
            for relative, contents in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)

            command = [
                sys.executable,
                str(Path(rename_preflight.__file__)),
                "--root",
                str(root),
                "--old",
                "old-owner/old-name",
                "--new",
                "new-owner/new-name",
            ]
            output = subprocess.run(
                command,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout

            self.assertIn("Literal joined-value matches: 1", output)
            self.assertIn("src/test/t_test.exs:1 [partition 2] owner-component", output)
            self.assertIn("src/test/f_test.exs:1 [partition 1] separator-variant", output)
            self.assertIn("src/test/i_test.exs:1 [partition 4] split-across-adjacent-lines", output)
            self.assertIn("src/test/e_test.exs:1 [partition 3] interpolation", output)
            self.assertIn("src/test/support/helpers.exs:1 [all test partitions] owner-component", output)


class ShardOfTest(unittest.TestCase):
    """Locks the shard rule this script shares with `Aiur.TestShard`.

    The values are golden: changing them silently re-shards CI and makes the
    preflight disagree with the coverage jobs it is supposed to describe.
    """

    GOLDEN = {
        "test/a_test.exs": 3,
        "test/e_test.exs": 3,
        "test/f_test.exs": 1,
        "test/i_test.exs": 4,
        "test/t_test.exs": 2,
    }

    def test_matches_golden_values(self):
        for path, expected in self.GOLDEN.items():
            self.assertEqual(rename_preflight.shard_of(path, 4), expected, path)

    def test_is_one_based_and_in_range(self):
        for index in range(500):
            shard = rename_preflight.shard_of(f"test/generated_{index}_test.exs", 4)
            self.assertIn(shard, {1, 2, 3, 4})

    def test_adding_a_file_moves_only_that_file(self):
        existing = [f"test/aiur/f{index}_test.exs" for index in range(300)]
        before = {path: rename_preflight.shard_of(path, 4) for path in existing}
        after = {path: rename_preflight.shard_of(path, 4) for path in existing + ["test/aiur/inserted_test.exs"]}
        moved = [path for path in existing if before[path] != after[path]]
        self.assertEqual(moved, [])


if __name__ == "__main__":
    unittest.main()
