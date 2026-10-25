#!/usr/bin/env python3
"""Safely publish and reconcile the approved Build Order issue graph.

Dry-run is the default.  ``--apply`` performs only the resumable publication
stage and writes pending receipts; it never commits, pushes, or marks the root
comment successful.  ``--finalize`` is a separate, receipt-commit-bound stage.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote

SKILL_SCRIPTS = Path(__file__).resolve().parents[1]
if str(SKILL_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SKILL_SCRIPTS))

from publication_comment import render_successful_comment
from publication_body_limits import format_body_limit_error
from publication_common import Report, SHA
from publication_receipt_authority import ReceiptAuthority, load_receipt_authority
from publication_rendering import exact_commit, reject_legacy_grafts, run_authority_git
import publication_client
import publication_mappings
import publication_materialize
import publication_pending
import publication_relationships
from publication_client import (  # noqa: F401
    AUTHORITY_CHECKPOINT_MUTATIONS,
    Budget,
    Client,
    GhClient,
    PublicationError,
    TIMEOUT_SECONDS,
)
from publication_context import (  # noqa: F401
    CREATABLE_LABELS,
    Context,
    IssueSpec,
    build_context,
)


class Publisher:
    def __init__(self, client: Client, context: Context) -> None:
        self.client, self.context, self.budget = client, context, Budget()
        self._guard_apply_mutations = False
        self._apply_mutation_count = 0
        self._retired_mappings: dict[str, dict[str, Any]] = {}
        self._retired_by_number: dict[int, tuple[str, str]] = {}
        self._reapproval: dict[str, list[str]] = self._empty_reapproval()

    def dry_run(self) -> dict[str, Any]:
        self._validate_body_lengths()
        self._persisted_mappings()
        self._check_authority()
        labels = self._pages(f"repos/{self.context.repository}/labels?per_page=100")
        missing = self._validate_label_inventory(labels)
        scan = self._scan_all()
        mappings = self._canonical_mappings(scan)
        self._check_authority()
        return {
            "mode": "dry-run",
            "approved_planning_commit": self.context.approved,
            "green_authority_commit": self.context.authority,
            "issues_scanned": len(scan),
            "canonical_issues_found": len(mappings),
            "issues_to_create": len(self.context.specs) - len(mappings),
            "labels_to_create": missing,
            "dependency_edges": len(self.context.core_edges),
            "extension_edges": len(
                self.context.expected_edges - self.context.core_edges
            ),
            "reapproval": self._reapproval,
            "mutations": 0,
        }

    def apply(self) -> dict[str, Any]:
        # This must remain before any GitHub read or mutation.  A pack is a
        # batch operation: report every oversized member before labels or
        # issues can leave the pack in a partial state.
        self._validate_body_lengths()
        self._persisted_mappings()
        self._check_authority()
        self._validate_persisted_ownership()
        labels = self._pages(f"repos/{self.context.repository}/labels?per_page=100")
        missing = self._validate_label_inventory(labels)
        scan = self._scan_all()
        mappings = self._canonical_mappings(scan)
        reapproval = self._reapproval
        self._guard_apply_mutations = True
        self._apply_mutation_count = 0
        try:
            for name in missing:
                color, description = self.context.creatable_labels[name]
                self._mutate("POST", f"repos/{self.context.repository}/labels", {
                    "name": name, "color": color, "description": description,
                })
            for logical_id in sorted(self.context.specs):
                mappings[logical_id] = self._ensure_issue(
                    self.context.specs[logical_id], mappings.get(logical_id),
                )
                self._persist_mapping(logical_id, mappings[logical_id])
            if len(mappings) != len(self.context.specs):
                raise PublicationError(
                    "publication did not materialize every planned identity"
                )
            self._ensure_relationships(mappings)
            comment = (
                self._ensure_pending_comment(mappings[self.context.root_id])
                if self.context.reconciliation_comment else None
            )
        finally:
            self._guard_apply_mutations = False
        self._check_authority()
        fresh = self._fresh_evidence(mappings, comment)
        self._write_materialized(fresh)
        self._run_validators()
        self._write_discovery_pack()
        self._check_authority()
        return {
            "mode": "apply-pending",
            "issues": len(self.context.specs),
            "members": sum(
                spec.kind == "ticket" for spec in self.context.specs.values()
            ),
            "blocked_by_edges": len(self.context.expected_edges),
            "reapproval": reapproval,
            **(
                {"pending_comment": fresh["comment"]["url"]}
                if fresh.get("comment") is not None else {}
            ),
            "files_written": [
                str(self.context.build_path), str(self.context.publication_path),
                str(self.context.discovery_path),
                str(self.context.root_document),
                *(
                    [str(self.context.additional_document)]
                    if self.context.additional_document is not None else []
                ),
            ],
            "next": "review, commit, and push receipts; then run --finalize explicitly",
        }

    def _validate_body_lengths(self) -> None:
        error = format_body_limit_error({
            logical_id: spec.body
            for logical_id, spec in self.context.specs.items()
        })
        if error is not None:
            raise PublicationError(error)

    def finalize(self, receipt_commit: str, receipt_url: str) -> dict[str, Any]:
        if not self.context.reconciliation_comment:
            raise PublicationError(
                "this planning pack does not declare a reconciliation-comment policy"
            )
        if not SHA.fullmatch(receipt_commit):
            raise PublicationError("--receipt-commit must be an exact 40-character SHA")
        self._check_authority(expected_tip=None)
        if not exact_commit(
            self.context.root, receipt_commit, "receipt_commit", Report()
        ):
            raise PublicationError("receipt commit is unavailable locally")
        ancestor = run_authority_git([
            "git", "-C", str(self.context.root), "merge-base", "--is-ancestor",
            self.context.approved, receipt_commit,
        ], check=False, capture_output=True, text=True)
        if ancestor.returncode or receipt_commit == self.context.approved:
            raise PublicationError("receipt commit must strictly descend from approval")
        authority = self._receipt_authority(receipt_commit)
        expected_receipt_url = (
            f"https://github.com/{authority.repository}/commit/{receipt_commit}"
        )
        expected = (
            (authority.root_id, self.context.root_id, "root identity"),
            (authority.plan_version, self.context.plan_version, "plan version"),
            (authority.approved_commit, self.context.approved, "approval"),
            (authority.repository, self.context.repository, "repository"),
        )
        for receipt_value, context_value, label in expected:
            if receipt_value != context_value:
                raise PublicationError(f"receipt {label} differs from operator context")
        if receipt_url != expected_receipt_url:
            raise PublicationError(f"--receipt-url must equal {expected_receipt_url}")

        # The immutable receipt, never mutable checkout receipt fields, selects
        # the pending authorization comment. Finalization preserves it forever
        # and appends one distinct successful receipt comment.
        comment_url = authority.root_comment_url
        prefix = f"{authority.root_issue_url}#issuecomment-"
        comment_id = comment_url.removeprefix(prefix)
        if not comment_url.startswith(prefix) or not comment_id.isdigit() or comment_id.startswith("0"):
            raise PublicationError("receipt-bound comment identity is invalid")
        comment_path = f"repos/{authority.repository}/issues/comments/{comment_id}"
        raw_comment = self._get(comment_path)
        state = self._canonical_comment_state(
            raw_comment, authority, receipt_commit, expected_receipt_url,
        )
        if state != "pending":
            raise PublicationError(
                "receipt-bound comment is not the canonical pending authorization"
            )
        comments = self._reconciliation_comment_states(
            authority, receipt_commit, expected_receipt_url,
        )
        successful_url = comments.get("successful")
        if successful_url is not None:
            self._run_receipt_verifier(
                "successful", authority, receipt_commit, expected_receipt_url,
            )
            return {
                "mode": "finalized", "pending_comment": comment_url,
                "successful_comment": successful_url,
                "receipt": receipt_commit,
            }

        # The receipt-bound verifier performs two complete graph reads before
        # the mutation. Re-scan afterward: a prior crashed/concurrent attempt
        # may already have appended the one canonical successful receipt.
        self._run_receipt_verifier(
            "pending", authority, receipt_commit, expected_receipt_url,
        )
        comments = self._reconciliation_comment_states(
            authority, receipt_commit, expected_receipt_url,
        )
        successful_url = comments.get("successful")
        if successful_url is not None:
            self._run_receipt_verifier(
                "successful", authority, receipt_commit, expected_receipt_url,
            )
            return {
                "mode": "finalized", "pending_comment": comment_url,
                "successful_comment": successful_url,
                "receipt": receipt_commit,
            }
        body = render_successful_comment(
            authority.root_id, authority.plan_version, authority.approved_commit,
            authority.repository, receipt_commit, expected_receipt_url,
        )
        root_number = authority.root_issue_url.rsplit("/", 1)[-1]
        created = self._mutate(
            "POST",
            f"repos/{authority.repository}/issues/{root_number}/comments",
            {"body": body},
        )
        if self._canonical_comment_state(
            created, authority, receipt_commit, expected_receipt_url,
        ) != "successful":
            raise PublicationError(
                "created reconciliation comment is not the canonical successful receipt"
            )
        successful_url = created["html_url"]
        comments = self._reconciliation_comment_states(
            authority, receipt_commit, expected_receipt_url,
        )
        if comments.get("successful") != successful_url:
            raise PublicationError(
                "created successful receipt is not the unique visible reconciliation evidence"
            )
        self._run_receipt_verifier(
            "successful", authority, receipt_commit, expected_receipt_url,
        )
        return {
            "mode": "finalized", "pending_comment": comment_url,
            "successful_comment": successful_url, "receipt": receipt_commit,
        }

    def _receipt_authority(self, receipt_commit: str) -> ReceiptAuthority:
        report = Report()
        authority = load_receipt_authority(
            receipt_commit, self.context.root, report,
        )
        if authority is None:
            raise PublicationError(
                "receipt authority is invalid: " + "; ".join(report.errors)
            )
        return authority

    def _run_receipt_verifier(
        self, state: str, authority: ReceiptAuthority, receipt_commit: str,
        receipt_url: str,
    ) -> None:
        command = [
            sys.executable,
            str(self.context.publication_path.parent / "scripts/publication_comment.py"),
        ]
        if state == "pending":
            command.extend(["--state", "pending"])
        command.extend([
            authority.root_id, str(authority.plan_version),
            authority.approved_commit, receipt_commit, receipt_url,
            authority.root_issue_url, authority.repository,
        ])
        self._run_checked(command, f"{state} receipt-bound verifier")

    def _check_authority(self, expected_tip: str | None = "configured") -> None:
        report = Report()
        if not reject_legacy_grafts(self.context.root, report):
            raise PublicationError("; ".join(report.errors))
        for value, label in (
            (self.context.approved, "approved_planning_commit"),
            (self.context.authority, "green_authority_commit"),
        ):
            if not exact_commit(self.context.root, value, label, report):
                raise PublicationError("; ".join(report.errors) or f"invalid {label}")
        result = run_authority_git([
            "git", "-C", str(self.context.root), "merge-base", "--is-ancestor",
            self.context.approved, self.context.authority,
        ], check=False, capture_output=True, text=True)
        if result.returncode:
            raise PublicationError("approval must be an ancestor of green authority")
        ref_path = quote(self.context.trusted_ref.removeprefix("refs/"), safe="/")
        raw = self._get(f"repos/{self.context.repository}/git/ref/{ref_path}")
        target = raw.get("object") if isinstance(raw, dict) else None
        if (
            not isinstance(raw, dict) or raw.get("ref") != self.context.trusted_ref
            or not isinstance(target, dict) or target.get("type") != "commit"
            or not isinstance(target.get("sha"), str)
        ):
            raise PublicationError("trusted GitHub ref did not return one commit target")
        if expected_tip == "configured" and target["sha"].lower() != self.context.authority:
            raise PublicationError("trusted GitHub ref no longer equals green authority")

    def _validate_label_inventory(self, raw: list[Any]) -> list[str]:
        names: set[str] = set()
        for item in raw:
            name = item.get("name") if isinstance(item, dict) else None
            if not isinstance(name, str) or not name or name in names:
                raise PublicationError("label scan returned invalid or duplicate names")
            names.add(name)
        required = {label for spec in self.context.specs.values() for label in spec.labels}
        missing = sorted(required - names)
        forbidden_creation = sorted(
            set(missing) - set(self.context.creatable_labels)
        )
        if forbidden_creation:
            raise PublicationError(
                "required labels must already exist and will not be invented: "
                + ", ".join(forbidden_creation)
            )
        return missing

    def _run_validators(self) -> None:
        canonical_command = [
            sys.executable,
            str(SKILL_SCRIPTS / "validate_build_order.py"),
            str(self.context.build_path),
            "--repository-root", str(self.context.root),
            "--root-document",
            self.context.root_document.resolve().relative_to(
                self.context.root.resolve()
            ).as_posix(),
            # The lifecycle label prefix must reach the validator from the
            # manifest, never from the Build Order it is checking.
            "--publication-manifest", str(self.context.publication_path),
        ]
        self._run_checked(canonical_command, "canonical validator")
        if self.context.extra_validator is not None:
            self._run_checked([
                sys.executable, str(self.context.extra_validator),
                str(self.context.build_path), str(self.context.publication_path),
            ], "publication validator")

    @staticmethod
    def _run_checked(command: list[str], label: str) -> None:
        try:
            result = subprocess.run(
                command, check=False, capture_output=True, text=True,
                timeout=TIMEOUT_SECONDS * 10,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PublicationError(f"{label} failed safely ({type(exc).__name__})") from None
        if result.returncode:
            detail = "\n".join((result.stdout + result.stderr).splitlines()[-20:])
            raise PublicationError(f"{label} failed:\n{detail}")

    _reconciliation_comment_states = publication_pending.reconciliation_comment_states
    _canonical_comment_state = publication_pending.canonical_comment_state
    _scan_all = publication_mappings.scan_all
    _empty_reapproval = staticmethod(publication_mappings.empty_reapproval)
    _authority_conflict = publication_mappings.authority_conflict
    _content_changed = publication_mappings.content_changed
    _is_recorded_reapproval = publication_mappings.is_recorded_reapproval
    _canonical_mappings = publication_mappings.canonical_mappings
    _persisted_mappings = publication_mappings.persisted_mappings
    _validate_persisted_ownership = publication_mappings.validate_persisted_ownership
    _ensure_issue = publication_mappings.ensure_issue
    _persist_mapping = publication_mappings.persist_mapping
    _atomic_write_bundle = publication_materialize.atomic_write_bundle
    _replace_staged_files = staticmethod(publication_materialize.replace_staged_files)
    _recover_materialization_transaction = staticmethod(publication_materialize.recover_materialization_transaction)
    _fsync_directory = staticmethod(publication_materialize.fsync_directory)
    _atomic_write_json = staticmethod(publication_materialize.atomic_write_json)
    _validate_live_issue_identity = publication_relationships.validate_live_issue_identity
    _validate_live_issue_authority = publication_relationships.validate_live_issue_authority
    _ensure_relationships = publication_relationships.ensure_relationships
    _ensure_pending_comment = publication_pending.ensure_pending_comment
    _fresh_evidence = publication_pending.fresh_evidence
    _write_materialized = publication_materialize.write_materialized
    _write_discovery_pack = publication_materialize.write_discovery_pack
    _pages = publication_client.pages
    _get = publication_client.get
    _mutate = publication_client.mutate
    _mapping = publication_client.mapping
    _receipt_mapping = staticmethod(publication_client.receipt_mapping)
    _database_id = staticmethod(publication_client.database_id)
    _relationship_id = publication_relationships.relationship_id
    _relationship_ids = publication_relationships.relationship_ids
    _labels = staticmethod(publication_client.labels)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=Path(__file__).resolve().parent.parent / "build-order.json")
    parser.add_argument("--publication", type=Path, default=Path(__file__).resolve().parent.parent / "publication.json")
    parser.add_argument("--approved-sha", required=True)
    parser.add_argument("--green-authority-sha", required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--dry-run", action="store_true", help="read-only rehearsal (default)")
    modes.add_argument("--apply", action="store_true", help="publish and write pending receipts")
    modes.add_argument("--finalize", action="store_true", help="verify receipt and edit pending comment successful")
    parser.add_argument("--receipt-commit")
    parser.add_argument("--receipt-url")
    args = parser.parse_args(argv[1:])
    try:
        context = build_context(
            args.build.resolve(), args.publication.resolve(),
            args.approved_sha, args.green_authority_sha,
        )
        publisher = Publisher(GhClient(), context)
        if args.finalize:
            if not args.receipt_commit or not args.receipt_url:
                raise PublicationError("--finalize requires --receipt-commit and --receipt-url")
            result = publisher.finalize(args.receipt_commit, args.receipt_url)
        elif args.apply:
            if args.receipt_commit or args.receipt_url:
                raise PublicationError("receipt arguments are accepted only with --finalize")
            result = publisher.apply()
        else:
            if args.receipt_commit or args.receipt_url:
                raise PublicationError("receipt arguments are accepted only with --finalize")
            result = publisher.dry_run()
    except PublicationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
