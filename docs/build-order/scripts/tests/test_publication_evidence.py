from __future__ import annotations

import tempfile
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_fixtures import Fixture, companions, github, publication  # noqa: E402
from publication_materialized_fixture import (  # noqa: E402
    ROOT_ID,
    SKILL_ID,
    materialized_pack,
)
from validate_publication import validate  # noqa: E402


class PublicationEvidenceTests(unittest.TestCase):
    def report(self, mutate=None):
        data, build, manifest = materialized_pack()
        if mutate is not None:
            mutate(data, build, manifest)
        fixture = Fixture(data, build, manifest)
        self.addCleanup(fixture.close)
        return validate(
            fixture.companion_path, fixture.build_path, fixture.publication_path
        )

    def test_companion_required_labels_are_exact(self) -> None:
        data = companions()
        data["required_labels"].append("area:dashboard")
        fixture = Fixture(data)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("required_labels must equal model:codex", joined)

    def test_companion_observation_rejects_new_routing_labels(self) -> None:
        def mutate(data, _build, _manifest):
            data["github_reconciliation"]["observed_labels"]["DASH-001"] += [
                "agent:brand-new", "human:todo", "phase:4",
            ]

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("agent:brand-new, human:todo, phase:4", joined)

    def test_body_evidence_partitions_are_exact(self) -> None:
        def mutate(_data, _build, manifest):
            evidence = manifest["github_reconciliation"]["observed_body_evidence"]
            evidence["example/repo:build-order-dashboard"] = next(iter(evidence.values()))

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("publication receipt.observed_body_evidence keys must match its owned issues", joined)

    def test_body_markers_and_hashes_are_bound(self) -> None:
        mutations = {
            "marker_count": (2, "marker_count must equal 1"),
            "marker_schema_version": (1, "marker_schema_version must equal 2"),
            "marker_logical_id": ("wrong", "marker_logical_id must equal DASH-001"),
            "marker_plan_version": (2, "marker_plan_version must equal 1"),
            "approved_planning_commit": ("0" * 40, "approved_planning_commit must match"),
            "approved_link_count": (2, "approved_link_count must equal 1"),
            "approved_link": ("https://example.com/wrong", "independently rendered approved body"),
            "body_sha256": ("A" * 64, "body_sha256 must be a lowercase SHA-256"),
        }
        for key, (value, expected) in mutations.items():
            with self.subTest(key=key):
                def mutate(data, _build, _manifest, key=key, value=value):
                    evidence = data["github_reconciliation"]["observed_body_evidence"]
                    evidence["DASH-001"][key] = value

                self.assertIn(expected, "\n".join(self.report(mutate).errors))

    def test_all_body_hashes_must_be_unique(self) -> None:
        def mutate(data, build, _manifest):
            core = build["github_reconciliation"]["observed_body_evidence"]["BO-001"]
            core["body_sha256"] = "0" * 64
            data["github_reconciliation"]["observed_body_evidence"]["DASH-001"][
                "body_sha256"
            ] = "0" * 64

        joined = "\n".join(self.report(mutate).errors)
        self.assertIn("observed body SHA-256 for DASH-001 duplicates BO-001", joined)

    def test_arbitrary_and_truncated_body_hashes_fail(self) -> None:
        def arbitrary(data, _build, _manifest):
            data["github_reconciliation"]["observed_body_evidence"]["DASH-001"][
                "body_sha256"
            ] = "0" * 64

        self.assertIn(
            "independently rendered approved body",
            "\n".join(self.report(arbitrary).errors),
        )

        def truncated(data, _build, _manifest):
            data["github_reconciliation"]["observed_body_evidence"]["DASH-001"][
                "body_sha256"
            ] = "0" * 63

        self.assertIn(
            "body_sha256 must be a lowercase SHA-256",
            "\n".join(self.report(truncated).errors),
        )

    def test_materialization_body_coverage_is_derived_from_manifests(self) -> None:
        def mutate(_data, build, _manifest):
            removed = build["tickets"].pop()["id"]
            receipt = build["github_reconciliation"]
            receipt["member_ticket_ids"].remove(removed)
            for field in ("projected_labels", "observed_labels", "observed_body_evidence"):
                del receipt[field][removed]
            del receipt["marker_query_matches"][removed]

        report = self.report(mutate)
        self.assertEqual([], report.errors)

    def test_comment_receipt_is_exact_and_pending(self) -> None:
        mutations = {
            "marker": ("wrong", "must match the canonical pending comment"),
            "state": ("successful", "must match the canonical pending comment"),
            "url": ("https://github.com/example/repo/issues/2#issuecomment-1", "mapped root issue"),
            "body_sha256": ("not-a-hash", "must match the canonical pending comment"),
        }
        for key, (value, expected) in mutations.items():
            with self.subTest(key=key):
                def mutate(_data, _build, manifest, key=key, value=value):
                    comment = manifest["github_reconciliation"]["root_reconciliation_comment_matches"][0]
                    comment[key] = value

                self.assertIn(expected, "\n".join(self.report(mutate).errors))

    def test_issue_marker_queries_require_one_exact_mapping(self) -> None:
        def duplicate(data, _build, _manifest):
            matches = data["github_reconciliation"]["marker_query_matches"]["DASH-001"]
            matches.append(dict(matches[0]))

        self.assertIn(
            "must contain exactly one issue match", "\n".join(self.report(duplicate).errors)
        )

        def wrong(data, _build, _manifest):
            matches = data["github_reconciliation"]["marker_query_matches"]["DASH-001"]
            matches[0] = dict(data["tickets"][1]["github"])

        self.assertIn(
            "must equal the returned GitHub mapping", "\n".join(self.report(wrong).errors)
        )

    def test_comment_marker_query_requires_one_match(self) -> None:
        def mutate(_data, _build, manifest):
            matches = manifest["github_reconciliation"]["root_reconciliation_comment_matches"]
            matches.append(dict(matches[0]))

        self.assertIn(
            "must contain exactly one comment match", "\n".join(self.report(mutate).errors)
        )

    def test_read_only_refs_are_exact(self) -> None:
        manifest = publication()
        manifest["read_only_issue_refs"].append("example/repo#999")
        fixture = Fixture(publication_data=manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("#132, #845, #1033, #1034, and #1067", joined)

    def test_read_only_issue_cannot_be_reused_by_any_publication_class(self) -> None:
        for issue_class in ("root", "bo", "dash", "skill"):
            with self.subTest(issue_class=issue_class):
                data, build, manifest = materialized_pack()
                mapping = github(132, f"PROTECTED_{issue_class.upper()}_NODE")
                logical_id = ""
                if issue_class == "root":
                    logical_id = ROOT_ID
                    build["github_root"] = dict(mapping)
                    build["github_reconciliation"]["root_node_id"] = mapping["node_id"]
                    build["github_reconciliation"]["marker_query_matches"][ROOT_ID] = [
                        dict(mapping)
                    ]
                    manifest["github_reconciliation"]["issue_mappings"][ROOT_ID] = dict(
                        mapping
                    )
                    manifest["github_reconciliation"][
                        "root_reconciliation_comment_matches"
                    ][0]["url"] = mapping["url"] + "#issuecomment-987"
                elif issue_class == "bo":
                    logical_id = "BO-001"
                    build["tickets"][0]["github"] = dict(mapping)
                    build["github_reconciliation"]["marker_query_matches"][logical_id] = [
                        dict(mapping)
                    ]
                elif issue_class == "dash":
                    logical_id = "DASH-001"
                    data["tickets"][0]["github"] = dict(mapping)
                    data["github_reconciliation"]["marker_query_matches"][logical_id] = [
                        dict(mapping)
                    ]
                else:
                    logical_id = SKILL_ID
                    manifest["github_reconciliation"]["issue_mappings"][SKILL_ID] = dict(
                        mapping
                    )
                    manifest["github_reconciliation"]["marker_query_matches"][SKILL_ID] = [
                        dict(mapping)
                    ]
                fixture = Fixture(data, build, manifest)
                self.addCleanup(fixture.close)
                joined = "\n".join(validate(
                    fixture.companion_path, fixture.build_path,
                    fixture.publication_path,
                ).errors)
                self.assertIn(
                    f"publication mapping {logical_id} reuses protected read-only issue "
                    "example/repo#132",
                    joined,
                )

    def test_staged_approval_must_resolve_before_materialization(self) -> None:
        data, manifest = companions(), publication()
        data["approved_planning_commit"] = "0" * 40
        manifest["approved_planning_commit"] = "0" * 40
        fixture = Fixture(data, publication_data=manifest)
        self.addCleanup(fixture.close)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("must resolve to an exact commit in this repository", joined)

    def test_document_symlinks_cannot_escape_pack(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        target = Path(outside.name) / "outside.md"
        target.write_text("# DASH-001 outside\n", encoding="utf-8")
        dash_path = fixture.base / "tickets/DASH-001.md"
        dash_path.unlink()
        dash_path.symlink_to(target)
        root_path = fixture.base / "root-issue.md"
        root_path.unlink()
        root_path.symlink_to(target)
        joined = "\n".join(validate(fixture.companion_path, fixture.build_path).errors)
        self.assertIn("DASH-001.document does not resolve within", joined)
        self.assertIn("root_issue.document does not resolve within", joined)


if __name__ == "__main__":
    unittest.main()
