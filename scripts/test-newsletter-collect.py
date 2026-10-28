#!/usr/bin/env python3
"""Focused contract tests for newsletter collection (standard library only)."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "newsletter"))
import collect
from classification import classify
from github import GitHub
from local_sources import iso

NOW = datetime.now(timezone.utc).replace(microsecond=0)
STAMP = iso(NOW)


def issue(number=1, labels=("phase:1", "feature:watch")):
    return {"number": number, "title": "Ship composer", "state": "CLOSED", "stateReason": "COMPLETED",
            "createdAt": iso(NOW - timedelta(days=2)), "closedAt": STAMP,
            "labels": {"nodes": [{"name": x} for x in labels], "pageInfo": {"hasNextPage": False}}}


class FakeGitHub:
    cost, calls, cost_complete = 4, 4, True

    def phase_labels(self):
        return ["phase:1"]

    def search(self, expression, fields, kind):
        if kind == "Issue":
            return [issue()]
        return [{"number": 2, "title": "Ship composer", "body": "Closes #1", "headRefName": "topic",
                 "mergedAt": STAMP, "mergeCommit": {"oid": "a" * 40},
                 "closingIssuesReferences": {"nodes": [{"number": 1}]}}]

    def issues(self, numbers):
        return {n: issue(n) for n in numbers}


def daemon(args):
    return json.dumps({"sources": {"units_catalog": {"state": "available", "observed_at": STAMP}},
                       "data": {"view": {"rows": [
                           {"identity": {"owner": "owner", "repository": "repo", "identifier": "1"},
                            "lifecycle": "running"}]}},
                       "auxiliary": {"running_build": {"sha": "b" * 40, "built_at": STAMP}}})


class CollectorTest(unittest.TestCase):
    def test_schema_real_sources_and_cross_machine_deduplication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "meta").mkdir()
            (root / "meta" / (NOW.strftime("%Y-%m-%dT%H-%M-%SZ") + "-check.md")).write_text(
                "## Bottleneck\n\nWaiting on review.\n\nFull log ignored.\nfeature_share=95%\n")
            history = root / "executor" / "run" / "history.ndjson"
            history.parent.mkdir(parents=True)
            history.write_text(json.dumps({"at": STAMP, "outcome": "no-action", "reason": "quiet", "run_id": "run"}) + "\n")
            result = collect.collect("owner/repo", root, NOW, FakeGitHub(), daemon, ["second"])
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["window_start"], iso(NOW - timedelta(hours=24)))
        self.assertEqual(result["window_end"], STAMP)
        self.assertEqual(result["repo"], "owner/repo")
        ticket = result["program"]["tickets"][0]
        self.assertEqual((ticket["state"], ticket["state_reason"], ticket["class"], ticket["lifecycle"]),
                         ("closed", "COMPLETED", "feature", "running"))
        self.assertTrue(ticket["mobile"])
        self.assertEqual(ticket["lane"], "feature:watch")
        self.assertEqual(result["allocation"]["units"]["running"]["feature"], 1)
        self.assertIsNone(result["allocation"]["agent_hours"])
        self.assertEqual(result["merges"][0]["closing_issue"], 1)
        self.assertEqual(result["merges"][0]["merge_sha"], "a" * 40)
        self.assertEqual(result["running_build"]["instance_1"]["sha"], "b" * 40)
        self.assertEqual(result["meta"][0]["bottleneck"], "Waiting on review.")
        self.assertEqual(result["meta"][0]["feature_share"], ["feature_share=95%"])
        self.assertEqual(result["executor_actions"][0]["reason"], "quiet")
        self.assertEqual(result["github_cost"]["graphql_points"], 4)
        self.assertTrue(all(set(s) == {"state", "observed_at", "reason"} for s in result["sources"].values()))

    def test_unavailable_and_stale_sources_do_not_become_zero(self):
        def stale(args):
            data = json.loads(daemon(args))
            data["sources"]["units_catalog"]["observed_at"] = iso(NOW - timedelta(hours=1))
            return json.dumps(data)
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, FakeGitHub(), stale)
        self.assertEqual(result["sources"]["meta"]["state"], "unavailable")
        self.assertTrue(result["sources"]["meta"]["reason"])
        self.assertEqual(result["sources"]["units_local"]["state"], "stale")
        self.assertIsNone(result["program"]["tickets"][0]["lifecycle"])
        self.assertIsNone(result["allocation"]["units"])
        self.assertIsNone(result["executor_actions"])
        def missing_build(args):
            data = json.loads(daemon(args))
            data["auxiliary"]["running_build"] = {"sha": "unknown", "built_at": None}
            return json.dumps(data)
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, FakeGitHub(), missing_build)
        self.assertEqual(result["sources"]["running_build_local"]["state"], "unavailable")
        def unknown(args):
            data = json.loads(daemon(args))
            data["data"]["view"]["rows"][0]["lifecycle"] = None
            return json.dumps(data)
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, FakeGitHub(), unknown)
        self.assertEqual(result["sources"]["units_local"]["state"], "unavailable")
        self.assertIsNone(result["allocation"]["units"])
        with tempfile.TemporaryDirectory() as tmp:
            def failed(args):
                raise RuntimeError("daemon unavailable")
            result = collect.collect("owner/repo", Path(tmp), NOW, FakeGitHub(), failed)
            output = collect.write_snapshot(result, Path(tmp))
            self.assertEqual(json.loads(output.read_text())["sources"]["units_local"]["state"], "unavailable")
            self.assertIsNone(result["running_build"]["local"]["sha"])

    def test_atomic_same_day_overwrite_and_failed_replace_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = {"captured_at": STAMP, "value": "first"}
            path = collect.write_snapshot(old, root)
            new = {"captured_at": STAMP, "value": "second"}
            replace = collect.os.replace
            def observe(source, target):
                self.assertEqual(json.loads(path.read_text()), old)
                self.assertEqual(json.loads(Path(source).read_text()), new)
                self.assertEqual(Path(source).parent, path.parent)
                replace(source, target)
            with patch.object(collect.os, "replace", side_effect=observe):
                self.assertEqual(collect.write_snapshot(new, root), path)
            self.assertEqual(json.loads(path.read_text()), new)
            with patch.object(collect.os, "replace", side_effect=OSError("disk failure")):
                with self.assertRaises(OSError):
                    collect.write_snapshot(old, root)
            self.assertEqual(json.loads(path.read_text()), new)
            self.assertEqual(list(root.iterdir()), [path])

    def test_shared_classification_matches_shell_for_fixture(self):
        for text, expected in [("feature:mail flaky test", "feature"), ("build-lane:watch", "feature"),
                               ("MP-E8-C11 Ship", "feature"), ("repair CI", "test_ci"),
                               ("coverage", "test_ci"), ("docs", "other")]:
            with self.subTest(text=text):
                shell = subprocess.check_output(["bash", str(ROOT / ".claude/skills/aiur-meta/scripts/feature-share.sh"),
                                                 "--classify", text], text=True)
                self.assertEqual(classify(text), expected)
                self.assertEqual(shell, expected)
        with tempfile.TemporaryDirectory() as tmp:
            portable = Path(tmp)
            for name in ("feature-share.sh", "classification.py"):
                shutil.copyfile(ROOT / ".claude/skills/aiur-meta/scripts" / name, portable / name)
            result = subprocess.check_output(["bash", str(portable / "feature-share.sh"), "--self-test"],
                                             cwd=portable, text=True,
                                             env={**os.environ, "GIT_CEILING_DIRECTORIES": str(portable.parent)})
            self.assertIn("feature-share self-test: ok", result)

    def test_cursor_pages_stop_and_repeated_cursor_fails(self):
        cursors = []
        def run(args):
            cursor = next(v for v in args if v.startswith("cursor="))
            cursors.append(cursor)
            end = "cursor-two" if cursor == "cursor=null" else None
            page = {"issueCount": 2, "nodes": [{"number": len(cursors)}],
                    "pageInfo": {"hasNextPage": end is not None, "endCursor": end}}
            return json.dumps({"data": {"search": page, "rateLimit": {"cost": 1}}})
        gh = GitHub("owner/repo", run)
        self.assertEqual(gh.search("is:issue", "number", "Issue"), [{"number": 1}, {"number": 2}])
        self.assertEqual(cursors, ["cursor=null", "cursor=cursor-two"])
        self.assertEqual(gh.cost, 2)
        self.assertEqual(gh.calls, 2)
        with self.assertRaisesRegex(RuntimeError, "repeated"):
            list(gh.pages(lambda c: {"nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "same"}}))

    def test_budget_and_incomplete_cost(self):
        gh = GitHub("owner/repo", lambda args: json.dumps({"data": {"rateLimit": {"cost": 1}}}))
        for _ in range(24):
            gh.query("query { rateLimit { cost } }")
        with self.assertRaisesRegex(RuntimeError, "ceiling"):
            gh.query("query { rateLimit { cost } }")
        self.assertEqual(gh.calls, 24)
        failed = GitHub("owner/repo", lambda args: "invalid json")
        with self.assertRaises(ValueError):
            failed.query("query { rateLimit { cost } }")
        self.assertFalse(failed.cost_complete)

    def test_github_failure_still_writes_snapshot(self):
        gh = GitHub("owner/repo", lambda args: json.dumps({"data": None, "errors": [{"message": "offline"}]}))
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, gh, daemon)
            path = collect.write_snapshot(result, Path(tmp))
            saved = json.loads(path.read_text())
        self.assertIsNone(saved["program"]["tickets"])
        self.assertIsNone(saved["merges"])
        self.assertIsNone(saved["github_cost"]["graphql_points"])
        self.assertEqual(saved["sources"]["github_phases"]["state"], "unavailable")

    def test_legacy_meta_filename_and_window_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "meta").mkdir()
            path = root / "meta" / (NOW.strftime("%Y%m%dT%H%M%SZ") + "-hourly.md")
            path.write_text("## Bottleneck\n\nBuild gate is full.\n\n## Feature share\n- 24 h: 90%\n## Other\nFull log omitted.\n")
            old = NOW - timedelta(days=2)
            (path.parent / (old.strftime("%Y-%m-%dT%H%MZ") + "-hourly.md")).write_text("Old log")
            result = collect.collect("owner/repo", root, NOW, FakeGitHub(), daemon)
        self.assertEqual(len(result["meta"]), 1)
        self.assertEqual(result["meta"][0]["timestamp"], STAMP)
        self.assertEqual(result["meta"][0]["bottleneck"], "Build gate is full.")
        self.assertEqual(result["meta"][0]["feature_share"], ["## Feature share", "- 24 h: 90%"])



if __name__ == "__main__":
    unittest.main(verbosity=2)
