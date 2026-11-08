"""Planner icon catalogue and repository epic-config tests."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from heroicon_names import OUTLINE_NAMES
from validation_icons import configured_epics


class IconTests(unittest.TestCase):
    def test_pinned_outline_names_match_vendored_heroicons(self) -> None:
        repository = Path(__file__).resolve().parents[5]
        outline = repository / "src/deps/heroicons/optimized/24/outline"
        if not outline.is_dir():
            self.skipTest(f"vendored Heroicons pack is unavailable at {outline}")

        actual = {path.stem for path in outline.glob("*.svg")}
        self.assertEqual(len(OUTLINE_NAMES), 324)
        self.assertEqual(OUTLINE_NAMES, actual)

    def test_configured_epics_parse_the_github_codex_flow_style_example(self) -> None:
        repository = Path(__file__).resolve().parents[5]
        example = repository / "src/examples/workflows/github-codex.yaml"
        lines = example.read_text(encoding="utf-8").splitlines()
        header = next(index for index, line in enumerate(lines) if line.strip() == "# general_epics:")
        config = "\n".join(line[line.index("#") + 1 :] for line in lines[header : header + 5])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / ".aiur/config"
            target.parent.mkdir()
            target.write_text(config, encoding="utf-8")

            self.assertEqual(
                configured_epics(root),
                [
                    {"key": "bugs", "labels": ["bug"], "icon": "bug"},
                    {"key": "design", "labels": ["design"], "icon": "pen"},
                    {"key": "infra", "labels": ["refactor", "chore"], "icon": "server"},
                    {"key": "docs", "labels": ["documentation"], "icon": "docs"},
                ],
            )

    def test_configured_epics_parse_block_style_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / ".aiur/config"
            target.parent.mkdir()
            target.write_text(
                "build_order:\n"
                "  general_epics:\n"
                "    - key: bugs\n"
                "      labels: [bug, defect]\n"
                "      icon: bug-ant\n"
                "    - key: docs\n"
                "      labels: [documentation]\n"
                "      icon: book-open\n",
                encoding="utf-8",
            )

            parsed = configured_epics(root)
            self.assertEqual([epic["key"] for epic in parsed], ["bugs", "docs"])
            self.assertEqual(parsed[0]["labels"], ["bug", "defect"])
            self.assertEqual(parsed[1]["icon"], "book-open")


if __name__ == "__main__":
    unittest.main()
