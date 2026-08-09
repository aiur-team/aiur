#!/usr/bin/env python3
"""Safely publish and reconcile the approved Build Order issue graph.

Dry-run is the default.  ``--apply`` performs only the resumable publication
stage and writes pending receipts; it never commits, pushes, or marks the root
comment successful.  ``--finalize`` is a separate, receipt-commit-bound stage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import quote

SKILL_SCRIPTS = Path(__file__).resolve().parents[1]
if str(SKILL_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SKILL_SCRIPTS))

from publication_comment import (
    COMMENT_MARKER,
    inspect_comment,
    render_pending_comment,
    render_successful_comment,
)
from publication_common import Report, SHA, load_json
from publication_labels import routing_subset
from publication_live_graph import API_VERSION, MARKER, MARKER_NAME
from publication_receipt_authority import ReceiptAuthority, load_receipt_authority
from publication_rendering import (
    MARKER_KEYS,
    exact_commit,
    reject_legacy_grafts,
    render_approved_issue_content,
    repository_root,
    run_authority_git,
)
from validation_github_approved import render_approved_build_order
from validation_github_rendering import inspect_issue_body, render_template_body
from validation_git_approved_source import approved_text


TIMEOUT_SECONDS = 30
PAGE_SIZE = 100
MAX_PAGES = 100
MAX_REQUESTS = 2_500
MAX_ITEMS = 50_000
AUTHORITY_CHECKPOINT_MUTATIONS = 16
CREATABLE_LABELS = {
    "build-order": ("5319e7", "Build Order planning root"),
    "build-lane:plan-graph": ("bfdadc", "Build Order lane: plan graph"),
    "build-lane:runtime": ("bfdadc", "Build Order lane: runtime"),
    "build-lane:dashboard-ui": ("bfdadc", "Build Order lane: dashboard UI"),
    "build-lane:accounting": ("bfdadc", "Build Order lane: accounting"),
    "build-lane:platform": ("bfdadc", "Build Order lane: platform"),
    "phase:7": ("d4c5f9", "Build Order phase 7"),
    "phase:8": ("d4c5f9", "Build Order phase 8"),
}


class PublicationError(RuntimeError):
    """A fail-closed publication precondition or GitHub operation failed."""


class Client(Protocol):
    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None,
        *, allow_404: bool = False,
    ) -> Any: ...


@dataclass
class Budget:
    requests: int = 0
    items: int = 0

    def request(self) -> None:
        self.requests += 1
        if self.requests > MAX_REQUESTS:
            raise PublicationError("GitHub operation exceeds total request bound")

    def add_items(self, count: int) -> None:
        self.items += count
        if self.items > MAX_ITEMS:
            raise PublicationError("GitHub operation exceeds total item bound")


class GhClient:
    """A github.com-only, version-pinned, timeout-bounded ``gh api`` client."""

    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None,
        *, allow_404: bool = False,
    ) -> Any:
        if not path.startswith("repos/") or "://" in path or path.startswith("/"):
            raise PublicationError("refusing non-repository or non-relative API path")
        command = [
            "gh", "api", "--hostname", "github.com", "--method", method,
            "-H", "Accept: application/vnd.github+json",
            "-H", f"X-GitHub-Api-Version: {API_VERSION}", path,
        ]
        input_text = None
        if payload is not None:
            command.extend(["--input", "-"])
            input_text = json.dumps(payload, separators=(",", ":"))
        try:
            result = subprocess.run(
                command, input=input_text, capture_output=True, text=True,
                check=False, timeout=TIMEOUT_SECONDS,
                env=os.environ.copy(),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PublicationError(
                f"GitHub {method} request failed safely ({type(exc).__name__})"
            ) from None
        if result.returncode:
            if allow_404 and "HTTP 404" in result.stderr:
                return None
            # Never echo stderr: auth helpers and proxies can include secrets.
            raise PublicationError(
                f"GitHub {method} request failed safely (gh exit {result.returncode})"
            )
        if not result.stdout.strip():
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            raise PublicationError("GitHub returned invalid JSON") from None


@dataclass(frozen=True)
class IssueSpec:
    logical_id: str
    title: str
    body: str
    labels: tuple[str, ...]
    kind: str


@dataclass
class Context:
    root: Path
    build_path: Path
    publication_path: Path
    discovery_path: Path
    approved: str
    authority: str
    repository: str
    trusted_ref: str
    plan_version: int
    root_id: str
    skill_id: str | None
    build: dict[str, Any]
    publication: dict[str, Any]
    specs: dict[str, IssueSpec]
    approved_evidence: dict[str, dict[str, Any]]
    expected_edges: set[tuple[str, str]]
    core_edges: set[tuple[str, str]]
    creatable_labels: dict[str, tuple[str, str]]
    reconciliation_comment: bool
    root_document: Path
    additional_document: Path | None
    extra_validator: Path | None


class Publisher:
    def __init__(self, client: Client, context: Context) -> None:
        self.client, self.context, self.budget = client, context, Budget()
        self._guard_apply_mutations = False
        self._apply_mutation_count = 0

    def dry_run(self) -> dict[str, Any]:
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
            "mutations": 0,
        }

    def apply(self) -> dict[str, Any]:
        self._check_authority()
        labels = self._pages(f"repos/{self.context.repository}/labels?per_page=100")
        missing = self._validate_label_inventory(labels)
        scan = self._scan_all()
        mappings = self._canonical_mappings(scan)
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

    def _reconciliation_comment_states(
        self, authority: ReceiptAuthority, receipt_commit: str,
        receipt_url: str,
    ) -> dict[str, str]:
        root_number = authority.root_issue_url.rsplit("/", 1)[-1]
        raw_comments = self._pages(
            f"repos/{authority.repository}/issues/{root_number}/comments?per_page=100"
        )
        found: dict[str, list[str]] = {"pending": [], "successful": []}
        for raw in raw_comments:
            body = raw.get("body") if isinstance(raw, dict) else None
            if not isinstance(body, str):
                raise PublicationError("root comment scan returned invalid content")
            if f"<!-- {COMMENT_MARKER}" not in body:
                continue
            state = self._canonical_comment_state(
                raw, authority, receipt_commit, receipt_url,
            )
            if state is None:
                raise PublicationError(
                    "root issue contains malformed or conflicting reconciliation evidence"
                )
            found[state].append(raw["html_url"])
        if found["pending"] != [authority.root_comment_url]:
            raise PublicationError(
                "root issue must preserve exactly one receipt-bound pending comment"
            )
        if len(found["successful"]) > 1:
            raise PublicationError(
                "root issue contains duplicate successful reconciliation evidence"
            )
        return {
            "pending": found["pending"][0],
            **({"successful": found["successful"][0]} if found["successful"] else {}),
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

    def _canonical_comment_state(
        self, raw: Any, authority: ReceiptAuthority, receipt_commit: str,
        receipt_url: str,
    ) -> str | None:
        if not isinstance(raw, dict):
            return None
        comment_url = raw.get("html_url")
        prefix = f"{authority.root_issue_url}#issuecomment-"
        comment_id = comment_url.removeprefix(prefix) if isinstance(comment_url, str) else ""
        if (
            not isinstance(comment_url, str) or not comment_url.startswith(prefix)
            or not comment_id.isdigit() or comment_id.startswith("0")
        ):
            return None
        body = raw.get("body")
        for state, commit, url, canonical_body in (
            (
                "successful", receipt_commit, receipt_url,
                render_successful_comment(
                    authority.root_id, authority.plan_version,
                    authority.approved_commit, authority.repository,
                    receipt_commit, receipt_url,
                ),
            ),
            (
                "pending", None, None,
                render_pending_comment(
                    authority.root_id, authority.plan_version,
                    authority.approved_commit, authority.repository,
                ),
            ),
        ):
            if body != canonical_body:
                continue
            if state == "pending" and comment_url != authority.root_comment_url:
                continue
            if state == "successful" and comment_url == authority.root_comment_url:
                continue
            report = Report()
            if inspect_comment(
                body, comment_url, authority.root_id,
                authority.plan_version, authority.approved_commit, state,
                commit, url, authority.repository,
                f"receipt-bound {state} comment", report,
            ) is not None and not report.errors:
                return state
        return None

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

    def _scan_all(self) -> list[dict[str, Any]]:
        values = self._pages(
            f"repos/{self.context.repository}/issues?state=all&per_page=100"
        )
        seen_numbers: set[int] = set()
        seen_nodes: set[str] = set()
        output: list[dict[str, Any]] = []
        for raw in values:
            if not isinstance(raw, dict):
                raise PublicationError("all-state scan returned a non-object")
            number, node = raw.get("number"), raw.get("node_id")
            if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
                raise PublicationError("all-state scan returned invalid identity")
            if number in seen_numbers or node in seen_nodes:
                raise PublicationError("all-state scan returned duplicate identity")
            seen_numbers.add(number); seen_nodes.add(node)
            body = raw.get("body")
            if body is not None and not isinstance(body, str):
                raise PublicationError(f"issue/PR #{number} returned a non-text body")
            text = body or ""
            openings = text.count(f"<!-- {MARKER_NAME}")
            matches = list(MARKER.finditer(text))
            if openings != len(matches):
                raise PublicationError(f"malformed planning marker on issue/PR #{number}")
            payloads: list[dict[str, Any]] = []
            for match in matches:
                try:
                    payload = json.loads(match.group("payload"))
                except json.JSONDecodeError:
                    raise PublicationError(f"malformed planning marker JSON on issue/PR #{number}") from None
                if not isinstance(payload, dict) or set(payload) != MARKER_KEYS:
                    raise PublicationError(f"malformed planning marker schema on issue/PR #{number}")
                payloads.append(payload)
            if len(payloads) > 1:
                raise PublicationError(
                    f"issue/PR #{number} contains multiple planning markers"
                )
            copy = dict(raw); copy["_planning_markers"] = payloads
            output.append(copy)
        return output

    def _canonical_mappings(self, scan: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        found: dict[str, list[dict[str, Any]]] = {key: [] for key in self.context.specs}
        protected = {
            int(value.rsplit("#", 1)[-1].rsplit("/", 1)[-1])
            for value in (
                self.context.publication.get("read_only_issue_refs", [])
                or self.context.publication.get("reference_only_issue_urls", [])
            )
            if isinstance(value, str)
            and ("#" in value or "/issues/" in value)
        }
        for raw in scan:
            for marker in raw["_planning_markers"]:
                logical_id = marker.get("logical_id")
                if logical_id not in found:
                    continue
                if "pull_request" in raw:
                    raise PublicationError(f"logical identity {logical_id} collides with a pull request")
                if (
                    marker.get("schema") != 2
                    or marker.get("plan_version") != self.context.plan_version
                    or marker.get("approved_planning_commit") != self.context.approved
                ):
                    raise PublicationError(f"logical identity {logical_id} has conflicting authority")
                found[logical_id].append(raw)
        mappings: dict[str, dict[str, Any]] = {}
        for logical_id, matches in found.items():
            if len(matches) > 1:
                raise PublicationError(f"logical identity {logical_id} has multiple issue matches")
            if matches:
                raw = matches[0]
                if raw["number"] in protected:
                    raise PublicationError(f"logical identity {logical_id} reuses protected issue #{raw['number']}")
                mappings[logical_id] = self._mapping(raw)
        numbers = [mapping["number"] for mapping in mappings.values()]
        nodes = [mapping["node_id"] for mapping in mappings.values()]
        if len(numbers) != len(set(numbers)) or len(nodes) != len(set(nodes)):
            raise PublicationError(
                "multiple logical identities resolve to the same issue"
            )
        return mappings

    def _ensure_issue(
        self, spec: IssueSpec, mapping: dict[str, Any] | None,
    ) -> dict[str, Any]:
        base = f"repos/{self.context.repository}/issues"
        if mapping is None:
            created = self._mutate("POST", base, {
                "title": spec.title, "body": spec.body, "labels": list(spec.labels),
            })
            number = created.get("number") if isinstance(created, dict) else None
            if type(number) is not int:
                raise PublicationError(f"create response for {spec.logical_id} lacks issue number")
        else:
            number = mapping["number"]
        raw = self._get(f"{base}/{number}")
        self._validate_live_issue_identity(raw, spec)
        labels = self._labels(raw)
        routing = routing_subset(set(labels))
        expected_routing = routing_subset(set(spec.labels))
        unexpected = sorted(routing - expected_routing)
        if unexpected:
            raise PublicationError(
                f"{spec.logical_id} has forbidden routing labels: " + ", ".join(unexpected)
            )
        patch: dict[str, Any] = {}
        if raw.get("title") != spec.title:
            patch["title"] = spec.title
        if raw.get("body") != spec.body:
            patch["body"] = spec.body
        missing = sorted(set(spec.labels) - set(labels))
        if patch:
            self._mutate("PATCH", f"{base}/{number}", patch)
        if missing:
            # The additive labels endpoint avoids a read/replace race that
            # could remove unrelated metadata added between GET and PATCH.
            self._mutate("POST", f"{base}/{number}/labels", {"labels": missing})
        if patch or missing:
            raw = self._get(f"{base}/{number}")
            self._validate_live_issue_identity(raw, spec)
            if raw.get("title") != spec.title or raw.get("body") != spec.body:
                raise PublicationError(f"{spec.logical_id} did not reconcile exact content")
            if not set(spec.labels).issubset(self._labels(raw)):
                raise PublicationError(f"{spec.logical_id} did not reconcile labels")
        return self._mapping(raw)

    def _validate_live_issue_identity(self, raw: Any, spec: IssueSpec) -> None:
        if not isinstance(raw, dict) or "pull_request" in raw:
            raise PublicationError(f"{spec.logical_id} did not resolve to an issue")
        if raw.get("state") != "open" or raw.get("locked") is not False:
            raise PublicationError(f"{spec.logical_id} must be open and unlocked")
        if type(raw.get("id")) is not int or raw["id"] < 1:
            raise PublicationError(f"{spec.logical_id} lacks numeric relationship identity")

    def _ensure_relationships(self, mappings: dict[str, dict[str, Any]]) -> None:
        root = mappings[self.context.root_id]
        member_ids = {key for key, spec in self.context.specs.items() if spec.kind == "ticket"}
        by_number = {
            value["number"]: (key, value["node_id"])
            for key, value in mappings.items()
        }
        observed_subissues: dict[str, set[str]] = {}
        observed_parents: dict[str, str | None] = {}
        observed_blockers: dict[str, set[str]] = {}
        expected_by_blocked: dict[str, set[str]] = {
            logical_id: set() for logical_id in mappings
        }
        for blocked, blocker in self.context.expected_edges:
            expected_by_blocked[blocked].add(blocker)

        # Complete the bounded conflict read before the first relationship
        # mutation.  A late unexpected parent/edge must not leave a partial
        # graph that the operator could have rejected up front.
        for logical_id in sorted(mappings):
            mapping = mappings[logical_id]
            parent = self._get(
                f"repos/{self.context.repository}/issues/{mapping['number']}/parent",
                allow_404=True,
            )
            observed_parents[logical_id] = None if parent is None else self._relationship_id(
                parent, by_number, f"{logical_id} parent",
            )
            observed_subissues[logical_id] = self._relationship_ids(self._pages(
                f"repos/{self.context.repository}/issues/{mapping['number']}"
                "/sub_issues?per_page=100"
            ), by_number, f"{logical_id} subissues")
            observed_blockers[logical_id] = self._relationship_ids(self._pages(
                f"repos/{self.context.repository}/issues/{mapping['number']}"
                "/dependencies/blocked_by?per_page=100"
            ), by_number, f"{logical_id} blockers")

        for logical_id in sorted(mappings):
            expected_parent = self.context.root_id if logical_id in member_ids else None
            if observed_parents[logical_id] != expected_parent and observed_parents[logical_id] is not None:
                raise PublicationError(f"{logical_id} already has a different parent")
            expected_children = member_ids if logical_id == self.context.root_id else set()
            unexpected_children = observed_subissues[logical_id] - expected_children
            if unexpected_children:
                raise PublicationError(
                    f"{logical_id} has unexpected existing subissues: "
                    + ", ".join(sorted(unexpected_children))
                )
            unexpected = observed_blockers[logical_id] - expected_by_blocked[logical_id]
            if unexpected:
                raise PublicationError(
                    f"{logical_id} has unexpected existing blockers: "
                    + ", ".join(sorted(unexpected))
                )

        for logical_id in sorted(member_ids - observed_subissues[self.context.root_id]):
            self._mutate(
                "POST",
                f"repos/{self.context.repository}/issues/{root['number']}/sub_issues",
                {"sub_issue_id": self._database_id(mappings[logical_id])},
            )
        for blocked in sorted(mappings):
            for blocker in sorted(expected_by_blocked[blocked] - observed_blockers[blocked]):
                self._mutate(
                    "POST",
                    f"repos/{self.context.repository}/issues/{mappings[blocked]['number']}"
                    "/dependencies/blocked_by",
                    {"issue_id": self._database_id(mappings[blocker])},
                )

    def _ensure_pending_comment(self, root: dict[str, Any]) -> dict[str, Any]:
        body = render_pending_comment(
            self.context.root_id, self.context.plan_version,
            self.context.approved, self.context.repository,
        )
        comments = self._pages(
            f"repos/{self.context.repository}/issues/{root['number']}/comments?per_page=100"
        )
        matches = [
            item for item in comments if isinstance(item, dict)
            and isinstance(item.get("body"), str)
            and f"<!-- {COMMENT_MARKER}" in item["body"]
        ]
        if len(matches) > 1:
            raise PublicationError("root has multiple reconciliation comments")
        if matches:
            comment = matches[0]
            report = Report()
            evidence = inspect_comment(
                comment.get("body"), comment.get("html_url"), self.context.root_id,
                self.context.plan_version, self.context.approved, "pending", None,
                None, self.context.repository, "pending root comment", report,
            )
            if evidence is None or comment.get("body") != body:
                raise PublicationError(
                    "existing reconciliation comment is malformed or not canonical pending"
                )
            return comment
        created = self._mutate(
            "POST", f"repos/{self.context.repository}/issues/{root['number']}/comments",
            {"body": body},
        )
        comment_id = created.get("id") if isinstance(created, dict) else None
        if type(comment_id) is not int:
            raise PublicationError("created reconciliation comment lacks numeric identity")
        return self._get(
            f"repos/{self.context.repository}/issues/comments/{comment_id}"
        )

    def _fresh_evidence(
        self, mappings: dict[str, dict[str, Any]], comment: dict[str, Any] | None,
    ) -> dict[str, Any]:
        scan = self._scan_all()
        fresh_mappings = self._canonical_mappings(scan)
        if set(fresh_mappings) != set(self.context.specs):
            raise PublicationError(
                "fresh marker scan does not exactly cover every planned identity"
            )
        marker_matches = {key: [fresh_mappings[key]] for key in fresh_mappings}
        issues: dict[str, dict[str, Any]] = {}
        by_number = {
            value["number"]: (key, value["node_id"])
            for key, value in fresh_mappings.items()
        }
        for logical_id, mapping in sorted(fresh_mappings.items()):
            spec = self.context.specs[logical_id]
            raw = self._get(
                f"repos/{self.context.repository}/issues/{mapping['number']}"
            )
            self._validate_live_issue_identity(raw, spec)
            labels = self._labels(raw)
            if routing_subset(set(labels)) != routing_subset(set(spec.labels)):
                raise PublicationError(f"fresh labels differ from projection for {logical_id}")
            parent_raw = self._get(
                f"repos/{self.context.repository}/issues/{mapping['number']}/parent",
                allow_404=True,
            )
            parent = None if parent_raw is None else self._relationship_id(parent_raw, by_number, f"{logical_id} parent")
            subissues = self._relationship_ids(self._pages(
                f"repos/{self.context.repository}/issues/{mapping['number']}/sub_issues?per_page=100"
            ), by_number, f"{logical_id} subissues")
            blockers = self._relationship_ids(self._pages(
                f"repos/{self.context.repository}/issues/{mapping['number']}/dependencies/blocked_by?per_page=100"
            ), by_number, f"{logical_id} blockers")
            expected_parent = self.context.root_id if spec.kind == "ticket" else None
            expected_subissues = {
                key for key, candidate in self.context.specs.items() if candidate.kind == "ticket"
            } if logical_id == self.context.root_id else set()
            expected_blockers = {blocker for blocked, blocker in self.context.expected_edges if blocked == logical_id}
            if parent != expected_parent or subissues != expected_subissues or blockers != expected_blockers:
                raise PublicationError(f"fresh relationship evidence differs for {logical_id}")
            body = raw.get("body")
            if raw.get("title") != spec.title or body != spec.body:
                raise PublicationError(f"fresh content evidence differs for {logical_id}")
            issues[logical_id] = {
                "mapping": self._mapping(raw), "labels": labels,
                "title": raw["title"], "state": raw["state"].upper(),
                "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
                "parent": parent,
            }
        comment_evidence = None
        if comment is not None:
            fresh_comment = self._get(
                f"repos/{self.context.repository}/issues/comments/{comment['id']}"
            )
            report = Report()
            comment_evidence = inspect_comment(
                fresh_comment.get("body") if isinstance(fresh_comment, dict) else None,
                fresh_comment.get("html_url") if isinstance(fresh_comment, dict) else None,
                self.context.root_id, self.context.plan_version, self.context.approved,
                "pending", None, None, self.context.repository,
                "fresh pending root comment", report,
            )
            if comment_evidence is None:
                raise PublicationError(
                    "fresh pending comment evidence is invalid: "
                    + "; ".join(report.errors)
                )
            comments = self._pages(
                f"repos/{self.context.repository}/issues/"
                f"{fresh_mappings[self.context.root_id]['number']}"
                "/comments?per_page=100"
            )
            marker_urls = [
                value.get("html_url") for value in comments
                if isinstance(value, dict) and isinstance(value.get("body"), str)
                and f"<!-- {COMMENT_MARKER}" in value["body"]
            ]
            if marker_urls != [comment_evidence["url"]]:
                raise PublicationError(
                    "fresh root comment scan must find exactly one pending marker"
                )
        return {
            "issues": issues, "marker_matches": marker_matches,
            "comment": comment_evidence,
        }

    def _write_materialized(self, fresh: dict[str, Any]) -> None:
        build = json.loads(json.dumps(self.context.build))
        publication = json.loads(json.dumps(self.context.publication))
        issues = fresh["issues"]
        root_mapping = self._receipt_mapping(issues[self.context.root_id]["mapping"])
        build["github_root"] = root_mapping
        for ticket in build["tickets"]:
            ticket["github"] = self._receipt_mapping(issues[ticket["id"]]["mapping"])
        ticket_ids = [ticket["id"] for ticket in build["tickets"]]
        checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        projected = {key: list(spec.labels) for key, spec in self.context.specs.items()}
        build["github_reconciliation"] = {
            "receipt_schema_version": 3,
            "checked_at": checked_at,
            "approved_planning_commit": self.context.approved,
            "root_node_id": root_mapping["node_id"],
            "member_ticket_ids": ticket_ids,
            "dependency_edges": [
                {"ticket_id": blocked, "depends_on": blocker}
                for blocked, blocker in sorted(self.context.core_edges)
            ],
            "projected_labels": {
                key: projected[key] for key in [self.context.root_id, *ticket_ids]
            },
            "observed_labels": {
                key: issues[key]["labels"] for key in [self.context.root_id, *ticket_ids]
            },
            "expected_issue_titles": {
                key: self.context.specs[key].title for key in [self.context.root_id, *ticket_ids]
            },
            "observed_issue_titles": {
                key: issues[key]["title"] for key in [self.context.root_id, *ticket_ids]
            },
            "observed_issue_states": {
                key: issues[key]["state"] for key in [self.context.root_id, *ticket_ids]
            },
            "observed_body_evidence": {
                key: self.context.approved_evidence[key] for key in [self.context.root_id, *ticket_ids]
            },
            "marker_query_matches": {
                key: [self._receipt_mapping(item) for item in fresh["marker_matches"][key]]
                for key in [self.context.root_id, *ticket_ids]
            },
        }
        if self.context.skill_id is not None:
            skill_id = self.context.skill_id
            publication["approved_planning_commit"] = self.context.approved
            publication["github_reconciliation"] = {
                "receipt_schema_version": 2,
                "checked_at": checked_at,
                "issue_mappings": {
                    self.context.root_id: root_mapping,
                    skill_id: self._receipt_mapping(issues[skill_id]["mapping"]),
                },
                "external_blocker_relations": publication[
                    "external_blocker_relations"
                ],
                "observed_labels": {
                    self.context.root_id: issues[self.context.root_id]["labels"],
                    skill_id: issues[skill_id]["labels"],
                },
                "observed_parent_issues": {
                    self.context.root_id: None, skill_id: None,
                },
                "observed_body_evidence": {
                    skill_id: self.context.approved_evidence[skill_id],
                },
                "expected_issue_titles": {
                    skill_id: self.context.specs[skill_id].title,
                },
                "observed_issue_titles": {skill_id: issues[skill_id]["title"]},
                "observed_issue_states": {skill_id: issues[skill_id]["state"]},
                "marker_query_matches": {
                    skill_id: [
                        self._receipt_mapping(item)
                        for item in fresh["marker_matches"][skill_id]
                    ],
                },
                "root_reconciliation_comment_matches": [fresh["comment"]],
            }
        self.context.build_path.write_text(json.dumps(build, indent=1) + "\n", encoding="utf-8")
        self.context.publication_path.write_text(json.dumps(publication, indent=2) + "\n", encoding="utf-8")
        self.context.root_document.write_text(
            self.context.specs[self.context.root_id].body, encoding="utf-8",
        )
        if self.context.additional_document is not None and self.context.skill_id:
            self.context.additional_document.write_text(
                self.context.specs[self.context.skill_id].body, encoding="utf-8",
            )

    def _write_discovery_pack(self) -> None:
        self.context.discovery_path.parent.mkdir(parents=True, exist_ok=True)
        self.context.discovery_path.write_text(
            self.context.build_path.read_text(encoding="utf-8"), encoding="utf-8",
        )

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

    def _pages(self, path: str) -> list[Any]:
        output: list[Any] = []
        separator = "&" if "?" in path else "?"
        for page in range(1, MAX_PAGES + 1):
            raw = self._get(f"{path}{separator}page={page}")
            if not isinstance(raw, list):
                raise PublicationError("paginated GitHub response must be an array")
            self.budget.add_items(len(raw)); output.extend(raw)
            if len(raw) < PAGE_SIZE:
                return output
        raise PublicationError("GitHub pagination exceeds page bound")

    def _get(self, path: str, *, allow_404: bool = False) -> Any:
        self.budget.request()
        return self.client.request("GET", path, allow_404=allow_404)

    def _mutate(self, method: str, path: str, payload: dict[str, Any]) -> Any:
        if (
            self._guard_apply_mutations
            and self._apply_mutation_count % AUTHORITY_CHECKPOINT_MUTATIONS == 0
        ):
            self._check_authority()
        self.budget.request()
        result = self.client.request(method, path, payload)
        if self._guard_apply_mutations:
            self._apply_mutation_count += 1
        return result

    def _mapping(self, raw: dict[str, Any]) -> dict[str, Any]:
        number, node, url = raw.get("number"), raw.get("node_id"), raw.get("html_url")
        expected_url = f"https://github.com/{self.context.repository}/issues/{number}"
        if type(number) is not int or not isinstance(node, str) or url != expected_url:
            raise PublicationError("GitHub issue returned invalid canonical mapping")
        return {
            "repository": self.context.repository, "number": number,
            "node_id": node, "url": url,
            "_database_id": raw.get("id"),
        }

    @staticmethod
    def _receipt_mapping(mapping: dict[str, Any]) -> dict[str, Any]:
        return {
            key: mapping[key]
            for key in ("repository", "number", "node_id", "url")
        }

    @staticmethod
    def _database_id(mapping: dict[str, Any]) -> int:
        value = mapping.get("_database_id")
        if type(value) is not int or value < 1:
            raise PublicationError("mapped issue lacks numeric relationship identity")
        return value

    def _relationship_id(
        self, raw: Any, by_number: dict[int, tuple[str, str]], label: str,
    ) -> str:
        if not isinstance(raw, dict) or type(raw.get("number")) is not int:
            raise PublicationError(f"{label} returned invalid relationship identity")
        expected = by_number.get(raw["number"])
        if expected is None:
            raise PublicationError(f"{label} references an issue outside this publication")
        logical_id, expected_node = expected
        expected_url = (
            f"https://github.com/{self.context.repository}/issues/{raw['number']}"
        )
        if raw.get("html_url") != expected_url or "pull_request" in raw:
            raise PublicationError(
                f"{label} must resolve inside the trusted repository"
            )
        node = raw.get("node_id")
        if node is not None and node != expected_node:
            raise PublicationError(
                f"{label} returned a conflicting node identity"
            )
        return logical_id

    def _relationship_ids(
        self, raw: list[Any], by_number: dict[int, tuple[str, str]], label: str,
    ) -> set[str]:
        values = [self._relationship_id(item, by_number, label) for item in raw]
        if len(values) != len(set(values)):
            raise PublicationError(f"{label} returned duplicate relationships")
        return set(values)

    @staticmethod
    def _labels(raw: dict[str, Any]) -> list[str]:
        values = raw.get("labels")
        if not isinstance(values, list):
            raise PublicationError("issue labels must be an array")
        labels = [item.get("name") if isinstance(item, dict) else None for item in values]
        if not all(isinstance(item, str) and item for item in labels) or len(labels) != len(set(labels)):
            raise PublicationError("issue labels contain invalid or duplicate names")
        return sorted(labels)


def build_context(
    build_path: Path, publication_path: Path, approved: str, authority: str,
    extension: dict[str, Any] | None = None,
) -> Context:
    if not SHA.fullmatch(approved) or not SHA.fullmatch(authority):
        raise PublicationError("approval and green authority must be exact 40-character SHAs")
    report = Report()
    root = repository_root(build_path, report)
    build = load_json(build_path, "build-order", report)
    publication = load_json(publication_path, "publication", report)
    if root is None or build is None or publication is None:
        raise PublicationError("; ".join(report.errors))
    repository, plan_version, root_id = (
        build.get("repository"), build.get("plan_version"), build.get("build_order_id")
    )
    trusted_ref = publication.get("trusted_repository_ref")
    if not all(
        isinstance(value, str) and value
        for value in (repository, root_id, trusted_ref)
    ) or type(plan_version) is not int:
        raise PublicationError("publication identity fields are invalid")
    slug = root_id.removeprefix(f"{repository}:")
    if root_id == slug or not slug or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in slug):
        raise PublicationError("build_order_id must be repository:feature-slug")
    mutation_repositories = publication.get("mutation_repositories")
    if mutation_repositories is not None and (
        not isinstance(mutation_repositories, list)
        or repository not in mutation_repositories
    ):
        raise PublicationError(
            "canonical repository must be explicitly authorized for mutation"
        )
    try:
        build_relative = build_path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        raise PublicationError("build-order manifest must remain inside the repository") from None
    extension = dict(extension or {})
    if not extension and isinstance(publication.get("skill_issue"), dict):
        extension = {
            "additional_issue": {
                "manifest_key": "skill_issue", "labels": ["human:todo"],
            },
            "external_edges_field": "external_blocker_relations",
            "feature_title_prefix": "BO:",
            "additional_title_must_be_unprefixed": True,
            "reconciliation_comment": True,
            "creatable_labels": CREATABLE_LABELS,
            "extra_validator": "scripts/validate_publication.py",
        }
    root_document_value = publication.get("root_document")
    if not isinstance(root_document_value, str):
        root_manifest = publication.get("root_issue")
        root_relative = root_manifest.get("document") if isinstance(root_manifest, dict) else None
        if not isinstance(root_relative, str):
            raise PublicationError("publication root document is unavailable")
        root_document_value = (
            build_path.parent / root_relative
        ).resolve().relative_to(root.resolve()).as_posix()
    if isinstance(extension.get("additional_issue"), dict):
        rendered = render_approved_issue_content(
            build_path, publication_path, approved.lower(), report,
        )
        if rendered is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        titles, bodies, evidence = rendered
    else:
        expectations = render_approved_build_order(
            root, approved.lower(), build_relative, root_document_value,
            build, report,
        )
        if (
            expectations is None or expectations.rendered_bodies is None
            or report.errors
        ):
            raise PublicationError("; ".join(report.errors))
        titles = expectations.titles
        bodies = expectations.rendered_bodies
        evidence = dict(expectations.bodies)
    feature_prefix = extension.get("feature_title_prefix")
    feature_ids = {
        root_id,
        *(
            item.get("id") for item in build.get("tickets", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ),
    }
    if isinstance(feature_prefix, str) and any(
        not titles.get(logical_id, "").startswith(feature_prefix)
        for logical_id in feature_ids
    ):
        raise PublicationError(
            f"every feature issue title must start with {feature_prefix}"
        )
    tickets = build.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        raise PublicationError("operator requires a non-empty reviewed ticket manifest")
    projection = build.get("label_projection")
    if not isinstance(projection, dict):
        raise PublicationError("label projection is unavailable")
    root_label = projection.get("build_order")
    if not isinstance(root_label, str) or not root_label:
        raise PublicationError("label projection build_order is unavailable")
    specs: dict[str, IssueSpec] = {
        root_id: IssueSpec(
            root_id, titles[root_id], bodies[root_id], (root_label,), "root",
        ),
    }
    core_edges: set[tuple[str, str]] = set()
    for ticket in tickets:
        if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
            raise PublicationError("ticket manifest entry is invalid")
        logical_id = ticket["id"]
        try:
            labels = (
                *projection["required_ticket_labels"],
                projection["workstreams"][ticket["workstream"]],
                projection["phases"][str(ticket["phase_hint"])],
                projection["complexities"][str(ticket["complexity_points"])],
            )
        except (KeyError, TypeError):
            raise PublicationError(f"ticket label projection is invalid for {logical_id}") from None
        specs[logical_id] = IssueSpec(
            logical_id, titles[logical_id], bodies[logical_id], tuple(sorted(labels)), "ticket",
        )
        dependencies = ticket.get("depends_on")
        if not isinstance(dependencies, list):
            raise PublicationError(f"ticket dependencies are invalid for {logical_id}")
        core_edges.update((logical_id, blocker) for blocker in dependencies)

    skill_id = None
    additional_document = None
    additional = extension.get("additional_issue")
    if isinstance(additional, dict):
        manifest_key = additional.get("manifest_key")
        raw_issue = publication.get(manifest_key) if isinstance(manifest_key, str) else None
        if not isinstance(raw_issue, dict):
            raise PublicationError("declared additional issue manifest is unavailable")
        skill_id = raw_issue.get("logical_id")
        document = raw_issue.get("document")
        labels = additional.get("labels")
        if (
            not isinstance(skill_id, str) or not isinstance(document, str)
            or not isinstance(labels, list)
            or not all(isinstance(item, str) and item for item in labels)
        ):
            raise PublicationError("declared additional issue is invalid")
        additional_relative = (
            build_path.parent / document
        ).resolve().relative_to(root.resolve()).as_posix()
        source = approved_text(
            root, approved.lower(), additional_relative,
            f"approved {skill_id} document", report,
        )
        if source is None:
            raise PublicationError("; ".join(report.errors))
        lines = source.splitlines()
        title = lines[0][2:].strip() if lines and lines[0].startswith("# ") else ""
        body = render_template_body(
            source, repository, skill_id, plan_version, approved.lower(),
            report, f"approved {skill_id} document",
        )
        if not title or body is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        if extension.get("additional_title_must_be_unprefixed") and (
            isinstance(feature_prefix, str) and title.startswith(feature_prefix)
        ):
            raise PublicationError(
                "the declared additional issue title must remain unprefixed"
            )
        additional_evidence = inspect_issue_body(
            body, repository, skill_id, plan_version, approved.lower(), report,
            f"approved {skill_id} body",
        )
        if additional_evidence is None or report.errors:
            raise PublicationError("; ".join(report.errors))
        specs[skill_id] = IssueSpec(
            skill_id, title, body, tuple(sorted(labels)), "skill",
        )
        evidence[skill_id] = additional_evidence
        additional_document = root / additional_relative

    edges = set(core_edges)
    external_field = extension.get("external_edges_field")
    if isinstance(external_field, str):
        relations = publication.get(external_field)
        if not isinstance(relations, list):
            raise PublicationError("declared external blocker relations are invalid")
        for relation in relations:
            if not isinstance(relation, dict):
                raise PublicationError("external blocker relation is invalid")
            edges.add((
                relation.get("blocked_ticket_id"),
                relation.get("blocker_issue_id"),
            ))
    if any(blocked not in specs or blocker not in specs for blocked, blocker in edges):
        raise PublicationError("publication edge references an unknown logical identity")
    creatable = extension.get("creatable_labels", {})
    if not isinstance(creatable, dict) or any(
        not isinstance(value, (list, tuple)) or len(value) != 2
        or not all(isinstance(item, str) for item in value)
        for value in creatable.values()
    ):
        raise PublicationError("declared creatable label policy is invalid")
    extra_validator = extension.get("extra_validator")
    validator_path = (
        build_path.parent / extra_validator
        if isinstance(extra_validator, str) else None
    )
    return Context(
        root=root, build_path=build_path, publication_path=publication_path,
        discovery_path=root / ".aiur" / "build_orders" / f"{slug}.json",
        approved=approved.lower(), authority=authority.lower(),
        repository=repository, trusted_ref=trusted_ref, plan_version=plan_version,
        root_id=root_id, skill_id=skill_id, build=build, publication=publication,
        specs=specs, approved_evidence=evidence, expected_edges=edges,
        core_edges=core_edges,
        creatable_labels={
            key: (value[0], value[1]) for key, value in creatable.items()
        },
        reconciliation_comment=bool(extension.get("reconciliation_comment")),
        root_document=root / root_document_value,
        additional_document=additional_document,
        extra_validator=validator_path,
    )


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
