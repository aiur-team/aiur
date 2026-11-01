"""Publication title constraints keep logical identity in the body."""

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_titles import has_logical_id_prefix  # noqa: E402
from publication_context import feature_epics, product_features, published_feature_slug  # noqa: E402


class PublicationTitlesTest(unittest.TestCase):
    def test_rejects_logical_id_prefixes_and_accepts_plain_titles(self) -> None:
        self.assertTrue(has_logical_id_prefix("OGM-024 — Phaser wrapper", "OGM-024"))
        self.assertTrue(has_logical_id_prefix("BO-001 implementation", "BO-001"))
        self.assertFalse(has_logical_id_prefix("Phaser wrapper", "OGM-024"))
        self.assertFalse(has_logical_id_prefix("OGM-0245 tooling", "OGM-024"))

    def test_published_lane_epics_have_unique_non_default_plan_icons(self) -> None:
        epics = feature_epics({
            "workstreams": [
                {"id": "runtime", "title": "Runtime", "icon": "command-line"},
                {"id": "dashboard", "title": "Dashboard", "icon": "window"},
            ],
            "tickets": [
                {"workstream": "runtime"}, {"workstream": "dashboard"},
            ],
            "build_order_id": "example/repo:game-maker",
        })

        icons = [epic["icon"] for epic in epics]
        self.assertEqual(["window", "command-line"], icons)
        self.assertNotIn("squares-2x2", icons)
        self.assertEqual(len(icons), len(set(icons)))

    def test_registration_creates_each_product_group_and_assigns_all_tickets(self) -> None:
        from types import SimpleNamespace
        from unittest.mock import patch

        from publication_operator import Publisher

        publisher = Publisher.__new__(Publisher)
        publisher.context = SimpleNamespace(
            root_id="example/repo:game-maker", repository="example/repo",
            build={
                "workstreams": [
                    {"id": "runtime", "title": "Runtime", "icon": "command-line"},
                    {"id": "ui-lane", "title": "UI", "icon": "window"},
                ],
                "tickets": [
                    {"id": "OGM-024", "workstream": "runtime"},
                    {"id": "OGM-025", "workstream": "ui-lane"},
                ],
                "product_features": [
                    {"slug": "runtime-tools", "label": "Runtime tools", "ticket_ids": ["OGM-024"]},
                    {"slug": "editor-ui", "label": "Editor UI", "ticket_ids": ["OGM-025"]},
                ],
                "build_order_id": "example/repo:game-maker",
            },
        )
        mappings = {"OGM-024": {"number": 41}, "OGM-025": {"number": 42}}
        with patch.object(Publisher, "_run_cli") as run_cli:
            publisher._ensure_feature(mappings)

        calls = run_cli.call_args_list
        self.assertEqual(4, len(calls))
        self.assertEqual("feature", calls[0].args[0][0])
        self.assertEqual(["feature", "create", "game-maker-runtime-tools", "--label", "Runtime tools",
                          "--epic", "f-game-maker-runtime-tools-runtime=Runtime",
                          "--epic-icon", "f-game-maker-runtime-tools-runtime=command-line"], calls[0].args[0])
        self.assertEqual(["feature", "add", "game-maker-runtime-tools", "41", "--epic",
                          "f-game-maker-runtime-tools-runtime"], calls[1].args[0])
        self.assertEqual("game-maker-editor-ui", calls[2].args[0][2])
        self.assertEqual(["feature", "add", "game-maker-editor-ui", "42", "--epic",
                          "f-game-maker-editor-ui-ui-lane"], calls[3].args[0])

    def test_product_feature_groups_cannot_leave_tickets_in_a_catch_all(self) -> None:
        with self.assertRaisesRegex(ValueError, "every ticket exactly once"):
            product_features({
                "tickets": [{"id": "A"}, {"id": "B"}],
                "product_features": [{"slug": "one", "label": "One", "ticket_ids": ["A"]}],
            })

    def test_published_feature_slug_obeys_aiur_limit(self) -> None:
        slug = published_feature_slug("a" * 42, "product-capability")
        self.assertLessEqual(len(slug), 42)
