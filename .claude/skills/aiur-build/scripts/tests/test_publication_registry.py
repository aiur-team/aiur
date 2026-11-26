"""Publication registers one epic per pack, its product features and their lanes."""

import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_client import PublicationError  # noqa: E402
from publication_labels import routing_subset  # noqa: E402
from publication_operator import Publisher  # noqa: E402
from publication_registry import ensure_registry  # noqa: E402

ROOT = "example/repo:game-maker"
ROOT_ID = ROOT


def _build() -> dict:
    """A pack with three product features; the first spans two lanes."""
    return {
        "build_order_id": ROOT,
        "workstreams": [
            {"id": "runtime", "title": "Runtime", "icon": "command-line"},
            {"id": "ui", "title": "UI", "icon": "window"},
            {"id": "tooling", "title": "Tooling", "icon": "wrench"},
        ],
        "tickets": [
            {"id": "OGM-024", "workstream": "runtime"},
            {"id": "OGM-025", "workstream": "ui"},
            {"id": "OGM-026", "workstream": "tooling"},
            {"id": "OGM-027", "workstream": "ui"},
        ],
        "product_features": [
            {"slug": "runtime-tools", "label": "Runtime tools", "ticket_ids": ["OGM-024", "OGM-026"]},
            {"slug": "editor-ui", "label": "Editor UI", "ticket_ids": ["OGM-025"]},
            {"slug": "level-editor", "label": "Level editor", "ticket_ids": ["OGM-027"]},
        ],
    }


def _mappings() -> dict[str, dict[str, int]]:
    return {
        ROOT_ID: {"number": 41},
        "OGM-024": {"number": 42},
        "OGM-025": {"number": 43},
        "OGM-026": {"number": 44},
        "OGM-027": {"number": 45},
    }


def _publisher(registry: "FakeRegistry") -> Publisher:
    publisher = Publisher.__new__(Publisher)
    publisher.context = SimpleNamespace(
        root_id=ROOT,
        repository="example/repo",
        build=_build(),
        specs={ROOT_ID: SimpleNamespace(title="Game maker")},
    )
    publisher._run_cli = registry
    return publisher


class FakeRegistry:
    """The `aiur epic` and `aiur feature` commands publication drives.

    It models the documented registry contract: a create whose values match an
    existing record changes nothing, a create whose values differ is refused, a
    label outside 1 to 80 characters is refused, and a membership add of
    already-joined tickets changes nothing.  Only real state changes land in
    `writes`.
    """

    def __init__(self) -> None:
        self.epics: dict[str, dict] = {}
        self.features: dict[str, dict] = {}
        self.calls: list[list[str]] = []
        self.writes: list[list[str]] = []

    def _read(self) -> str:
        return json.dumps({
            "command": "epic list",
            "epics": [
                {"slug": slug, "label": epic["label"], "features": epic["features"]}
                for slug, epic in self.epics.items()
            ],
            "schema_version": 1,
        })

    def __call__(self, arguments: list[str], _label: str) -> str:
        self.calls.append(list(arguments))
        if arguments == ["epic", "list", "--json"]:
            return self._read()
        verb = arguments[0]
        if verb == "epic":
            self._epic(arguments)
        elif verb == "feature":
            self._feature(arguments)
        else:
            raise AssertionError(f"unexpected registry command {arguments}")
        return ""

    def _epic(self, arguments: list[str]) -> None:
        positionals, options = _parse(arguments)
        action, slug = positionals[1], positionals[2]
        if action != "create":
            raise AssertionError(f"unexpected epic action {arguments}")
        label = _single(options, "label", arguments)
        if not 1 <= len(label) <= 80:
            raise AssertionError(f"invalid label: {label!r} is not 1 to 80 characters")
        existing = self.epics.get(slug)
        if existing is None:
            self.epics[slug] = {"label": label, "features": []}
            self.writes.append(list(arguments))
        elif existing["label"] != label:
            raise AssertionError(
                f"epic {slug} exists with different values; use aiur epic edit"
            )

    def _feature(self, arguments: list[str]) -> None:
        positionals, options = _parse(arguments)
        action, slug = positionals[1], positionals[2]
        if action == "create":
            self._create_feature(slug, options, arguments)
        elif action == "add":
            self._add_members(slug, positionals[3:], options, arguments)
        else:
            raise AssertionError(f"unexpected feature action {arguments}")

    def _create_feature(self, slug: str, options: dict, arguments: list[str]) -> None:
        epic = _single(options, "in", arguments)
        if epic not in self.epics:
            raise AssertionError(f"unknown epic {epic}; create it with aiur epic create")
        lanes = _lanes(options, arguments)
        label = _single(options, "label", arguments)
        existing = self.features.get(slug)
        if existing is None:
            self.features[slug] = {"label": label, "lanes": lanes}
            self.epics[epic]["features"].append(slug)
            self.writes.append(list(arguments))
        elif existing["label"] != label or set(existing["lanes"]) != set(lanes):
            raise AssertionError(
                f"feature {slug} exists with different values; use aiur feature edit"
            )

    def _add_members(
        self, slug: str, numbers: list[str], options: dict, arguments: list[str],
    ) -> None:
        if slug not in self.features:
            raise AssertionError(f"unknown feature {slug}; create it first")
        lane = _single(options, "lane", arguments)
        if lane not in self.features[slug]["lanes"]:
            raise AssertionError(f"unknown lane {lane} on feature {slug}")
        members = self.features[slug]["lanes"][lane]["members"]
        missing = [number for number in numbers if number not in members]
        if missing:
            members.extend(missing)
            self.writes.append(list(arguments))


