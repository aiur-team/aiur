"""Read the execution amendment and its policy document from Git authority."""

from __future__ import annotations

import hashlib
import json
import stat
from pathlib import Path
from typing import Any

import skill_publication_path  # noqa: F401
from publication_common import Report, SHA
from publication_receipt_authority import _commit_blob, ReceiptBlobBudget
from publication_rendering import exact_commit, repository_relative, repository_root


def load_amendment_at_commit(
    amendment_path: Path, amendment_commit: str, report: Report,
) -> dict[str, Any] | None:
    """Load exact committed amendment bytes and reject mutable-source drift."""
    root = repository_root(amendment_path, report)
    if root is None:
        return None
    if not isinstance(amendment_commit, str) or not SHA.fullmatch(amendment_commit):
        report.error("amendment_commit must be a 40-character Git SHA")
        return None
    if not exact_commit(root, amendment_commit, "amendment_commit", report):
        return None
    relative = repository_relative(amendment_path, root, report)
    if relative is None:
        return None
    budget = ReceiptBlobBudget(files_remaining=1, bytes_remaining=2 * 1024 * 1024)
    committed = _commit_blob(
        root, amendment_commit, relative, "execution amendment", budget, report,
    )
    try:
        mode = amendment_path.lstat().st_mode
        current = amendment_path.read_bytes()
    except OSError as exc:
        report.error(f"cannot read current execution amendment: {exc}")
        return None
    if not stat.S_ISREG(mode) or amendment_path.is_symlink():
        report.error("current execution amendment must be a regular non-symlink file")
        return None
    if committed is None:
        return None
    if current != committed:
        report.error("current execution amendment must equal amendment_commit bytes")
        return None
    try:
        value = json.loads(committed.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.error(f"execution amendment must be valid UTF-8 JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error("execution amendment must be a JSON object")
        return None
    return value


def validate_policy_authority_source(
    amendment_path: Path, amendment: dict[str, Any], report: Report,
) -> None:
    """Prove the supplied policy commit contains the exact authorized document."""
    value = amendment.get("policy_authority")
    if not isinstance(value, dict):
        report.error("execution amendment policy_authority is unavailable")
        return
    commit, document = value.get("commit"), value.get("document")
    wanted_sha = value.get("document_sha256")
    root = repository_root(amendment_path, report)
    if root is None or not isinstance(commit, str):
        return
    if not exact_commit(root, commit, "policy_authority.commit", report):
        return
    policy_path = amendment_path.parent / str(document)
    relative = repository_relative(policy_path, root, report)
    if relative is None:
        return
    budget = ReceiptBlobBudget(files_remaining=1, bytes_remaining=2 * 1024 * 1024)
    committed = _commit_blob(
        root, commit, relative, "execution amendment policy document", budget, report,
    )
    if committed is None:
        return
    observed_sha = hashlib.sha256(committed).hexdigest()
    if observed_sha != wanted_sha:
        report.error("policy authority document hash does not match the supplied receipt")
    try:
        current = policy_path.read_bytes()
        mode = policy_path.lstat().st_mode
    except OSError as exc:
        report.error(f"cannot read current policy authority document: {exc}")
        return
    if not stat.S_ISREG(mode) or policy_path.is_symlink():
        report.error("current policy authority document must be regular and non-symlinked")
    elif current != committed:
        report.error("current policy authority document must equal policy commit bytes")
