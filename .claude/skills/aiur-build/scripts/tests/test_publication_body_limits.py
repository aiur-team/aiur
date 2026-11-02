"""GitHub issue-body limit and resumable publication tests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_body_limits import (  # noqa: E402
    MAX_ISSUE_BODY_CHARACTERS,
    format_body_limit_error,
)
from publication_operator import IssueSpec, PublicationError, Publisher  # noqa: E402
from publication_common import validate_document as validate_publication_document  # noqa: E402
from validation_common import Report  # noqa: E402
from validation_documents import validate_document  # noqa: E402
from validation_github_rendering import authority_preamble, inspect_issue_body  # noqa: E402
from publication_rendering import inspect_issue_body as inspect_published_issue_body  # noqa: E402


class NoRequestClient:
    def request(self, *args, **kwargs):
        raise AssertionError("body preflight must run before GitHub requests")


class CreateThenReadFailureClient:
    def request(self, method, path, payload=None, *, allow_404=False):
        if method == "POST":
            return {
                "id": 1004,
                "number": 104,
                "node_id": "NODE_104",
                "html_url": "https://github.com/example/repo/issues/104",
            }
        raise RuntimeError("simulated follow-up read failure")


class PointerOwnershipClient:
    def __init__(self) -> None:
        self.methods = []

    def request(self, method, path, payload=None, *, allow_404=False):
        self.methods.append(method)
        return {
            "id": 104, "number": 104, "node_id": "NODE_OTHER",
            "html_url": "https://github.com/example/repo/issues/104",
            "state": "open", "locked": False, "title": "title",
            "body": "body", "labels": [],
        }


class PublicationBodyLimitTests(unittest.TestCase):
    def test_at_limit_is_accepted(self) -> None:
        self.assertIsNone(format_body_limit_error({"BO-001": "x" * MAX_ISSUE_BODY_CHARACTERS}))

    def test_over_limit_reports_length_and_overage(self) -> None:
        body = "x" * (MAX_ISSUE_BODY_CHARACTERS + 5_672)
        error = format_body_limit_error({"AS-104": body})
        self.assertEqual(
            "1 members exceed GitHub's 65,536-character issue body limit\n"
            "  AS-104  71,208 (+5,672)",
            error,
        )

    def test_multiple_over_limit_members_are_reported_before_any_request(self) -> None:
        specs = {
            logical_id: IssueSpec(logical_id, logical_id, "x" * length, (), "ticket")
            for logical_id, length in (
                ("AS-104", MAX_ISSUE_BODY_CHARACTERS + 5_672),
                ("AS-111", MAX_ISSUE_BODY_CHARACTERS + 3_404),
            )
        }
        publisher = Publisher(NoRequestClient(), SimpleNamespace(specs=specs))
        with self.assertRaisesRegex(PublicationError, "2 members exceed") as raised:
            publisher.apply()
        self.assertIn("AS-104  71,208 (+5,672)", str(raised.exception))
        self.assertIn("AS-111  68,940 (+3,404)", str(raised.exception))

    def test_each_mapping_checkpoint_is_written_for_retry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_path = root / "build-order.json"
            publication_path = root / "publication.json"
            build = {
                "github_root": None,
                "tickets": [{"id": "BO-001", "github": None}],
            }
            publication = {}
            build_path.write_text(json.dumps(build), encoding="utf-8")
            publication_path.write_text(json.dumps(publication), encoding="utf-8")
            context = SimpleNamespace(
                root_id="root", skill_id=None, build=build,
                publication=publication, build_path=build_path,
                publication_path=publication_path,
            )
            publisher = Publisher(object(), context)
            mapping = {
                "repository": "example/repo", "number": 104,
                "node_id": "NODE_104",
                "url": "https://github.com/example/repo/issues/104",
            }
            publisher._persist_mapping(
                "root",
                {
                    **mapping,
                    "number": 103,
                    "node_id": "NODE_103",
                    "url": "https://github.com/example/repo/issues/103",
                },
            )
            publisher._persist_mapping("BO-001", mapping)
            persisted = json.loads(build_path.read_text(encoding="utf-8"))
            self.assertEqual(103, persisted["github_root"]["number"])
            self.assertEqual(104, persisted["tickets"][0]["github"]["number"])

    def test_create_is_checkpointed_before_follow_up_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_path = root / "build-order.json"
            publication_path = root / "publication.json"
            build = {
                "github_root": None,
                "tickets": [{"id": "BO-001", "github": None}],
            }
            build_path.write_text(json.dumps(build), encoding="utf-8")
            publication_path.write_text("{}", encoding="utf-8")
            context = SimpleNamespace(
                repository="example/repo", root_id="root", skill_id=None,
                build=build, publication={}, build_path=build_path,
                publication_path=publication_path,
            )
            publisher = Publisher(CreateThenReadFailureClient(), context)
            spec = IssueSpec("BO-001", "BO-001", "body", (), "ticket")
            with self.assertRaisesRegex(RuntimeError, "follow-up read"):
                publisher._ensure_issue(spec, None)
            persisted = json.loads(build_path.read_text(encoding="utf-8"))
            self.assertEqual(104, persisted["tickets"][0]["github"]["number"])

    def test_persisted_pointer_ownership_is_checked_before_reconciliation(self) -> None:
        client = PointerOwnershipClient()
        context = SimpleNamespace(repository="example/repo")
        publisher = Publisher(client, context)
        spec = IssueSpec("BO-001", "title", "body", (), "ticket")
        mapping = {
            "repository": "example/repo", "number": 104,
            "node_id": "NODE_104",
            "url": "https://github.com/example/repo/issues/104",
        }
        with self.assertRaisesRegex(PublicationError, "does not own"):
            publisher._ensure_issue(spec, mapping)
        self.assertEqual(["GET"], client.methods)

    def test_all_persisted_pointers_are_preflighted_before_apply_mutations(self) -> None:
        client = PointerOwnershipClient()
        mapping = {
            "repository": "example/repo", "number": 104,
            "node_id": "NODE_104",
            "url": "https://github.com/example/repo/issues/104",
        }
        spec = IssueSpec("BO-001", "title", "body", (), "ticket")
        context = SimpleNamespace(
            repository="example/repo", root_id="root", skill_id=None,
            specs={"BO-001": spec},
            build={"github_root": None, "tickets": [{"id": "BO-001", "github": mapping}]},
            publication={},
        )
        publisher = Publisher(client, context)
        with self.assertRaisesRegex(PublicationError, "does not own"):
            publisher._validate_persisted_ownership()
        self.assertEqual(["GET"], client.methods)

    def test_duplicate_persisted_issue_numbers_fail_before_remote_reads(self) -> None:
        mapping = {
            "repository": "example/repo", "number": 104,
            "node_id": "NODE_104",
            "url": "https://github.com/example/repo/issues/104",
        }
        context = SimpleNamespace(
            repository="example/repo", root_id="root", skill_id=None,
            specs={
                "root": IssueSpec("root", "root", "body", (), "root"),
                "BO-001": IssueSpec("BO-001", "ticket", "body", (), "ticket"),
            },
            build={
                "github_root": mapping,
                "tickets": [{"id": "BO-001", "github": mapping}],
            },
            publication={},
        )
        publisher = Publisher(NoRequestClient(), context)
        with self.assertRaisesRegex(PublicationError, "same issue"):
            publisher._persisted_mappings()

    def test_null_reconciliation_is_normalized_before_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_path = root / "build-order.json"
            publication_path = root / "publication.json"
            build = {"github_root": None, "tickets": []}
            publication = {"github_reconciliation": None}
            build_path.write_text(json.dumps(build), encoding="utf-8")
            publication_path.write_text(json.dumps(publication), encoding="utf-8")
            context = SimpleNamespace(
                root=root, root_id="root", skill_id="SKILL-DELIVERY-001",
                build=build, publication=publication,
                build_path=build_path, publication_path=publication_path,
            )
            publisher = Publisher(object(), context)
            mapping = {
                "repository": "example/repo", "number": 104,
                "node_id": "NODE_104",
                "url": "https://github.com/example/repo/issues/104",
            }
            publisher._persist_mapping("root", mapping)
            persisted = json.loads(publication_path.read_text(encoding="utf-8"))
            self.assertEqual(
                mapping,
                persisted["github_reconciliation"]["issue_mappings"]["root"],
            )
            context.publication = {"github_reconciliation": []}
            publisher.context.publication = context.publication
            with self.assertRaisesRegex(PublicationError, "must be an object or null"):
                publisher._persist_mapping("root", mapping)

    def test_persisted_mapping_wins_when_marker_scan_is_incomplete(self) -> None:
        mapping = {
            "repository": "example/repo", "number": 104,
            "node_id": "NODE_104",
            "url": "https://github.com/example/repo/issues/104",
        }
        context = SimpleNamespace(
            repository="example/repo", root_id="root", skill_id=None,
            specs={"root": IssueSpec("root", "root", "body", (), "root")},
            build={"github_root": mapping, "tickets": []},
            publication={},
        )
        publisher = Publisher(object(), context)
        self.assertEqual(
            {"root": mapping},
            publisher._canonical_mappings([{"number": 999, "_planning_markers": []}]),
        )

    def test_planning_warns_when_ticket_document_exceeds_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.md"
            path.write_text(
                "# BO-001 — Oversized\n\n**Kind:** umbrella\n" +
                "x" * (MAX_ISSUE_BODY_CHARACTERS + 1),
                encoding="utf-8",
            )
            report = Report()
            validate_document(
                "BO-001", "ticket.md", {"kind": "umbrella"}, {},
                Path(directory), report,
            )
            self.assertEqual([], report.errors)
            self.assertIn("exceeding GitHub's 65,536-character", report.warnings[0])

    def test_planning_measures_rendered_body_preamble(self) -> None:
        approved = "a" * 40
        repository = "example/repo"
        preamble = authority_preamble(repository, "BO-001", 1, approved)
        prefix = "# BO-001 — Oversized\n\n**Kind:** umbrella\n"
        source = prefix + "x" * (
            MAX_ISSUE_BODY_CHARACTERS - len(preamble) - len(prefix) + 1
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.md"
            path.write_text(source, encoding="utf-8")
            report = Report()
            validate_document(
                "BO-001", "ticket.md", {"kind": "umbrella"},
                {
                    "repository": repository, "plan_version": 1,
                    "researched_at_commit": approved,
                }, Path(directory), report,
            )
            self.assertEqual([], report.errors)
            self.assertIn("renders to 65,537 characters", report.warnings[0])

    def test_planning_preserves_crlf_when_measuring_rendered_body(self) -> None:
        approved = "a" * 40
        repository = "example/repo"
        preamble = authority_preamble(repository, "BO-001", 1, approved)
        prefix = "# BO-001 — Oversized\r\n\r\n**Kind:** umbrella\r\n"
        source = prefix + "x" * (
            MAX_ISSUE_BODY_CHARACTERS - len(preamble) - len(prefix) + 1
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.md"
            path.write_bytes(source.encode("utf-8"))
            report = Report()
            validate_document(
                "BO-001", "ticket.md", {"kind": "umbrella"},
                {
                    "repository": repository, "plan_version": 1,
                    "researched_at_commit": approved,
                }, Path(directory), report,
            )
            self.assertEqual([], report.errors)
            self.assertIn("renders to 65,537 characters", report.warnings[0])

    def test_extended_publication_warning_measures_rendered_ticket_body(self) -> None:
        approved = "a" * 40
        repository = "example/repo"
        preamble = authority_preamble(repository, "BO-001", 1, approved)
        prefix = "# BO-001 — Oversized\n\n**Complexity:** 1\n"
        source = prefix + "x" * (
            MAX_ISSUE_BODY_CHARACTERS - len(preamble) - len(prefix) + 1
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.md"
            path.write_text(source, encoding="utf-8")
            report = Report()
            validate_publication_document(
                {"id": "BO-001", "title": "Oversized", "document": "ticket.md", "complexity_points": 1},
                Path(directory), report,
                repository=repository, plan_version=1, approved=approved,
            )
            self.assertIn("renders to 65,537 characters", report.warnings[0])

    def test_rendered_issue_inspection_warns_for_extended_body_limit(self) -> None:
        approved = "a" * 40
        repository = "example/repo"
        preamble = authority_preamble(repository, "SKILL-DELIVERY-001", 1, approved)
        body = preamble + "x" * (MAX_ISSUE_BODY_CHARACTERS - len(preamble) + 1)
        report = Report()
        self.assertIsNotNone(
            inspect_issue_body(
                body, repository, "SKILL-DELIVERY-001", 1, approved,
                report, "extended skill body",
            )
        )
        self.assertIn("rendered issue body is 65,537 characters", report.warnings[0])

    def test_extended_renderer_warns_for_rendered_body_limit(self) -> None:
        approved = "a" * 40
        repository = "example/repo"
        preamble = authority_preamble(repository, "SKILL-DELIVERY-001", 1, approved)
        body = preamble + "x" * (MAX_ISSUE_BODY_CHARACTERS - len(preamble) + 1)
        report = Report()
        self.assertIsNotNone(
            inspect_published_issue_body(
                body, repository, "SKILL-DELIVERY-001", 1, approved,
                report, "extended skill body",
            )
        )
        self.assertIn("rendered issue body is 65,537 characters", report.warnings[0])


if __name__ == "__main__":
    unittest.main()
