#!/usr/bin/env python3
"""Focused contract tests for newsletter collection (standard library only).

This remains one fixture-only collector suite because its source seams and
snapshot contract are shared; CI runs this file as one bounded Python command.
"""
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
from allocation_sources import allocation_evidence

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
        return {n: issue(n, ("feature:watch", "agent:parked")) if n == 99 else issue(n) for n in numbers}


def daemon(args):
    return json.dumps({"sources": {"units_catalog": {"state": "available", "observed_at": STAMP}},
                       "data": {"view": {"rows": [
                           {"identity": {"owner": "owner", "repository": "repo", "identifier": "1"},
                            "lifecycle": "running"},
                           {"identity": {"owner": "owner", "repository": "repo", "identifier": "99"},
                            "lifecycle": "completed"}]}},
                       "auxiliary": {"running_build": {"sha": "b" * 40, "built_at": STAMP}}})


class CollectorTest(unittest.TestCase):
    def test_allocation_evidence_is_unavailable_without_telemetry_and_keeps_reader_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = allocation_evidence(root, NOW, {}, telemetry_root=root / "missing")
        self.assertEqual(set(result), {"pc", "nuc"})
        for machine in ("pc", "nuc"):
            self.assertEqual(set(result[machine]), {"turns", "intake", "feature_supply"})
            for section in result[machine].values():
                self.assertEqual(section["state"], "unavailable")
                self.assertIs(section["complete"], False)
                self.assertIsNone(section["records"])

    def test_allocation_evidence_matches_metric_reader_record_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_dir = root / "telemetry"
            log_dir.mkdir()
            rows = [
                {"kind": "run_context", "timestamp": iso(NOW - timedelta(days=7, minutes=1)), "attributes": {}},
                {"kind": "lifecycle", "timestamp": iso(NOW - timedelta(minutes=2)),
                 "attributes": {"ticket": "42", "attempt_id": "attempt", "operation_id": "turn:1",
                                "event": "implement", "boundary": "start"}},
                {"kind": "lifecycle", "timestamp": iso(NOW - timedelta(minutes=1)),
                 "attributes": {"ticket": "42", "attempt_id": "attempt", "operation_id": "turn:1",
                                "event": "implement", "boundary": "end"}},
                {"kind": "feature_supply", "timestamp": iso(NOW),
                 "attributes": {"event": "interval", "event_key": "supply:1",
                                "interval_start_ms": int((NOW - timedelta(days=1)).timestamp() * 1000),
                                "interval_end_ms": int(NOW.timestamp() * 1000),
                                "feature_starved_slot_minutes": 1440.0,
                                "non_feature_during_starvation_minutes": 0.0, "observed_minutes": 1440.0}},
            ]
            (log_dir / "telemetry.ndjson").write_text("".join(json.dumps(row) + "\n" for row in rows))
            result = allocation_evidence(root, NOW, {42: {"labels": ["feature:newsletter"], "title": "Newsletter"}}, telemetry_root=log_dir)
        block = result["pc"]["turns"]
        self.assertEqual((block["state"], block["complete"]), ("available", True))
        row = block["records"][0]
        self.assertEqual(set(row), {"attempt_id", "number", "phase", "started_at", "ended_at", "labels", "title"})
        self.assertEqual((row["number"], row["phase"], row["labels"]), (42, "implement", ["feature:newsletter"]))
        self.assertEqual(result["pc"]["intake"]["state"], "unavailable")
        supply = result["pc"]["feature_supply"]
        self.assertEqual((supply["state"], supply["complete"]), ("available", True))
        self.assertEqual(set(supply["records"][0]), {"event_id", "kind", "attributes"})

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
        self.assertEqual(result["allocation"]["units"]["paused"]["feature"], 0)
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

    def test_repo_discovery_uses_local_git_without_unrecorded_graphql(self):
        for remote, expected in (("https://github.com/owner/repo.git", "owner/repo"),
                                 ("git@github.com:second/project.git", "second/project")):
            with patch.object(collect, "command", return_value=remote) as run:
                self.assertEqual(collect.discover_repo(), expected)
            self.assertEqual(run.call_args.args[0], ["git", "-C", str(Path.cwd()), "remote", "get-url", "origin"])
        with patch.object(collect, "command", return_value="https://example.invalid/owner/repo.git"):
            with self.assertRaisesRegex(RuntimeError, "specify --repo"):
                collect.discover_repo()

    def test_large_program_is_paged_per_phase_and_deduplicated(self):
        requests = []
        oversized = False
        def run(args):
            expression = next((v[2:] for v in args if v.startswith("q=")), None)
            if expression is None:
                data = {"repository": {"labels": {
                    "nodes": [{"name": "phase:1"}, {"name": "phase:2"}],
                    "pageInfo": {"hasNextPage": False}}}}
            else:
                cursor = next(v[7:] for v in args if v.startswith("cursor="))
                requests.append((expression, cursor))
                rows = []
                if "is:issue" in expression:
                    # 1,300 unique tickets; 100 belong to both 700-ticket phases.
                    if expression.endswith('label:"phase:1"'):
                        rows = [issue(n) for n in range(1, 701)]
                    elif expression.endswith('label:"phase:2"'):
                        rows = [issue(n, ("phase:2",)) for n in range(601, 1301)]
                    else:
                        rows = [issue(n) for n in range(1, 1301)]
                offset = 0 if cursor == "null" else int(cursor)
                more = offset + 100 < len(rows)
                data = {"search": {"issueCount": 1001 if oversized and rows else len(rows),
                                   "nodes": rows[offset:offset+100],
                                   "pageInfo": {"hasNextPage": more, "endCursor": str(offset + 100) if more else None}}}
            return json.dumps({"data": {**data, "rateLimit": {"cost": 1}}})
        def empty_daemon(args):
            data = json.loads(daemon(args))
            data["data"]["view"]["rows"] = []
            return json.dumps(data)
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, GitHub("owner/repo", run), empty_daemon)
            self.assertEqual(result["sources"]["github_program"]["state"], "available")
            self.assertEqual([t["number"] for t in result["program"]["tickets"]], list(range(1, 1301)))
            for phase in (1, 2):
                self.assertEqual([c for q, c in requests if q.endswith(f'label:"phase:{phase}"')],
                                 ["null", "100", "200", "300", "400", "500", "600"])
            self.assertEqual(result["github_cost"]["graphql_points"], 16)
            self.assertEqual(result["github_cost"]["request_ceiling"], 40)
            oversized = True
            result = collect.collect("owner/repo", Path(tmp), NOW, GitHub("owner/repo", run), empty_daemon)
            self.assertIsNone(result["program"]["tickets"])
            self.assertEqual(result["sources"]["github_program"]["state"], "unavailable")
            self.assertIn("1000-result", result["sources"]["github_program"]["reason"])

    def test_failed_instance_does_not_publish_partial_ticket_lifecycles(self):
        class TwoTickets(FakeGitHub):
            def search(self, expression, fields, kind):
                return [issue(1), issue(2)] if kind == "Issue" else []
        def partial(args):
            data = json.loads(daemon(args))
            rows = data["data"]["view"]["rows"]
            rows[1]["identity"]["identifier"] = "2"
            if "--instance" in args:
                rows[1]["lifecycle"] = "running"
                rows[0]["lifecycle"] = "waiting"  # Conflicts after reading #2.
                rows.reverse()
            else:
                rows[1]["lifecycle"] = None  # Fails after reading #1.
            return json.dumps(data)
        with tempfile.TemporaryDirectory() as tmp:
            result = collect.collect("owner/repo", Path(tmp), NOW, TwoTickets(), partial)
            self.assertEqual([t["lifecycle"] for t in result["program"]["tickets"]], [None, None])
            self.assertEqual(result["sources"]["units_local"]["state"], "unavailable")
            def conflicting(args):
                return partial(args) if "--instance" in args else daemon(args)
            result = collect.collect("owner/repo", Path(tmp), NOW, TwoTickets(), conflicting, ["second"])
            self.assertEqual([t["lifecycle"] for t in result["program"]["tickets"]], ["running", None])
            self.assertEqual(result["sources"]["units_instance_1"]["state"], "unavailable")
            self.assertIn("disagree", result["sources"]["units_instance_1"]["reason"])
            self.assertIsNone(result["allocation"]["units"])

    def test_budget_and_incomplete_cost(self):
        gh = GitHub("owner/repo", lambda args: json.dumps({"data": {"rateLimit": {"cost": 1}}}))
        for _ in range(40):
            gh.query("query { rateLimit { cost } }")
        with self.assertRaisesRegex(RuntimeError, "ceiling"):
            gh.query("query { rateLimit { cost } }")
        self.assertEqual(gh.calls, 40)
        costly = GitHub("owner/repo", lambda args: json.dumps({"data": {"rateLimit": {"cost": 2}}}))
        for _ in range(24):
            costly.query("query { rateLimit { cost } }")
        with self.assertRaisesRegex(RuntimeError, "point budget"):
            costly.query("query { rateLimit { cost } }")
        self.assertEqual(costly.cost, 48)
        unreported = GitHub("owner/repo", lambda args: json.dumps({"data": {}}))
        for _ in range(24):
            unreported.query("query { rateLimit { cost } }")
        with self.assertRaisesRegex(RuntimeError, "point budget"):
            unreported.query("query { rateLimit { cost } }")
        self.assertFalse(unreported.cost_complete)
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
