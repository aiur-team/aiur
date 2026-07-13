"""Temporary Git-backed planning packs used by publication validator tests."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
from pathlib import Path


FIXTURE_APPROVED = "f" * 40
EXPECTED_BODY_SHA = "<EXPECTED_BODY_SHA256>"
EXPECTED_COMMENT_SHA = "<EXPECTED_COMMENT_SHA256>"


class FixtureBase:
    def __init__(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object], pack_prefix: str = ".",
    ) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.pack = self.base / pack_prefix
        self.pack.mkdir(parents=True, exist_ok=True)
        self.companion_path = self.pack / "dashboard-companions.json"
        self.build_path = self.pack / "build-order.json"
        self.publication_path = self.pack / "publication.json"
        self.approved_commit: str | None = None
        self.github_repository = str(
            publication_data.get("repository", "example/repo")
        )
        values = copy.deepcopy((companion, build, publication_data))
        if self._needs_git(*values):
            source = self._approved_source(*values)
            self._write(*source)
            self._init_git()
            approved = self._head()
            self.approved_commit = approved
            values = tuple(_replace_approval(item, approved) for item in values)
            self._write(*values)
            self._fill_expected_receipts(*values, approved)
        self._write(*values)

    def _write(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object],
    ) -> None:
        (self.base / "tickets").mkdir(exist_ok=True)
        for ticket in build.get("tickets", []):
            if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
                continue
            document = ticket.get("document")
            if not isinstance(document, str):
                continue
            path = self.pack / document
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                f"# {ticket['id']} — {ticket.get('title')}\n", encoding="utf-8"
            )
        for ticket in companion.get("tickets", []):
            if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
                continue
            path = self.pack / str(ticket.get("document"))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(_ticket_text(ticket), encoding="utf-8")
        self.companion_path.write_text(json.dumps(companion), encoding="utf-8")
        self.build_path.write_text(json.dumps(build), encoding="utf-8")
        self.publication_path.write_text(json.dumps(publication_data), encoding="utf-8")
        repository = publication_data.get("repository", "example/repo")
        plan_version = publication_data.get("plan_version", 1)
        for key, title in (("root_issue", "Test root"), ("skill_issue", "Test skill")):
            issue = publication_data.get(key)
            if not isinstance(issue, dict):
                continue
            logical_id = issue.get("logical_id")
            document = issue.get("document")
            if not isinstance(logical_id, str) or not isinstance(document, str):
                continue
            path = self.pack / document
            path.parent.mkdir(parents=True, exist_ok=True)
            text = _template_text(title, logical_id, repository, plan_version)
            approved = publication_data.get("approved_planning_commit")
            if isinstance(approved, str):
                text = text.replace("<APPROVED_SHA>", approved)
            path.write_text(text, encoding="utf-8")

    def _approved_source(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object],
    ) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
        companion, build, publication_data = copy.deepcopy(
            (companion, build, publication_data)
        )
        companion["approved_planning_commit"] = None
        publication_data["approved_planning_commit"] = None
        for value in (companion, build, publication_data):
            value["github_reconciliation"] = None
        build["github_root"] = None
        for value in (companion, build):
            tickets = value.get("tickets")
            if isinstance(tickets, list):
                for ticket in tickets:
                    if isinstance(ticket, dict) and "github" in ticket:
                        ticket["github"] = None
        return companion, build, publication_data

    def _fill_expected_receipts(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object], approved: str,
    ) -> None:
        from publication_common import Report
        from publication_comment import pending_comment_evidence
        from publication_rendering import render_approved_pack

        report = Report()
        expected = render_approved_pack(
            build, companion, publication_data, self.build_path,
            self.companion_path, self.publication_path, approved, report,
        )
        if expected is not None:
            for value in (build, companion, publication_data):
                receipt = value.get("github_reconciliation")
                evidence = receipt.get("observed_body_evidence") if isinstance(receipt, dict) else None
                if not isinstance(evidence, dict):
                    continue
                for logical_id, observed in evidence.items():
                    if (
                        isinstance(observed, dict)
                        and observed.get("body_sha256") == EXPECTED_BODY_SHA
                        and logical_id in expected
                    ):
                        observed["body_sha256"] = expected[logical_id]["body_sha256"]
        receipt = publication_data.get("github_reconciliation")
        matches = receipt.get("root_reconciliation_comment_matches") if isinstance(receipt, dict) else None
        root = publication_data.get("root_issue")
        mappings = receipt.get("issue_mappings") if isinstance(receipt, dict) else None
        root_id = root.get("logical_id") if isinstance(root, dict) else None
        mapping = mappings.get(root_id) if isinstance(mappings, dict) else None
        if (
            isinstance(matches, list) and len(matches) == 1
            and isinstance(matches[0], dict)
            and matches[0].get("body_sha256") == EXPECTED_COMMENT_SHA
            and isinstance(root_id, str) and isinstance(mapping, dict)
            and isinstance(mapping.get("url"), str)
            and isinstance(mapping.get("repository"), str)
        ):
            comment = pending_comment_evidence(
                matches[0]["url"], root_id,
                int(publication_data.get("plan_version", 1)), approved,
                mapping["repository"], report,
            )
            if comment is not None:
                matches[0]["body_sha256"] = comment["body_sha256"]

    def _needs_git(self, *values: dict[str, object]) -> bool:
        return any(
            value.get("approved_planning_commit") is not None
            or value.get("github_reconciliation") is not None
            for value in values
        )

    def _init_git(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.base)], check=True)
        subprocess.run(
            ["git", "-C", str(self.base), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.base), "config", "user.name", "Test"],
            check=True,
        )
        subprocess.run(
            [
                "git", "-C", str(self.base), "remote", "add", "origin",
                f"https://github.com/{self.github_repository}.git",
            ],
            check=True,
        )
        subprocess.run(["git", "-C", str(self.base), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(self.base), "commit", "-qm", "approved pack"],
            check=True,
        )

    def _head(self) -> str:
        return subprocess.run(
            ["git", "-C", str(self.base), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def commit_materialized(self) -> str:
        subprocess.run(["git", "-C", str(self.base), "add", "-A"], check=True)
        subprocess.run(
            ["git", "-C", str(self.base), "commit", "-qm", "receipt"],
            check=True,
        )
        return self._head()

    def close(self) -> None:
        self.temp.cleanup()


def _replace_approval(value: object, approved: str) -> object:
    if isinstance(value, str):
        return value.replace(FIXTURE_APPROVED, approved)
    if isinstance(value, list):
        return [_replace_approval(item, approved) for item in value]
    if isinstance(value, dict):
        return {key: _replace_approval(item, approved) for key, item in value.items()}
    return value


def _template_text(
    title: str, logical_id: str, repository: object, plan_version: object,
) -> str:
    marker = json.dumps(
        {
            "schema": 2,
            "logical_id": logical_id,
            "plan_version": plan_version,
            "approved_planning_commit": "<APPROVED_SHA>",
        },
        separators=(",", ":"),
    )
    return (
        f"# {title}\n\n{logical_id}\n\n"
        f"[`<APPROVED_SHA>`](https://github.com/{repository}/commit/<APPROVED_SHA>)\n\n"
        f"<!-- aiur-planning-issue\n{marker}\n-->\n"
    )


def _ticket_text(ticket: dict[str, object]) -> str:
    dependencies = ticket.get("depends_on", []) + ticket.get("external_blockers", [])
    dependency_text = ", ".join(dependencies) if dependencies else "none"
    gates = ticket.get("external_gate_ids", [])
    gate_text = f"**External gates:** {', '.join(gates)}\n\n" if gates else ""
    return (
        f"# {ticket['id']} — {ticket.get('title')}\n\n"
        "**Kind:** executable\n\n"
        f"**Complexity:** {ticket.get('complexity_points')} — Test\n\n"
        f"**Depends on:** {dependency_text}\n\n"
        f"{gate_text}"
        f"**Requirements:** {ticket.get('requirement_ref')}\n\n"
        "**Build Order membership:** none — standalone dashboard companion\n"
    )
