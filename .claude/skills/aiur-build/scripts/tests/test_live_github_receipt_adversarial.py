"""Adversarial live GitHub receipt drift tests."""

import copy

from live_receipt_helpers import (
    FakeReader,
    REPOSITORY,
    ROOT_ID,
    fixture,
    raw_mapping,
    validate,
)


class LiveReceiptAdversarialTests(__import__("unittest").TestCase):
    def test_duplicate_marker_match_fails_even_when_closed(self) -> None:
        data, snapshot = fixture()
        duplicate = copy.deepcopy(snapshot["issues"]["BO-001"])
        duplicate.update(
            number=999,
            node_id="DUPLICATE",
            html_url=f"https://github.com/{REPOSITORY}/issues/999",
            state="closed",
        )
        snapshot["issues"]["duplicate"] = duplicate
        self.assertIn(
            "marker query for BO-001 must return exactly its mapped issue",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_pull_request_marker_collision_fails(self) -> None:
        data, snapshot = fixture()
        pull = copy.deepcopy(snapshot["issues"]["BO-001"])
        pull.update(
            number=999,
            node_id="PULL",
            html_url=f"https://github.com/{REPOSITORY}/pull/999",
            pull_request={"url": "https://api.github.com/pulls/999"},
        )
        snapshot["issues"]["pull"] = pull
        self.assertIn(
            "appears on a pull request",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_unhashable_marker_identity_fails_without_crashing(self) -> None:
        data, snapshot = fixture()
        malformed = copy.deepcopy(snapshot["issues"]["BO-001"])
        malformed.update(
            number=999,
            node_id="MALFORMED",
            html_url=f"https://github.com/{REPOSITORY}/issues/999",
            body=malformed["body"].replace('"logical_id":"BO-001"', '"logical_id":[]'),
        )
        snapshot["issues"]["malformed"] = malformed
        self.assertIn(
            "planning marker has invalid typed values",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_parent_and_nested_subissue_drift_fail(self) -> None:
        data, snapshot = fixture()
        snapshot["parents"][ROOT_ID] = raw_mapping(data["tickets"][0]["github"])
        self.assertIn(
            f"parent for {ROOT_ID} must equal none",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )
        data, snapshot = fixture()
        snapshot["nested"]["BO-001"] = [raw_mapping(data["tickets"][1]["github"])]
        self.assertIn(
            "member BO-001 must not have subissues",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_mid_query_snapshot_drift_fails(self) -> None:
        data, first = fixture()
        second = copy.deepcopy(first)
        second["issues"]["BO-001"]["title"] = "changed between reads"
        report = validate(data, FakeReader(first, second))
        self.assertIn(
            "live GitHub publication graph changed during bounded requery",
            report.errors,
        )

    def test_ordering_only_differences_are_canonicalized(self) -> None:
        data, first = fixture()
        second = copy.deepcopy(first)
        second["issues"] = dict(reversed(list(second["issues"].items())))
        second["members"].reverse()
        for issue in second["issues"].values():
            issue["labels"].reverse()
        self.assertEqual([], validate(data, FakeReader(first, second)).errors)


if __name__ == "__main__":
    import unittest

    unittest.main()