def _parse(arguments: list[str]) -> tuple[list[str], dict[str, list[str]]]:
    positionals: list[str] = []
    options: dict[str, list[str]] = {}
    index = 0
    while index < len(arguments):
        token = arguments[index]
        if token.startswith("--"):
            options.setdefault(token[2:], []).append(arguments[index + 1])
            index += 2
        else:
            positionals.append(token)
            index += 1
    return positionals, options


def _single(options: dict, name: str, arguments: list[str]) -> str:
    values = options.get(name, [])
    if len(values) != 1:
        raise AssertionError(f"{name} must appear once in {arguments}")
    return values[0]


def _lanes(options: dict, arguments: list[str]) -> dict[str, dict]:
    """Lane key -> its label and icon, as `--lane key=label --lane-icon key=icon`."""
    lanes: dict[str, dict] = {}
    for value in options.get("lane", []):
        key, label = value.split("=", 1)
        lanes[key] = {"label": label, "icon": None, "members": []}
    for value in options.get("lane-icon", []):
        key, icon = value.split("=", 1)
        if key not in lanes:
            raise AssertionError(f"--lane-icon {key} has no --lane in {arguments}")
        lanes[key]["icon"] = icon
    for key, lane in lanes.items():
        if lane["icon"] is None:
            raise AssertionError(f"lane {key} has no icon in {arguments}")
    return lanes


class PublicationRegistryTest(unittest.TestCase):
    def test_publication_registers_one_epic_three_features_and_their_lanes(self) -> None:
        registry = FakeRegistry()

        summary = ensure_registry(_publisher(registry), _mappings())

        self.assertEqual(["bo-41"], sorted(registry.epics))
        self.assertEqual("Game maker", registry.epics["bo-41"]["label"])
        self.assertEqual(
            ["game-maker-runtime-tools", "game-maker-editor-ui", "game-maker-level-editor"],
            registry.epics["bo-41"]["features"],
        )
        self.assertEqual(
            {
                "game-maker-runtime-tools": {
                    "label": "Runtime tools",
                    "lanes": {
                        "f-game-maker-runtime-tools-runtime": {
                            "label": "Runtime", "icon": "command-line", "members": ["42"],
                        },
                        "f-game-maker-runtime-tools-tooling": {
                            "label": "Tooling", "icon": "wrench", "members": ["44"],
                        },
                    },
                },
                "game-maker-editor-ui": {
                    "label": "Editor UI",
                    "lanes": {
                        "f-game-maker-editor-ui-ui": {
                            "label": "UI", "icon": "window", "members": ["43"],
                        },
                    },
                },
                "game-maker-level-editor": {
                    "label": "Level editor",
                    "lanes": {
                        "f-game-maker-level-editor-ui": {
                            "label": "UI", "icon": "window", "members": ["45"],
                        },
                    },
                },
            },
            registry.features,
        )
        self.assertEqual("bo-41", summary["epic"])
        self.assertEqual(["epic", "list", "--json"], registry.calls[0])
        self.assertEqual("epic", registry.calls[1][0])
        self.assertNotIn("--epic", " ".join(" ".join(call) for call in registry.calls))
        self.assertNotIn("--epic-icon", " ".join(" ".join(call) for call in registry.calls))

    def test_republishing_writes_nothing_new(self) -> None:
        registry = FakeRegistry()
        publisher = _publisher(registry)
        first = ensure_registry(publisher, _mappings())
        writes = list(registry.writes)
        calls = len(registry.calls)

        second = ensure_registry(publisher, _mappings())

        self.assertEqual(first, second)
        self.assertEqual(writes, registry.writes)
        self.assertGreater(len(registry.calls), calls)
        self.assertEqual(1, len(registry.epics))
        self.assertEqual(3, len(registry.features))
        creates = [call for call in registry.calls if call[:2] == ["epic", "create"]]
        self.assertEqual(1, len(creates), "a republished pack must not re-create its epic")

    def test_changed_pack_title_is_refused_instead_of_renaming(self) -> None:
        registry = FakeRegistry()
        ensure_registry(_publisher(registry), _mappings())
        writes = list(registry.writes)
        renamed = _publisher(registry)
        renamed.context.specs[ROOT_ID] = SimpleNamespace(title="Game maker 2")

        with self.assertRaisesRegex(PublicationError, "aiur epic edit bo-41"):
            ensure_registry(renamed, _mappings())

        self.assertEqual(writes, registry.writes)
        self.assertEqual("Game maker", registry.epics["bo-41"]["label"])

    def test_pack_title_over_the_epic_label_limit_is_refused(self) -> None:
        registry = FakeRegistry()
        long_title = _publisher(registry)
        long_title.context.specs[ROOT_ID] = SimpleNamespace(title="G" * 81)

        with self.assertRaisesRegex(PublicationError, "1 to 80"):
            ensure_registry(long_title, _mappings())

        self.assertEqual([], registry.calls)
        self.assertEqual({}, registry.epics)
        self.assertEqual([], registry.writes)

    def test_lane_labels_count_as_routing_labels(self) -> None:
        self.assertEqual(
            {"lane:runtime", "build-lane:ui"},
            routing_subset({"lane:runtime", "build-lane:ui", "bug"}),
        )


if __name__ == "__main__":
    unittest.main()
