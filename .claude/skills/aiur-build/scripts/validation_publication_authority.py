"""Load immutable publication and mutation authority from approved Git history."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from validation_common import (
    REPOSITORY,
    SHA,
    Report,
    checked_string_list,
    git_no_replace_env,
    nonempty_string,
    repository_relative_path,
    strict_object,
)
from validation_git_bounded import run_bounded_git


MANIFEST_KEYS = {
    "trusted_repository_ref",
    "root_document",
    "mutation_repositories",
    "reference_only_issue_urls",
    "tracker_lifecycle_label_prefix",
}
ISSUE_URL = re.compile(
    r"^https://github\.com/[^/\s]+/[^/\s]+/issues/[1-9][0-9]*$", re.ASCII,
)
GIT_AUTHORITY_TIMEOUT_SECONDS = 30
MAX_PUBLICATION_GIT_OUTPUT_BYTES = 64 * 1024
MAX_PUBLICATION_MANIFEST_BYTES = 256 * 1024


@dataclass(frozen=True)
class PublicationAuthority:
    trusted_repository_ref: str
    root_document: str
    mutation_repositories: tuple[str, ...]
    reference_only_issue_urls: tuple[str, ...]
    tracker_lifecycle_label_prefix: str


def load_frozen_publication_authority(
    root: Path,
    manifest_path: str,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
) -> PublicationAuthority | None:
    """Require identical typed publication authority at approval and receipt."""
    path = repository_relative_path(manifest_path, "publication manifest", report)
    if path is None:
        return None
    loaded: dict[str, PublicationAuthority] = {}
    for label, commit in (
        ("approved_planning_commit", approved_commit),
        ("receipt_commit", receipt_commit),
    ):
        if not isinstance(commit, str) or not SHA.fullmatch(commit):
            report.error(f"{label} must be a 40-character Git SHA")
            continue
        if not exact_commit(root, commit):
            report.error(f"{label} must resolve to an exact commit")
            continue
        manifest = _manifest(root, str(commit), path, label, report)
        authority = _parse_authority(manifest, label, report)
        if authority is not None:
            loaded[label] = authority
    if set(loaded) != {"approved_planning_commit", "receipt_commit"}:
        return None
    approved = loaded["approved_planning_commit"]
    if loaded["receipt_commit"] != approved:
        report.error("receipt publication authority must equal its approved value")
        return None
    return approved


def exact_commit(root: Path, commit: object) -> bool:
    if not isinstance(commit, str) or not SHA.fullmatch(commit):
        return False
    result = _git(root, "rev-parse", "--verify", f"{commit}^{{commit}}")
    return result.returncode == 0 and result.stdout.strip().lower() == commit.lower()


def _manifest(
    root: Path, commit: str, path: str, label: str, report: Report,
) -> dict[str, Any] | None:
    entry = _git(root, "ls-tree", "-z", commit, "--", path, binary=True)
    if entry.returncode or not _regular_blob(entry.stdout, path):
        report.error(f"{label} publication manifest must be a regular file at {path}")
        return None
    result = _git(
        root, "show", f"{commit}:{path}", binary=True,
        stdout_limit=MAX_PUBLICATION_MANIFEST_BYTES,
    )
    try:
        value = json.loads(result.stdout.decode("utf-8")) if result.returncode == 0 else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        value = None
    if not isinstance(value, dict):
        report.error(f"{label} publication manifest must be a UTF-8 JSON object")
        return None
    return value


def _parse_authority(
    value: dict[str, Any] | None, label: str, report: Report,
) -> PublicationAuthority | None:
    manifest = strict_object(value, f"{label} publication manifest", MANIFEST_KEYS, report)
    if manifest is None:
        return None
    trusted_ref = manifest.get("trusted_repository_ref")
    root_document = repository_relative_path(
        manifest.get("root_document"), f"{label} root_document", report,
    )
    repositories = checked_string_list(
        manifest.get("mutation_repositories"),
        f"{label} mutation_repositories", report, require_items=True,
    )
    reference_only = checked_string_list(
        manifest.get("reference_only_issue_urls"),
        f"{label} reference_only_issue_urls", report,
    )
    prefix = manifest.get("tracker_lifecycle_label_prefix")
    valid = True
    if not isinstance(trusted_ref, str):
        report.error(f"{label} trusted_repository_ref must be a string")
        valid = False
    if root_document is None:
        valid = False
    if any(not REPOSITORY.fullmatch(item) for item in repositories):
        report.error(f"{label} mutation_repositories must contain owner/repo values")
        valid = False
    if any(not ISSUE_URL.fullmatch(item) for item in reference_only):
        report.error(f"{label} reference_only_issue_urls must contain exact issue URLs")
        valid = False
    if not nonempty_string(prefix) or ":" in str(prefix):
        report.error(f"{label} tracker_lifecycle_label_prefix must be one label segment")
        valid = False
    if not valid:
        return None
    return PublicationAuthority(
        str(trusted_ref), str(root_document), tuple(repositories),
        tuple(reference_only), str(prefix),
    )


def _regular_blob(raw: bytes, path: str) -> bool:
    entries = [entry for entry in raw.split(b"\0") if entry]
    if len(entries) != 1 or b"\t" not in entries[0]:
        return False
    metadata, name = entries[0].split(b"\t", 1)
    fields = metadata.split()
    return (
        len(fields) == 3 and fields[0] in {b"100644", b"100755"}
        and fields[1] == b"blob" and name == path.encode("utf-8")
    )


def _git(
    root: Path, *arguments: str, binary: bool = False,
    stdout_limit: int = MAX_PUBLICATION_GIT_OUTPUT_BYTES,
):
    return run_bounded_git(
        root, *arguments, environment=git_no_replace_env(), text=not binary,
        timeout_seconds=GIT_AUTHORITY_TIMEOUT_SECONDS,
        stdout_limit=stdout_limit,
        stderr_limit=MAX_PUBLICATION_GIT_OUTPUT_BYTES,
    )
