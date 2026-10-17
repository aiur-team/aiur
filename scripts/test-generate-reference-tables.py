#!/usr/bin/env python3
"""Exercise reference regeneration and sibling-branch table union behavior."""

from __future__ import annotations

import importlib.util
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).with_name("generate-reference-tables.py")
SPEC = importlib.util.spec_from_file_location("generate_reference_tables", SCRIPT)
assert SPEC and SPEC.loader
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


def check_rows_are_added_and_idempotent() -> None:
    source = """| Key | Type | Default | Controls | <!-- generated-reference:config-demo -->
| --- | --- | --- | --- |
| `alpha` | string | nil | Alpha. |
"""
    generated = ["| `alpha` | string | nil | Alpha. |", "| `beta` | string | nil | Beta. |"]
    updated, seen = GENERATOR.replace_tables(source, {"config-demo": generated}, "demo.md")
    assert seen == {"config-demo"}
    assert "| `beta` | string | nil | Beta. |" in updated
    repeated, _ = GENERATOR.replace_tables(updated, {"config-demo": generated}, "demo.md")
    assert repeated == updated


def check_split_config_annotations_pair_across_comments() -> None:
    rows = GENERATOR.config_rows(
        """# @config-reference config-demo feature.enabled
# credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
# @config-detail feature.enabled | boolean | false | Controls the feature. |
"""
    )
    assert rows == {"config-demo": ["| `feature.enabled` | boolean | false | Controls the feature. |"]}


def check_combined_config_annotation_preserves_each_key() -> None:
    rows = GENERATOR.config_rows(
        """# @config-reference config-demo feature.name, feature.email
# @config-detail feature.name, feature.email | string or nil | nil | Shared identity fields. |
"""
    )
    assert rows == {
        "config-demo": [
            "| `feature.name`, `feature.email` | string or nil | nil | Shared identity fields. |"
        ]
    }


def check_incomplete_config_annotations_fail() -> None:
    try:
        GENERATOR.config_rows("# @config-reference config-demo feature.enabled\n", "fixture.ex")
    except SystemExit as error:
        assert "missing @config-detail" in str(error)
    else:
        raise AssertionError("incomplete config annotation was accepted")


def check_unannotated_generated_marker_fails() -> None:
    try:
        GENERATOR.replace_tables(
            "| Key | Type | Default | Controls | <!-- generated-reference:config-missing -->\n| --- | --- | --- | --- |\n",
            {},
            "demo.md",
        )
    except SystemExit as error:
        assert "has no schema or CLI annotations" in str(error)
    else:
        raise AssertionError("unannotated generated table was silently skipped")


def check_sibling_rows_union_after_merge() -> None:
    # Each branch adds one annotated row. The merged table contains one of them;
    # regeneration unions the current table with the other branch's metadata.
    branch_a = "| `alpha` | string | nil | Alpha. |"
    branch_b = "| `beta` | string | nil | Beta. |"
    merged_table = f"""| Key | Type | Default | Controls | <!-- generated-reference:config-demo -->
| --- | --- | --- | --- |
{branch_a}
"""
    source_rows = sorted([branch_a, branch_b], key=GENERATOR.row_identity)
    updated, _ = GENERATOR.replace_tables(merged_table, {"config-demo": source_rows}, "demo.md")
    assert branch_a in updated and branch_b in updated
    assert updated.index(branch_a) < updated.index(branch_b)


def check_reference_files_use_union_merge() -> None:
    paths = [
        "website/docs-app/reference/configuration.md",
        "website/docs-app/reference/configuration-agent.md",
        "website/docs-app/reference/configuration-build-order.md",
        "website/docs-app/reference/merge-policy.md",
        "website/docs-app/reference/cli-options.md",
    ]
    result = subprocess.run(
        ["git", "-C", str(GENERATOR.ROOT), "check-attr", "merge", "--", *paths],
        check=True,
        capture_output=True,
        text=True,
    )
    assert all(line.endswith(": merge: union") for line in result.stdout.splitlines())

    with tempfile.TemporaryDirectory(prefix="reference-union-", dir=GENERATOR.ROOT) as directory:
        root = Path(directory)
        base, ours, theirs = (root / name for name in ("base.md", "ours.md", "theirs.md"))
        header = "| Key | Type | Default | Controls |\n| --- | --- | --- | --- |\n"
        base.write_text(header + "| `alpha` | string | nil | Alpha. |\n")
        ours.write_text(header + "| `alpha` | string | nil | Alpha. |\n| `branch_a` | string | nil | A. |\n")
        theirs.write_text(header + "| `alpha` | string | nil | Alpha. |\n| `branch_b` | string | nil | B. |\n")
        subprocess.run(
            ["git", "-C", str(GENERATOR.ROOT), "merge-file", "--union", str(ours), str(base), str(theirs)],
            check=True,
        )
        merged = ours.read_text()
        assert "| `branch_a`" in merged and "| `branch_b`" in merged


if __name__ == "__main__":
    check_rows_are_added_and_idempotent()
    check_split_config_annotations_pair_across_comments()
    check_combined_config_annotation_preserves_each_key()
    check_incomplete_config_annotations_fail()
    check_unannotated_generated_marker_fails()
    check_sibling_rows_union_after_merge()
    check_reference_files_use_union_merge()
    print("reference generator tests passed")
