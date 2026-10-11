"""Atomic, recoverable writes of the published bundle and discovery pack."""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from publication_client import MATERIALIZATION_TRANSACTION, PublicationError


def atomic_write_bundle(publisher, files: dict[Path, str]) -> None:
    """Commit all related publication files through a recoverable journal."""
    root = Path(getattr(publisher.context, "root", publisher.context.build_path.parent)).resolve()
    entries = []
    for path, content in files.items():
        resolved = path.resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError:
            raise PublicationError("publication output must remain inside the repository") from None
        entries.append({"path": relative, "content": content})
    journal = root / MATERIALIZATION_TRANSACTION
    publisher._atomic_write_json(
        journal, {"version": 1, "files": entries}, indent=2,
    )
    try:
        publisher._fsync_directory(root)
        publisher._replace_staged_files({Path(root / entry["path"]): entry["content"] for entry in entries})
        publisher._fsync_directory(root)
        journal.unlink()
        publisher._fsync_directory(root)
    except OSError:
        # Leave the journal in place.  The next operator invocation
        # replays the complete bundle before loading the manifests.
        raise PublicationError("could not commit publication manifests safely") from None


def replace_staged_files(files: dict[Path, str]) -> None:
    temporary: dict[Path, str] = {}
    try:
        for path, content in files.items():
            descriptor, name = tempfile.mkstemp(
                dir=path.parent, prefix=f".{path.name}.", suffix=".tmp",
            )
            temporary[path] = name
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        for path, name in temporary.items():
            os.replace(name, path)
        temporary.clear()
    except OSError:
        raise
    finally:
        for name in temporary.values():
            try:
                os.unlink(name)
            except OSError:
                pass


def recover_materialization_transaction(root: Path) -> bool:
    journal = root / MATERIALIZATION_TRANSACTION
    if not journal.exists():
        return False
    try:
        payload = json.loads(journal.read_text(encoding="utf-8"))
        entries = payload.get("files") if isinstance(payload, dict) else None
        if (
            not isinstance(payload, dict) or payload.get("version") != 1
            or not isinstance(entries, list)
        ):
            raise ValueError
        files: dict[Path, str] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError
            relative, content = entry.get("path"), entry.get("content")
            if not isinstance(relative, str) or not isinstance(content, str):
                raise ValueError
            path = (root / relative).resolve()
            path.relative_to(root)
            files[path] = content
        if not files:
            raise ValueError
        replace_staged_files(files)
        fsync_directory(root)
        journal.unlink()
        fsync_directory(root)
        return True
    except (OSError, ValueError, json.JSONDecodeError):
        raise PublicationError("publication transaction recovery failed safely") from None


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_json(path: Path, value: dict[str, Any], *, indent: int) -> None:
    """Replace one internal journal without exposing truncated JSON."""
    temporary: str | None = None
    try:
        descriptor, temporary = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp",
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(value, indent=indent) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError:
        raise PublicationError(
            f"could not checkpoint {path.name} safely"
        ) from None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def write_materialized(publisher, fresh: dict[str, Any]) -> None:
    build = json.loads(json.dumps(publisher.context.build))
    publication = json.loads(json.dumps(publisher.context.publication))
    issues = fresh["issues"]
    root_mapping = publisher._receipt_mapping(issues[publisher.context.root_id]["mapping"])
    build["github_root"] = root_mapping
    for ticket in build["tickets"]:
        ticket["github"] = publisher._receipt_mapping(issues[ticket["id"]]["mapping"])
    ticket_ids = [ticket["id"] for ticket in build["tickets"]]
    checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    projected = {key: list(spec.labels) for key, spec in publisher.context.specs.items()}
    build["github_reconciliation"] = {
        "receipt_schema_version": 3,
        "checked_at": checked_at,
        "approved_planning_commit": publisher.context.approved,
        "root_node_id": root_mapping["node_id"],
        "member_ticket_ids": ticket_ids,
        "dependency_edges": [
            {"ticket_id": blocked, "depends_on": blocker}
            for blocked, blocker in sorted(publisher.context.core_edges)
        ],
        "projected_labels": {
            key: projected[key] for key in [publisher.context.root_id, *ticket_ids]
        },
        "observed_labels": {
            key: issues[key]["labels"] for key in [publisher.context.root_id, *ticket_ids]
        },
        "expected_issue_titles": {
            key: publisher.context.specs[key].title for key in [publisher.context.root_id, *ticket_ids]
        },
        "observed_issue_titles": {
            key: issues[key]["title"] for key in [publisher.context.root_id, *ticket_ids]
        },
        "observed_issue_states": {
            key: issues[key]["state"] for key in [publisher.context.root_id, *ticket_ids]
        },
        "observed_body_evidence": {
            key: publisher.context.approved_evidence[key] for key in [publisher.context.root_id, *ticket_ids]
        },
        "marker_query_matches": {
            key: [publisher._receipt_mapping(item) for item in fresh["marker_matches"][key]]
            for key in [publisher.context.root_id, *ticket_ids]
        },
    }
    if publisher.context.skill_id is not None:
        skill_id = publisher.context.skill_id
        publication["approved_planning_commit"] = publisher.context.approved
        publication["github_reconciliation"] = {
            "receipt_schema_version": 2,
            "checked_at": checked_at,
            "issue_mappings": {
                publisher.context.root_id: root_mapping,
                skill_id: publisher._receipt_mapping(issues[skill_id]["mapping"]),
            },
            "external_blocker_relations": publication[
                "external_blocker_relations"
            ],
            "observed_labels": {
                publisher.context.root_id: issues[publisher.context.root_id]["labels"],
                skill_id: issues[skill_id]["labels"],
            },
            "observed_parent_issues": {
                publisher.context.root_id: None, skill_id: None,
            },
            "observed_body_evidence": {
                skill_id: publisher.context.approved_evidence[skill_id],
            },
            "expected_issue_titles": {
                skill_id: publisher.context.specs[skill_id].title,
            },
            "observed_issue_titles": {skill_id: issues[skill_id]["title"]},
            "observed_issue_states": {skill_id: issues[skill_id]["state"]},
            "marker_query_matches": {
                skill_id: [
                    publisher._receipt_mapping(item)
                    for item in fresh["marker_matches"][skill_id]
                ],
            },
            "root_reconciliation_comment_matches": [fresh["comment"]],
        }
    files = {
        publisher.context.build_path: json.dumps(build, indent=1) + "\n",
        publisher.context.publication_path: json.dumps(publication, indent=2) + "\n",
        publisher.context.root_document: publisher.context.specs[publisher.context.root_id].body,
    }
    if publisher.context.additional_document is not None and publisher.context.skill_id:
        files[publisher.context.additional_document] = publisher.context.specs[publisher.context.skill_id].body
    publisher._atomic_write_bundle(files)
    publisher.context.build = build
    publisher.context.publication = publication


def write_discovery_pack(publisher) -> None:
    publisher.context.discovery_path.parent.mkdir(parents=True, exist_ok=True)
    publisher.context.discovery_path.write_text(
        publisher.context.build_path.read_text(encoding="utf-8"), encoding="utf-8",
    )
