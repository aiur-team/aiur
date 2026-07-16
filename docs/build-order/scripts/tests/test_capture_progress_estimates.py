"""Focused tests for the offline Build Order progress-estimate collector."""

from __future__ import annotations

import json
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from capture_progress_estimates import CollectorError, collect  # noqa: E402


class CaptureProgressEstimatesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "workspaces"
        self.output = Path(self.temporary.name) / "analytics" / "samples.ndjson"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_rows(self, ticket: int, *rows: object) -> Path:
        path = self.root / str(ticket) / "logs" / "agent.ndjson"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as stream:
            for row in rows:
                if isinstance(row, str):
                    stream.write(row + "\n")
                else:
                    stream.write(json.dumps(row) + "\n")
        return path

    def samples(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self.output.read_text().splitlines()]

    def test_lifecycle_copies_collapse_and_completion_enriches_sample(self) -> None:
        arguments = {
            "name": "progress.checkin",
            "message": "review underway",
            "payload": {"label": "review: fixes underway", "percent": 90},
        }
        self.write_rows(
            1085,
            {
                "event": "notification",
                "timestamp": "2026-07-14T01:00:00.000000Z",
                "payload": {
                    "method": "item/started",
                    "params": {"item": {"id": "exec-1", "arguments": arguments}},
                },
            },
            {
                "event": "tool_call_completed",
                "timestamp": "2026-07-14T01:00:00.100000Z",
                "payload": {
                    "params": {"callId": "exec-1", "arguments": arguments}
                },
            },
            {
                "event": "notification",
                "timestamp": "2026-07-14T01:00:00.200000Z",
                "payload": {
                    "method": "item/completed",
                    "params": {
                        "item": {
                            "id": "exec-1",
                            "arguments": arguments,
                            "status": "completed",
                            "success": True,
                            "contentItems": [
                                {
                                    "type": "inputText",
                                    "text": json.dumps({"result": {"id": 4242}}),
                                }
                            ],
                        }
                    },
                },
            },
        )

        result = collect([self.root], self.output)

        self.assertEqual(1, result["total_samples"])
        sample = self.samples()[0]
        self.assertEqual("2026-07-14T01:00:00.000000Z", sample["timestamp"])
        self.assertEqual("emitted", sample["delivery_status"])
        self.assertEqual(4242, sample["event_id"])
        self.assertEqual("progress.checkin", sample["estimate_kind"])
        self.assertEqual(90, sample["percent"])

    def test_stream_tolerates_noise_malformed_rows_and_argument_string_variant(self) -> None:
        secret = "do-not-copy-this-token"
        self.write_rows(
            1086,
            "not json",
            {"event": "notification", "payload": {"delta": "progress.checkin 90"}},
            {
                "event": "tool_call_completed",
                "timestamp": "2026-07-14T02:00:00+00:00",
                "raw_prompt": secret,
                "payload": {
                    "command_output": secret,
                    "params": {
                        "callId": "exec-2",
                        "arguments": json.dumps(
                            {
                                "name": "progress",
                                "message": "starting the ticket",
                                "payload": {"label": "plan: scoped", "percent": "10%"},
                            }
                        ),
                    },
                },
            },
        )

        result = collect([self.root], self.output)

        self.assertEqual(1, result["malformed_source_lines"])
        self.assertEqual(1, result["total_samples"])
        serialized = self.output.read_text()
        self.assertNotIn(secret, serialized)
        self.assertEqual("starting the ticket", self.samples()[0]["message"])
        self.assertEqual("attempted", self.samples()[0]["delivery_status"])

    def test_completed_tool_without_bus_event_id_remains_attempted(self) -> None:
        self.write_rows(
            1086,
            {
                "event": "notification",
                "timestamp": "2026-07-14T02:30:00Z",
                "payload": {
                    "method": "item/completed",
                    "params": {
                        "item": {
                            "id": "exec-no-event",
                            "arguments": {
                                "name": "progress.checkin",
                                "message": "tool lifecycle ended",
                                "payload": {"label": "work", "percent": 60},
                            },
                            "status": "completed",
                            "success": True,
                            "contentItems": [],
                        }
                    },
                },
            },
        )

        collect([self.root], self.output)

        sample = self.samples()[0]
        self.assertIsNone(sample["event_id"])
        self.assertEqual("attempted", sample["delivery_status"])

    def test_eventual_publication_completion_upgrades_pending_call(self) -> None:
        arguments = {
            "name": "progress.checkin",
            "message": "publication queued",
            "payload": {"label": "work", "percent": 65},
        }
        self.write_rows(
            1086,
            {
                "event": "notification",
                "timestamp": "2026-07-14T02:30:00Z",
                "payload": {
                    "method": "item/completed",
                    "params": {
                        "item": {
                            "id": "exec-eventual-success",
                            "arguments": arguments,
                            "status": "completed",
                            "success": True,
                            "contentItems": [],
                        }
                    },
                },
            },
            {
                "event": "event_publication_completed",
                "timestamp": "2026-07-14T02:30:01Z",
                "tool_call_id": "exec-eventual-success",
                "event_id": 4243,
                "topic": "ticket.1086.agent.progress.checkin",
            },
        )

        collect([self.root], self.output)

        sample = self.samples()[0]
        self.assertEqual("emitted", sample["delivery_status"])
        self.assertEqual(4243, sample["event_id"])

    def test_terminal_publication_failure_marks_pending_call_failed(self) -> None:
        arguments = {
            "name": "progress",
            "message": "publication queued",
            "payload": {"label": "work", "percent": 66},
        }
        self.write_rows(
            1086,
            {
                "event": "notification",
                "timestamp": "2026-07-14T02:31:00Z",
                "payload": {
                    "method": "item/completed",
                    "params": {
                        "item": {
                            "id": "exec-eventual-failure",
                            "arguments": arguments,
                            "status": "completed",
                            "success": True,
                            "contentItems": [],
                        }
                    },
                },
            },
            {
                "event": "event_publication_failed",
                "timestamp": "2026-07-14T02:31:01Z",
                "tool_call_id": "exec-eventual-failure",
                "reason": ["error", "disk_full"],
                "topic": "ticket.1086.agent.progress",
            },
        )

        collect([self.root], self.output)

        sample = self.samples()[0]
        self.assertIsNone(sample["event_id"])
        self.assertEqual("failed", sample["delivery_status"])

    def test_failed_attempt_is_retained_but_distinguished(self) -> None:
        self.write_rows(
            1087,
            {
                "event": "tool_call_failed",
                "timestamp": "2026-07-14T03:00:00Z",
                "payload": {
                    "params": {
                        "callId": "exec-failed",
                        "arguments": {
                            "name": "progress.checkin",
                            "message": "still reviewing",
                            "payload": {"label": "review", "percent": 80},
                        },
                    }
                },
            },
        )
        collect([self.root], self.output)
        self.assertEqual("failed", self.samples()[0]["delivery_status"])

    def test_rescan_and_source_removal_preserve_one_durable_sample(self) -> None:
        source = self.write_rows(
            1088,
            {
                "event": "progress.checkin",
                "timestamp": "2026-07-14T04:00:00Z",
                "payload": {"label": "work", "message": "coding", "percent": 50},
            },
        )
        first = collect([self.root], self.output)
        second = collect([self.root], self.output)
        shutil.rmtree(source.parents[1])
        third = collect([self.root], self.output)

        self.assertEqual(1, first["new_samples"])
        self.assertEqual(0, second["new_samples"])
        self.assertEqual(1, third["total_samples"])
        self.assertEqual([1088], third["covered_tickets"])
        self.assertEqual("emitted", self.samples()[0]["delivery_status"])

    def test_malformed_durable_output_fails_closed(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.output.write_text("not json\n")
        with self.assertRaises(CollectorError):
            collect([self.root], self.output)
        self.assertEqual("not json\n", self.output.read_text())

    def test_new_dedicated_output_parent_is_private(self) -> None:
        collect([self.root], self.output)
        mode = stat.S_IMODE(self.output.parent.stat().st_mode)
        self.assertEqual(0o700, mode)


if __name__ == "__main__":
    unittest.main()
