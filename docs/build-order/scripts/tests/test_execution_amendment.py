from __future__ import annotations

import copy
import hashlib
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from execution_amendment import (  # noqa: E402
    EXPECTED_LANES,
    EXPECTED_AFFECTED_IDS,
    EXPECTED_LANE_MAPPING_SHA256,
    EXPECTED_POLICY,
    POLICY_AUTHORITY_COMMIT,
    POLICY_AUTHORITY_DOCUMENT,
    POLICY_AUTHORITY_DOCUMENT_SHA256,
    baseline_fingerprints,
    canonical_sha256,
    decision_sha256,
    render_authorization_comment,
    render_ticket_amendment_comment,
    validate_amendment_schema,
    validate_policy_authority_source,
)
from execution_amendment_live import (  # noqa: E402
    ExecutionSnapshot,
    compare_execution_snapshot,
    verify_live_execution_amendment,
)
from publication_common import Report  # noqa: E402
from publication_live_graph import _mapping_tuple  # noqa: E402
from publication_receipt_authority import ReceiptAuthority  # noqa: E402


PACK = SCRIPT_DIR.parent
PUBLICATION_RECEIPT = "b8db1794c57ba01bd724cc44b8d4ee6de0b79cad"
AUTHOR = "its-everdred"


def authority() -> ReceiptAuthority:
    build = json.loads((PACK / "build-order.json").read_text(encoding="utf-8"))
    publication = json.loads((PACK / "publication.json").read_text(encoding="utf-8"))
    root_comment = publication["github_reconciliation"][
        "root_reconciliation_comment_matches"
    ][0]["url"]
    return ReceiptAuthority(
        repository=build["repository"],
        root_id=build["build_order_id"],
        plan_version=build["plan_version"],
        approved_commit=publication["approved_planning_commit"],
        root_issue_url=build["github_root"]["url"],
        root_comment_url=root_comment,
        trusted_repository_ref=publication["trusted_repository_ref"],
        receipt_manifests={
            "build-order.json": build,
            "publication.json": publication,
        },
    )


def amendment(
    auth: ReceiptAuthority,
    *,
    completed_before: set[str] | None = None,
) -> dict:
    build = auth.receipt_manifests["build-order.json"]
    tickets = {item["id"]: item for item in build["tickets"]}
    completed = (
        set(completed_before)
        if completed_before is not None
        else set(tickets) - EXPECTED_AFFECTED_IDS
    )
    affected = set(tickets) - completed
    report = Report()
    baseline = baseline_fingerprints(build, report)
    if report.errors or baseline is None:
        raise AssertionError(report.errors)
    value = {
        "schema_version": 1,
        "amendment_id": "DEC-015",
        "build_order_id": auth.root_id,
        "plan_version": auth.plan_version,
        "publication_receipt_commit": PUBLICATION_RECEIPT,
        "recorded_at": "2026-07-15T18:00:00Z",
        "policy_authority": {
            "commit": POLICY_AUTHORITY_COMMIT,
            "document": POLICY_AUTHORITY_DOCUMENT,
            "document_sha256": POLICY_AUTHORITY_DOCUMENT_SHA256,
        },
        "baseline": baseline,
        "policy": copy.deepcopy(EXPECTED_POLICY),
        "lanes": copy.deepcopy(EXPECTED_LANES),
        "lane_mapping_sha256": EXPECTED_LANE_MAPPING_SHA256,
        "affected_ticket_ids": sorted(affected),
        "completed_before_amendment_ticket_ids": sorted(completed),
        "authorized_comment_authors": [AUTHOR],
        "decision_sha256": None,
        "authorization_comment": None,
        "ticket_amendment_comments": {},
    }
    value["decision_sha256"] = decision_sha256(value)
    root_body = render_authorization_comment(value)
    value["authorization_comment"] = {
        "url": f"{build['github_root']['url']}#issuecomment-900001",
        "body_sha256": hashlib.sha256(root_body.encode()).hexdigest(),
        "author_login": AUTHOR,
    }
    for index, logical_id in enumerate(sorted(affected), 900_100):
        body = render_ticket_amendment_comment(value, logical_id)
        value["ticket_amendment_comments"][logical_id] = {
            "url": f"{tickets[logical_id]['github']['url']}#issuecomment-{index}",
            "body_sha256": hashlib.sha256(body.encode()).hexdigest(),
            "author_login": AUTHOR,
        }
    return value


