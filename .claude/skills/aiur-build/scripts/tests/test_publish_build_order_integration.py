"""Canonical example publication through the skill-owned default driver."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
REFERENCES = SCRIPT_DIR.parent / "references"
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publish_build_order import load_driver  # noqa: E402


class FakeGitHub:
    def __init__(self, repository: str, authority: str, labels: set[str]) -> None:
        self.repository = repository
        self.authority = authority
        self.labels = labels
        self.issues: dict[int, dict] = {}
        self.parents: dict[int, int | None] = {}
        self.children: dict[int, set[int]] = {}
        self.blockers: dict[int, set[int]] = {}
        self.next_number = 1

    def request(self, method, path, payload=None, *, allow_404=False):
        base = f"repos/{self.repository}"
        if method == "GET" and path.startswith(f"{base}/git/ref/"):
            return {
                "ref": "refs/heads/build-order-research",
                "object": {"type": "commit", "sha": self.authority},
            }
        if method == "GET" and path == f"{base}/labels?per_page=100&page=1":
            return [{"name": label} for label in sorted(self.labels)]
        if method == "GET" and path == f"{base}/issues?state=all&per_page=100&page=1":
            return [copy.deepcopy(value) for value in self.issues.values()]
        if method == "POST" and path == f"{base}/issues":
            number = self.next_number
            self.next_number += 1
            raw = {
                "id": 1000 + number,
                "number": number,
                "node_id": f"NODE_{number}",
                "html_url": f"https://github.com/{self.repository}/issues/{number}",
                "title": payload["title"],
                "body": payload["body"],
                "labels": [{"name": label} for label in payload["labels"]],
                "state": "open",
                "locked": False,
                "updated_at": "2026-07-13T00:00:00Z",
            }
            self.issues[number] = raw
            self.parents[number] = None
            self.children[number] = set()
            self.blockers[number] = set()
            return copy.deepcopy(raw)
        issue_prefix = f"{base}/issues/"
        if path.startswith(issue_prefix):
            suffix = path.removeprefix(issue_prefix)
            number_text = suffix.split("/", 1)[0]
            if not number_text.isdigit():
                raise AssertionError((method, path, payload))
            number = int(number_text)
            tail = suffix.removeprefix(number_text)
            if method == "GET" and not tail:
                return copy.deepcopy(self.issues[number])
            if method == "GET" and tail == "/parent":
                parent = self.parents[number]
                if parent is None:
                    return None
                return self._relationship(parent)
            if method == "GET" and tail == "/sub_issues?per_page=100&page=1":
                return [self._relationship(value) for value in sorted(self.children[number])]
            if method == "GET" and tail == "/dependencies/blocked_by?per_page=100&page=1":
                return [self._relationship(value) for value in sorted(self.blockers[number])]
            if method == "POST" and tail == "/sub_issues":
                child = self._number_for_database_id(payload["sub_issue_id"])
                self.children[number].add(child)
                self.parents[child] = number
                return {}
            if method == "POST" and tail == "/dependencies/blocked_by":
                blocker = self._number_for_database_id(payload["issue_id"])
                self.blockers[number].add(blocker)
                return {}
        raise AssertionError((method, path, payload, allow_404))

    def _number_for_database_id(self, database_id: int) -> int:
        return next(
            number for number, raw in self.issues.items()
            if raw["id"] == database_id
        )

    def _relationship(self, number: int) -> dict:
        raw = self.issues[number]
        return {
            "number": number,
            "node_id": raw["node_id"],
            "html_url": raw["html_url"],
        }


class CanonicalPublicationIntegrationTests(unittest.TestCase):
    def test_example_structure_materializes_and_reconciles_without_pack_modules(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            pack = root / "docs/build-orders/example"
            tickets = pack / "example-tickets"
            tickets.mkdir(parents=True)
            build = json.loads(
                (REFERENCES / "build-order.example.json").read_text(encoding="utf-8")
            )
            publication = json.loads(
                (REFERENCES / "publication.example.json").read_text(encoding="utf-8")
            )
            publication["mutation_repositories"] = [build["repository"]]
            publication["reference_only_issue_urls"] = [
                f"https://github.com/{build['repository']}/issues/123"
            ]
            build_path = pack / "build-order.json"
            publication_path = pack / "publication.json"
            build_path.write_text(json.dumps(build), encoding="utf-8")
            publication_path.write_text(json.dumps(publication), encoding="utf-8")
            for ticket in build["tickets"]:
                source = REFERENCES / ticket["document"]
                (pack / ticket["document"]).write_text(
                    source.read_text(encoding="utf-8"), encoding="utf-8",
                )
            (pack / "example-design-evidence.md").write_text(
                (REFERENCES / "example-design-evidence.md").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            root_document = pack / "root-issue.md"
            template = (
                "# BO: Example Build Order\n\n"
                "[`<APPROVED_SHA>`](https://github.com/example/repo/commit/<APPROVED_SHA>)\n\n"
                "<!-- aiur-planning-issue\n"
                '{"schema":2,"logical_id":"example/repo:operator-dashboard",'
                '"plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}\n'
                "-->\n"
            )
            root_document.write_text(template, encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "test@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Test"],
                check=True,
            )
            subprocess.run(["git", "-C", str(root), "add", "docs"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "approved"], check=True,
            )
            approved = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"],
                check=True, capture_output=True, text=True,
            ).stdout.strip()
            root_document.write_text(
                template.replace("<APPROVED_SHA>", approved), encoding="utf-8",
            )
            driver = load_driver(
                build_path, publication_path, approved, approved,
            )
            labels = {
                label for spec in driver.context.specs.values()
                for label in spec.labels
            }
            client = FakeGitHub(build["repository"], approved, labels)
            driver.client = client
            result = driver.apply()
            self.assertEqual("apply-pending", result["mode"])
            self.assertNotIn("pending_comment", result)
            materialized = json.loads(build_path.read_text(encoding="utf-8"))
            self.assertEqual(2, len(materialized["tickets"]))
            self.assertEqual(2, len(materialized["github_reconciliation"]["member_ticket_ids"]))
            self.assertEqual(1, len(materialized["github_reconciliation"]["dependency_edges"]))
            root_number = materialized["github_root"]["number"]
            self.assertEqual(2, len(client.children[root_number]))
            discovery = root / ".aiur" / "build_orders" / "operator-dashboard.json"
            self.assertEqual(build_path.read_text(encoding="utf-8"), discovery.read_text(encoding="utf-8"))
            self.assertIn(str(discovery), result["files_written"])


if __name__ == "__main__":
    unittest.main()
