"""Publication title constraints keep logical identity in the body."""

import sys
import json
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_titles import has_logical_id_prefix  # noqa: E402
from publication_context import build_context, feature_epics, product_features, published_feature_slug  # noqa: E402
from publication_client import PublicationError  # noqa: E402
from publication_rendering_sections import _approved_ticket_titles, authority_preamble  # noqa: E402
from publication_common import Report  # noqa: E402
from validation_github_approved import ApprovedIssueExpectations  # noqa: E402


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

    def test_published_epics_reject_default_missing_and_duplicate_icons(self) -> None:
        cases = [
            ([{"id": "runtime", "title": "Runtime", "icon": "squares-2x2"}],
             [{"workstream": "runtime"}]),
            ([{"id": "runtime", "title": "Runtime"}],
             [{"workstream": "runtime"}]),
            *(
                ([{"id": "runtime", "title": "Runtime", "icon": icon}],
                 [{"workstream": "runtime"}])
                for icon in ("", None, 17)
            ),
            ([{"id": "runtime", "title": "Runtime", "icon": "command-line"},
              {"id": "dashboard", "title": "Dashboard", "icon": "command-line"}],
             [{"workstream": "runtime"}, {"workstream": "dashboard"}]),
        ]
        for workstreams, tickets in cases:
            with self.subTest(workstreams=workstreams):
                with self.assertRaises(ValueError):
                    feature_epics({
                        "workstreams": workstreams,
                        "tickets": tickets,
                        "build_order_id": "example/repo:game-maker",
                    })

    def test_rendered_ticket_body_carries_the_plain_plan_id(self) -> None:
        preamble = authority_preamble("example/repo", "OGM-024", 1, "a" * 40)
        self.assertIn("Plan id: OGM-024", preamble)

    def test_approved_ticket_title_matches_plain_manifest_title(self) -> None:
        report = Report()
        titles: dict[str, str] = {}
        manifest_title = "Phaser wrapper"
        with patch("publication_rendering_sections._git_show", return_value=f"# {manifest_title}\n"):
            _approved_ticket_titles(
                titles, Path("."), "a" * 40, PurePosixPath("docs/build-order"),
                {"tickets": [{"id": "OGM-024", "title": manifest_title,
                              "document": "tickets/OGM-024.md"}]},
                "build", report,
            )

        self.assertEqual([], report.errors)
        self.assertEqual({"OGM-024": manifest_title}, titles)

    def test_publication_rejects_manifest_title_with_its_logical_id_prefix(self) -> None:
        from test_publish_build_order_integration import prepare_example_pack

        with tempfile.TemporaryDirectory() as directory:
            build_path, publication_path, build, approved = prepare_example_pack(Path(directory))
            ticket = build["tickets"][0]
            ticket["title"] = f"{ticket['id']} — Prefixed title"
            build_path.write_text(json.dumps(build), encoding="utf-8")
            expected = ApprovedIssueExpectations(
                {}, {ticket["id"]: ticket["title"]}, {},
            )
            with patch("publication_context.render_approved_build_order", return_value=expected):
                with self.assertRaisesRegex(PublicationError, "must not start with a logical ID"):
                    build_context(build_path, publication_path, approved, approved)

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

    def test_feature_cli_runs_the_product_command_resolved_on_path(self) -> None:
        import os

        from publication_operator import Publisher

        publisher = Publisher.__new__(Publisher)
        with (
            patch.dict(os.environ, {"AIUR_FEATURE_CLI": ""}),
            patch("publication_operator.shutil.which", return_value="/usr/local/bin/aiur") as which,
            patch("publication_operator.subprocess.run") as run,
        ):
            run.return_value.returncode = 0
            publisher._run_cli(["feature", "show"], "feature inspection")

        which.assert_called_once_with("aiur")
        self.assertEqual("/usr/local/bin/aiur", run.call_args.args[0][0])
        self.assertEqual(["feature", "show"], run.call_args.args[0][1:])

    def test_feature_cli_override_resolves_an_explicit_product_command(self) -> None:
        import os

        from publication_operator import Publisher

        with (
            patch.dict(os.environ, {"AIUR_FEATURE_CLI": "/custom/bin/aiurdev"}),
            patch("publication_operator.shutil.which", return_value="/custom/bin/aiurdev") as which,
        ):
            self.assertEqual("/custom/bin/aiurdev", Publisher._resolve_cli())

        which.assert_called_once_with("/custom/bin/aiurdev")