def snapshot(auth: ReceiptAuthority, value: dict) -> ExecutionSnapshot:
    build = auth.receipt_manifests["build-order.json"]
    publication = auth.receipt_manifests["publication.json"]
    receipt = build["github_reconciliation"]
    tickets = {item["id"]: item for item in build["tickets"]}
    completed = set(value["completed_before_amendment_ticket_ids"])
    mappings = {auth.root_id: build["github_root"]}
    mappings.update({logical_id: item["github"] for logical_id, item in tickets.items()})
    issues = {}
    for logical_id, mapping in mappings.items():
        is_completed = logical_id in completed
        issues[logical_id] = json.dumps(
            {
                "mapping": mapping,
                "title": receipt["observed_issue_titles"][logical_id],
                "body_sha256": receipt["observed_body_evidence"][logical_id][
                    "body_sha256"
                ],
                "labels": sorted(receipt["observed_labels"][logical_id]),
                "state": "CLOSED" if is_completed else "OPEN",
                "state_reason": "completed" if is_completed else None,
                "locked": False,
                "updated_at": "2026-07-15T18:00:01Z",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    expected_comments = {auth.root_id: value["authorization_comment"]}
    expected_comments.update(value["ticket_amendment_comments"])
    comments = {}
    for logical_id, evidence in expected_comments.items():
        body = (
            render_authorization_comment(value)
            if logical_id == auth.root_id
            else render_ticket_amendment_comment(value, logical_id)
        )
        record = {
            "url": evidence["url"],
            "body": body,
            "body_sha256": evidence["body_sha256"],
            "author_login": evidence["author_login"],
            "author_association": "OWNER",
            "updated_at": "2026-07-15T18:00:01Z",
        }
        comments[logical_id] = json.dumps(
            {"exact": record, "marked": [record]},
            sort_keys=True,
            separators=(",", ":"),
        )
    internal = {
        (logical_id, dependency)
        for logical_id, ticket in tickets.items()
        for dependency in ticket["depends_on"]
    }
    external = {
        (item["blocked_ticket_id"], item["blocker_issue_id"])
        for item in publication["external_blocker_relations"]
    }
    skill_id = publication["skill_issue"]["logical_id"]
    skill_mapping = publication["github_reconciliation"]["issue_mappings"][skill_id]
    return ExecutionSnapshot(
        issues=tuple(sorted(issues.items())),
        auxiliary_issues=((skill_id, json.dumps(
            {
                "mapping": skill_mapping,
                "state": "OPEN",
                "state_reason": None,
                "locked": False,
            },
            sort_keys=True,
            separators=(",", ":"),
        )),),
        marker_matches=tuple(
            (logical_id, (_mapping_tuple(mapping),))
            for logical_id, mapping in sorted(mappings.items())
        ),
        root_members=tuple(sorted(tickets)),
        parents=tuple(sorted(
            [(auth.root_id, None), *[(logical_id, auth.root_id) for logical_id in tickets]]
        )),
        nested_subissues=tuple((logical_id, ()) for logical_id in sorted(tickets)),
        internal_edges=tuple(sorted(internal)),
        external_edges=tuple(sorted(external)),
        comments=tuple(sorted(comments.items())),
    )


class ExecutionAmendmentSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.authority = authority()
        self.amendment = amendment(self.authority)

    def validate(self, value=None, auth=None) -> Report:
        report = Report()
        validate_amendment_schema(
            value or self.amendment, auth or self.authority, report,
        )
        return report

    def test_future_fixture_is_valid_without_live_state_constants(self) -> None:
        report = self.validate()
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def test_baseline_fingerprints_are_exact_54_and_105(self) -> None:
        baseline = self.amendment["baseline"]
        self.assertEqual(54, baseline["member_count"])
        self.assertEqual(105, baseline["dependency_edge_count"])

    def test_lane_partition_and_policy_cannot_drift(self) -> None:
        for mutate, expected in (
            (
                lambda value: value["lanes"]["L1"].append("BO-001"),
                "authorized five-lane map",
            ),
            (
                lambda value: value["policy"].update({"target_ref": "refs/heads/main"}),
                "exact develop-head policy",
            ),
        ):
            with self.subTest(expected=expected):
                value = copy.deepcopy(self.amendment)
                mutate(value)
                joined = "\n".join(self.validate(value).errors)
                self.assertIn(expected, joined)

    def test_policy_authority_commit_and_document_hash_are_exact(self) -> None:
        source_report = Report()
        validate_policy_authority_source(
            PACK / "execution-amendment.json", self.amendment, source_report,
        )
        self.assertEqual([], source_report.errors)
        for field, replacement in (
            ("commit", "0" * 40),
            ("document_sha256", "0" * 64),
        ):
            with self.subTest(field=field):
                value = copy.deepcopy(self.amendment)
                value["policy_authority"][field] = replacement
                value["decision_sha256"] = decision_sha256(value)
                joined = "\n".join(self.validate(value).errors)
                self.assertIn("policy_authority must equal the supplied receipt", joined)

    def test_member_partitions_are_complete_and_lane_members_are_affected(self) -> None:
        value = copy.deepcopy(self.amendment)
        value["affected_ticket_ids"].remove("BO-007")
        value["completed_before_amendment_ticket_ids"].append("BO-007")
        value["completed_before_amendment_ticket_ids"].sort()
        value["ticket_amendment_comments"].pop("BO-007")
        value["decision_sha256"] = decision_sha256(value)
        joined = "\n".join(self.validate(value).errors)
        self.assertIn("all five lane members", joined)

    def test_comment_evidence_is_rendered_bound_and_unique(self) -> None:
        value = copy.deepcopy(self.amendment)
        value["ticket_amendment_comments"]["BO-003"]["body_sha256"] = "0" * 64
        joined = "\n".join(self.validate(value).errors)
        self.assertIn("canonical rendered comment", joined)

        value = copy.deepcopy(self.amendment)
        value["ticket_amendment_comments"]["BO-003"]["url"] = value[
            "ticket_amendment_comments"
        ]["BO-005"]["url"]
        joined = "\n".join(self.validate(value).errors)
        self.assertIn("mapped issue BO-003", joined)
        self.assertIn("comment URL is reused", joined)

    def test_rendered_comments_pin_policy_and_lane_ownership(self) -> None:
        root = render_authorization_comment(self.amendment)
        self.assertIn(POLICY_AUTHORITY_COMMIT, root)
        self.assertIn("11-execution-amendment.md", root)

        owner = render_ticket_amendment_comment(self.amendment, "BO-007")
        self.assertIn("Lane owner:", owner)
        self.assertIn("Exact members:", owner)
        self.assertIn("#L132", owner)
        follower = render_ticket_amendment_comment(self.amendment, "BO-011")
        self.assertIn("Lane follower:", follower)
        self.assertIn("issues/1095", follower)
        self.assertIn("closes individually", follower)
        individual = render_ticket_amendment_comment(self.amendment, "BO-003")
        self.assertIn("Individual owner packet:", individual)
        self.assertIn("#L98", individual)

    def test_receipt_mapping_drift_fails_even_with_self_consistent_amendment(self) -> None:
        changed = copy.deepcopy(self.authority)
        build = changed.receipt_manifests["build-order.json"]
        build["tickets"][0]["github"]["node_id"] = "FORGED"
        joined = "\n".join(self.validate(auth=changed).errors)
        self.assertIn("54/105 baseline", joined)


class ExecutionAmendmentLiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.authority = authority()
        completed = {
            item["id"]
            for item in self.authority.receipt_manifests["build-order.json"]["tickets"]
            if item["id"] not in EXPECTED_AFFECTED_IDS
        }
        self.amendment = amendment(self.authority, completed_before=completed)
        self.snapshot = snapshot(self.authority, self.amendment)

    def compare(self, snap=None) -> Report:
        report = Report()
        compare_execution_snapshot(
            snap or self.snapshot, self.authority, self.amendment, report,
        )
        return report

    def test_mixed_open_and_completed_execution_state_passes(self) -> None:
        self.assertEqual([], self.compare().errors)

    def test_not_planned_and_reopened_precompleted_ticket_fail(self) -> None:
        completed = self.amendment["completed_before_amendment_ticket_ids"][0]
        for state, reason in (("CLOSED", "not_planned"), ("OPEN", "reopened")):
            with self.subTest(state=state, reason=reason):
                snap = copy.deepcopy(self.snapshot)
                issues = dict(snap.issues)
                row = json.loads(issues[completed])
                row.update(state=state, state_reason=reason)
                issues[completed] = json.dumps(row, sort_keys=True, separators=(",", ":"))
                snap = copy.deepcopy(snap)
                object.__setattr__(snap, "issues", tuple(sorted(issues.items())))
                joined = "\n".join(self.compare(snap).errors)
                self.assertIn("must remain completed", joined)

    def test_membership_edge_mapping_and_body_drift_fail(self) -> None:
        mutations = []
        member = copy.deepcopy(self.snapshot)
        object.__setattr__(member, "root_members", member.root_members[:-1])
        mutations.append((member, "exactly 54"))
        edge = copy.deepcopy(self.snapshot)
        object.__setattr__(edge, "internal_edges", edge.internal_edges[:-1])
        mutations.append((edge, "exactly 105"))
        body = copy.deepcopy(self.snapshot)
        issues = dict(body.issues)
        logical_id = next(iter(issues))
        row = json.loads(issues[logical_id]); row["body_sha256"] = "0" * 64
        issues[logical_id] = json.dumps(row, sort_keys=True, separators=(",", ":"))
        object.__setattr__(body, "issues", tuple(sorted(issues.items())))
        mutations.append((body, "body drifted"))
        for snap, expected in mutations:
            with self.subTest(expected=expected):
                self.assertIn(expected, "\n".join(self.compare(snap).errors))

    def test_duplicate_or_edited_comment_marker_fails(self) -> None:
        snap = copy.deepcopy(self.snapshot)
        comments = dict(snap.comments)
        logical_id = next(iter(comments))
        row = json.loads(comments[logical_id])
        row["marked"].append(copy.deepcopy(row["exact"]))
        comments[logical_id] = json.dumps(row, sort_keys=True, separators=(",", ":"))
        object.__setattr__(snap, "comments", tuple(sorted(comments.items())))
        self.assertIn(
            "exactly one amendment marker", "\n".join(self.compare(snap).errors)
        )

    def test_double_read_must_be_stable(self) -> None:
        second = copy.deepcopy(self.snapshot)
        issues = dict(second.issues)
        logical_id = next(iter(issues))
        row = json.loads(issues[logical_id]); row["updated_at"] = "2026-07-15T18:01:00Z"
        issues[logical_id] = json.dumps(row, sort_keys=True, separators=(",", ":"))
        object.__setattr__(second, "issues", tuple(sorted(issues.items())))
        report = Report()
        with patch(
            "execution_amendment_live.capture_execution_snapshot",
            side_effect=[self.snapshot, second],
        ):
            verify_live_execution_amendment(
                self.authority, self.amendment, report, reader=object(),
            )
        self.assertIn("changed during the two bounded reads", "\n".join(report.errors))


if __name__ == "__main__":
    unittest.main()
