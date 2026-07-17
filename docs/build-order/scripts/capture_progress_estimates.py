#!/usr/bin/env python3
"""Capture Build Order agent progress estimates without retaining transcripts."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


DEFAULT_WORKSPACE_ROOT = Path(
    os.environ.get(
        "AIUR_BUILD_ORDER_WORKSPACE_ROOT",
        "~/code/aiur-workspaces/its-everdred/aiur",
    )
).expanduser()
DEFAULT_OUTPUT = Path(
    os.environ.get(
        "AIUR_BUILD_ORDER_PROGRESS_OUTPUT",
        "~/.aiur/analytics/build-order-progress/progress-estimates.ndjson",
    )
).expanduser()
DEFAULT_PUBLICATION_ROOT = Path(
    os.environ.get("AIUR_BUILD_ORDER_PUBLICATION_ROOT", "~/.aiur/logs")
).expanduser()
ESTIMATE_KINDS = frozenset(("progress", "progress.checkin"))
PUBLICATION_EVENTS = {
    "event_publication_completed": "emitted",
    "event_publication_failed": "failed",
}
STATUS_RANK = {"attempted": 0, "failed": 1, "emitted": 2}
PUBLICATION_LOG_NAME = "event-publications.ndjson"
SCHEMA_VERSION = 2
PERCENT = re.compile(r"^(?:100(?:\.0+)?|\d{1,2}(?:\.\d+)?)%?$")


class CollectorError(RuntimeError):
    """Raised when the durable output cannot be read without data loss."""


def _mapping(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except (TypeError, ValueError):
            return None
        return decoded if isinstance(decoded, dict) else None
    return None


def _get(data: Any, *path: str) -> Any:
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def _argument_candidates(row: dict[str, Any]) -> Iterable[dict[str, Any]]:
    paths = (
        ("payload", "params", "item", "arguments"),
        ("payload", "params", "arguments"),
        ("payload", "item", "arguments"),
        ("payload", "arguments"),
        ("item", "arguments"),
        ("arguments",),
    )
    seen: set[int] = set()
    for path in paths:
        candidate = _mapping(_get(row, *path))
        if candidate is not None and id(candidate) not in seen:
            seen.add(id(candidate))
            yield candidate

    # Some adapters persist the emitted event directly instead of the wrapping
    # emit_event tool call. It is safe to support only the two exact names.
    if row.get("event") in ESTIMATE_KINDS:
        payload = _mapping(row.get("payload")) or {}
        yield {
            "name": row["event"],
            "message": row.get("message", payload.get("message")),
            "payload": payload,
        }


def _percent(value: Any) -> int | float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str) and PERCENT.fullmatch(value.strip()):
        number = float(value.strip().removesuffix("%"))
    else:
        return None
    if not 0 <= number <= 100:
        return None
    return int(number) if number.is_integer() else number


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _timestamp(row: dict[str, Any]) -> str | None:
    value = row.get("timestamp")
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        if parsed is not None and parsed.tzinfo is not None:
            return (
                parsed.astimezone(timezone.utc)
                .isoformat(timespec="microseconds")
                .replace("+00:00", "Z")
            )

    for path in (
        ("payload", "params", "startedAtMs"),
        ("payload", "params", "completedAtMs"),
        ("startedAtMs",),
        ("completedAtMs",),
    ):
        milliseconds = _get(row, *path)
        if isinstance(milliseconds, (int, float)) and not isinstance(milliseconds, bool):
            try:
                parsed = datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
            except (OverflowError, OSError, ValueError):
                continue
            return parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    return None


def _call_id(row: dict[str, Any]) -> str | None:
    for path in (
        ("payload", "params", "callId"),
        ("payload", "params", "item", "id"),
        ("payload", "callId"),
        ("tool_call_id",),
        ("callId",),
        ("item", "id"),
    ):
        value = _get(row, *path)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return str(value)
    return None


def _event_id(row: dict[str, Any]) -> str | int | None:
    for path in (
        ("event_id",),
        ("payload", "event_id"),
        ("payload", "result", "id"),
        ("payload", "params", "result", "id"),
    ):
        value = _get(row, *path)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return value

    items = _get(row, "payload", "params", "item", "contentItems")
    if not isinstance(items, list):
        return None
    for item in items:
        if not isinstance(item, dict) or item.get("type") != "inputText":
            continue
        decoded = _mapping(item.get("text"))
        value = _get(decoded, "result", "id")
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return value
    return None


def _publication_outcome(row: dict[str, Any]) -> dict[str, Any] | None:
    status = PUBLICATION_EVENTS.get(row.get("event"))
    call_id = _call_id(row)
    timestamp = _timestamp(row)
    if status is None or call_id is None or timestamp is None:
        return None
    return {
        "delivery_status": status,
        "event_id": _event_id(row),
        "timestamp": timestamp,
        "tool_call_id": call_id,
    }


def _publication_ticket(row: dict[str, Any]) -> int | None:
    for key in ("issue_number", "issue_identifier"):
        value = row.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            return value
        if isinstance(value, str) and value.isdigit() and int(value) > 0:
            return int(value)
    return None


def _sample_id(
    ticket: int,
    source_log: str,
    call_id: str | None,
    timestamp: str,
    kind: str,
    percent: int | float,
    label: str | None,
    message: str | None,
) -> str:
    if call_id is not None:
        return _call_sample_id(ticket, call_id)
    identity = "\0".join(
        (
            "estimate",
            str(ticket),
            source_log,
            timestamp,
            kind,
            str(percent),
            label or "",
            message or "",
        )
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _call_sample_id(ticket: int, call_id: str) -> str:
    identity = f"call\0{ticket}\0{call_id}"
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def sample_from_row(
    row: dict[str, Any], ticket: int, source_log: Path
) -> dict[str, Any] | None:
    timestamp = _timestamp(row)
    if timestamp is None:
        return None
    for arguments in _argument_candidates(row):
        kind = arguments.get("name")
        if kind not in ESTIMATE_KINDS:
            continue
        payload = _mapping(arguments.get("payload")) or {}
        percent = _percent(payload.get("percent", arguments.get("percent")))
        if percent is None:
            continue
        label = _text(payload.get("label", arguments.get("label")))
        message = _text(arguments.get("message", payload.get("message")))
        call_id = _call_id(row)
        source = str(source_log.resolve())
        return {
            "schema_version": SCHEMA_VERSION,
            "sample_id": _sample_id(
                ticket, source, call_id, timestamp, kind, percent, label, message
            ),
            "ticket": ticket,
            "timestamp": timestamp,
            "event_id": None,
            "tool_call_id": call_id,
            "estimate_kind": kind,
            "percent": percent,
            "label": label,
            "message": message,
            "delivery_status": "attempted",
            "source_log": source,
        }
    return None


def _merge_sample(
    current: dict[str, Any], incoming: dict[str, Any]
) -> dict[str, Any]:
    result = dict(current)
    if incoming["timestamp"] < current["timestamp"]:
        result["timestamp"] = incoming["timestamp"]
    if STATUS_RANK[incoming["delivery_status"]] > STATUS_RANK[
        current["delivery_status"]
    ]:
        result["delivery_status"] = incoming["delivery_status"]
    if result.get("event_id") is None and incoming.get("event_id") is not None:
        result["event_id"] = incoming["event_id"]
    for field in ("tool_call_id", "label", "message"):
        if result.get(field) is None and incoming.get(field) is not None:
            result[field] = incoming[field]
    return result


def _apply_publication_outcome(
    sample: dict[str, Any], outcome: dict[str, Any]
) -> dict[str, Any]:
    result = dict(sample)
    if STATUS_RANK[outcome["delivery_status"]] > STATUS_RANK[
        sample["delivery_status"]
    ]:
        result["delivery_status"] = outcome["delivery_status"]
    if result.get("event_id") is None and outcome.get("event_id") is not None:
        result["event_id"] = outcome["event_id"]
    return result


def _merge_publication_outcome(
    current: dict[str, Any], incoming: dict[str, Any]
) -> dict[str, Any]:
    result = dict(current)
    if STATUS_RANK[incoming["delivery_status"]] > STATUS_RANK[
        current["delivery_status"]
    ]:
        result["delivery_status"] = incoming["delivery_status"]
    if result.get("event_id") is None and incoming.get("event_id") is not None:
        result["event_id"] = incoming["event_id"]
    if incoming["timestamp"] < current["timestamp"]:
        result["timestamp"] = incoming["timestamp"]
    return result


def _load_existing(output: Path) -> dict[str, dict[str, Any]]:
    samples: dict[str, dict[str, Any]] = {}
    if not output.exists():
        return samples
    with output.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except (TypeError, ValueError) as error:
                raise CollectorError(
                    f"refusing to replace malformed durable output at line {line_number}: {error}"
                ) from error
            sample_id = row.get("sample_id") if isinstance(row, dict) else None
            if not isinstance(sample_id, str) or not sample_id:
                raise CollectorError(
                    f"refusing to replace invalid durable output at line {line_number}"
                )
            samples[sample_id] = _upgrade_existing_sample(row, line_number)
    return samples


def _upgrade_existing_sample(
    row: dict[str, Any], line_number: int
) -> dict[str, Any]:
    version = row.get("schema_version", 1)
    if version == SCHEMA_VERSION:
        return row
    if version == 1:
        upgraded = dict(row)
        upgraded["schema_version"] = SCHEMA_VERSION
        upgraded["delivery_status"] = "attempted"
        upgraded["event_id"] = None
        return upgraded
    raise CollectorError(
        f"refusing unsupported durable schema at line {line_number}: {version!r}"
    )


def _write_atomic(output: Path, samples: dict[str, dict[str, Any]]) -> None:
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=output.parent, prefix=".progress-", delete=False
    ) as stream:
        temporary = Path(stream.name)
        os.chmod(temporary, 0o600)
        for sample in sorted(
            samples.values(),
            key=lambda item: (
                item["timestamp"],
                item["ticket"],
                item["sample_id"],
            ),
        ):
            stream.write(json.dumps(sample, sort_keys=True, separators=(",", ":")))
            stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, output)


def _source_rows(source_log: Path, stats: dict[str, int]) -> Iterable[dict[str, Any]]:
    stats["source_logs_scanned"] += 1
    with source_log.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            stats["source_lines_scanned"] += 1
            try:
                row = json.loads(line)
            except (TypeError, ValueError):
                stats["malformed_source_lines"] += 1
                continue
            if isinstance(row, dict):
                yield row


def _remember_publication_outcome(
    row: dict[str, Any],
    ticket: int,
    publication_outcomes: dict[str, dict[str, Any]],
    stats: dict[str, int],
) -> None:
    outcome = _publication_outcome(row)
    if outcome is None:
        return
    stats["publication_records_seen"] += 1
    sample_id = _call_sample_id(ticket, outcome["tool_call_id"])
    current = publication_outcomes.get(sample_id)
    publication_outcomes[sample_id] = (
        outcome
        if current is None
        else _merge_publication_outcome(current, outcome)
    )


def _publication_logs(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return

    direct = root / PUBLICATION_LOG_NAME
    if direct.is_file():
        yield direct
    yield from sorted(root.glob(f"*/log/{PUBLICATION_LOG_NAME}"))


def collect(
    workspace_roots: Iterable[Path],
    output: Path,
    ticket_min: int = 1085,
    ticket_max: int = 1138,
    publication_roots: Iterable[Path] = (),
) -> dict[str, Any]:
    if ticket_min > ticket_max:
        raise CollectorError("ticket minimum must not exceed ticket maximum")
    output = output.expanduser()
    output_parent_existed = output.parent.exists()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if (
        not output_parent_existed
        or output.parent.resolve() == DEFAULT_OUTPUT.parent.resolve()
    ):
        os.chmod(output.parent, 0o700)
    lock_path = output.with_suffix(output.suffix + ".lock")
    with lock_path.open("a", encoding="utf-8") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        samples = _load_existing(output)
        before = len(samples)
        stats = {
            "source_logs_scanned": 0,
            "source_lines_scanned": 0,
            "malformed_source_lines": 0,
            "estimate_records_seen": 0,
            "publication_records_seen": 0,
        }
        publication_outcomes: dict[str, dict[str, Any]] = {}
        scanned_tickets: set[int] = set()
        for raw_root in workspace_roots:
            root = raw_root.expanduser()
            for ticket in range(ticket_min, ticket_max + 1):
                agent_log = root / str(ticket) / "logs" / "agent.ndjson"
                if not agent_log.is_file():
                    continue
                scanned_tickets.add(ticket)
                for row in _source_rows(agent_log, stats):
                    sample = sample_from_row(row, ticket, agent_log)
                    if sample is None:
                        continue
                    stats["estimate_records_seen"] += 1
                    sample_id = sample["sample_id"]
                    if sample_id in samples:
                        samples[sample_id] = _merge_sample(
                            samples[sample_id], sample
                        )
                    else:
                        samples[sample_id] = sample

        seen_publication_logs: set[Path] = set()
        for raw_root in publication_roots:
            for source_log in _publication_logs(raw_root.expanduser()):
                resolved = source_log.resolve()
                if resolved in seen_publication_logs:
                    continue
                seen_publication_logs.add(resolved)
                for row in _source_rows(source_log, stats):
                    ticket = _publication_ticket(row)
                    if ticket is None or not ticket_min <= ticket <= ticket_max:
                        continue
                    scanned_tickets.add(ticket)
                    _remember_publication_outcome(
                        row, ticket, publication_outcomes, stats
                    )
        for sample_id, outcome in publication_outcomes.items():
            if sample_id in samples:
                samples[sample_id] = _apply_publication_outcome(
                    samples[sample_id], outcome
                )
        _write_atomic(output, samples)

    covered_tickets = sorted(
        {
            sample["ticket"]
            for sample in samples.values()
            if ticket_min <= sample.get("ticket", -1) <= ticket_max
        }
    )
    return {
        **stats,
        "output": str(output.resolve()),
        "new_samples": len(samples) - before,
        "total_samples": len(samples),
        "scanned_tickets": sorted(scanned_tickets),
        "covered_tickets": covered_tickets,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture BO agent progress estimates into a durable local NDJSON dataset."
    )
    parser.add_argument(
        "--workspace-root",
        action="append",
        type=Path,
        dest="workspace_roots",
        help="repository workspace root containing ticket agent logs; repeatable",
    )
    parser.add_argument(
        "--publication-root",
        action="append",
        type=Path,
        dest="publication_roots",
        help="daemon run-log root containing event-publications.ndjson; repeatable",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--ticket-min", type=int, default=1085)
    parser.add_argument("--ticket-max", type=int, default=1138)
    return parser


def main(argv: list[str]) -> int:
    args = _parser().parse_args(argv[1:])
    roots = args.workspace_roots or [DEFAULT_WORKSPACE_ROOT]
    publication_roots = args.publication_roots or [DEFAULT_PUBLICATION_ROOT]
    try:
        result = collect(
            roots,
            args.output,
            args.ticket_min,
            args.ticket_max,
            publication_roots,
        )
    except (CollectorError, OSError) as error:
        print(f"capture failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
