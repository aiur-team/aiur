"""Load and validate publication authority from an immutable receipt commit."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Callable

from publication_common import SHA, Report, valid_trusted_branch_ref
from publication_rendering import exact_commit, repository_root, run_authority_git


PACK_ROOT = PurePosixPath("docs/build-order")
MANIFEST_NAMES = (
    "build-order.json",
    "dashboard-companions.json",
    "publication.json",
)
REGULAR_MODES = {b"100644", b"100755"}
GITHUB_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
RemoteRefContainmentChecker = Callable[[str, str, tuple[str, ...]], bool]


@dataclass(frozen=True)
class ReceiptAuthority:
    repository: str
    root_id: str
    plan_version: int
    approved_commit: str
    root_issue_url: str
    root_comment_url: str
    trusted_repository_ref: str
    receipt_manifests: dict[str, dict[str, Any]] = field(
        repr=False, compare=False,
    )


def load_receipt_authority(
    receipt_commit: str,
    repository_anchor: Path,
    report: Report,
    remote_ref_contains: RemoteRefContainmentChecker | None = None,
) -> ReceiptAuthority | None:
    """Validate exact receipt bytes with current trusted validation code."""
    validation = Report()
    root = _source_root(repository_anchor, validation)
    if root is None or not exact_commit(
        root, receipt_commit, "receipt_commit", validation
    ):
        _merge(validation, report)
        return None
    trusted_repository = _github_origin_repository(root, validation)
    if trusted_repository is None:
        _merge(validation, report)
        return None

    snapshot = _snapshot_blobs(root, receipt_commit, validation)
    if snapshot is None:
        _merge(validation, report)
        return None
    manifests, blobs = snapshot
    _require_materialized_receipts(manifests, validation)
    if validation.errors:
        _merge(validation, report)
        return None

    with tempfile.TemporaryDirectory() as temp_name:
        clone = Path(temp_name) / "receipt"
        if not _clone_without_checkout(root, clone, validation):
            _merge(validation, report)
            return None
        _write_snapshot(clone, blobs, validation)
        if not validation.errors:
            _validate_with_trusted_code(clone, validation)

    authority = None
    if not validation.errors and not validation.warnings:
        authority = _derive_authority(
            manifests, root, trusted_repository, validation
        )
    if authority is not None and not validation.errors and not validation.warnings:
        _require_local_receipt_order(
            root, authority.approved_commit, receipt_commit, validation
        )
    if authority is not None and not validation.errors and not validation.warnings:
        _require_remote_ref_containment(
            authority, receipt_commit,
            remote_ref_contains or _github_repository_ref_contains,
            validation,
        )
    _merge(validation, report)
    return authority if not validation.errors and not validation.warnings else None


def _source_root(anchor: Path, report: Report) -> Path | None:
    probe = anchor / ".receipt-authority-anchor" if anchor.is_dir() else anchor
    return repository_root(probe, report)


def _github_origin_repository(root: Path, report: Report) -> str | None:
    result = run_authority_git(
        ["git", "-C", str(root), "remote", "get-url", "origin"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        report.error("receipt authority requires a configured GitHub origin")
        return None
    url = result.stdout.strip().rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    repository = None
    for prefix in (
        "https://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
    ):
        if url.startswith(prefix):
            repository = url[len(prefix):]
            break
    if repository is None or not GITHUB_REPOSITORY.fullmatch(repository):
        report.error("receipt authority origin must identify one GitHub repository")
        return None
    return repository


def _snapshot_blobs(
    root: Path, receipt_commit: str, report: Report,
) -> tuple[dict[str, dict[str, Any]], dict[str, bytes]] | None:
    manifests: dict[str, dict[str, Any]] = {}
    blobs: dict[str, bytes] = {}
    for name in MANIFEST_NAMES:
        path = (PACK_ROOT / name).as_posix()
        raw = _commit_blob(root, receipt_commit, path, f"receipt {name}", report)
        if raw is None:
            continue
        blobs[path] = raw
        value = _json_object(raw, f"receipt {name}", report)
        if value is not None:
            manifests[name] = value
    if set(manifests) != set(MANIFEST_NAMES):
        return None

    reserved = {path.casefold(): path for path in blobs}
    for label, relative in _document_references(manifests):
        safe = _safe_relative_path(relative, label, report)
        if safe is None:
            continue
        path = (PACK_ROOT / PurePosixPath(safe)).as_posix()
        folded = path.casefold()
        if folded in reserved:
            report.error(
                f"{label} collides with reserved receipt path {reserved[folded]}"
            )
            continue
        raw = _commit_blob(root, receipt_commit, path, label, report)
        if raw is not None:
            blobs[path] = raw
            reserved[folded] = path
    return manifests, blobs


def _document_references(
    manifests: dict[str, dict[str, Any]],
) -> list[tuple[str, object]]:
    references: list[tuple[str, object]] = []
    for manifest_name in ("build-order.json", "dashboard-companions.json"):
        tickets = manifests[manifest_name].get("tickets")
        if not isinstance(tickets, list):
            continue
        for index, ticket in enumerate(tickets):
            if isinstance(ticket, dict):
                ticket_id = ticket.get("id", index)
                references.append(
                    (f"receipt document for {ticket_id}", ticket.get("document"))
                )
    publication = manifests["publication.json"]
    for key in ("root_issue", "skill_issue"):
        issue = publication.get(key)
        if isinstance(issue, dict):
            references.append(
                (f"receipt document for {key}", issue.get("document"))
            )
    return references


def _safe_relative_path(value: object, label: str, report: Report) -> str | None:
    if not isinstance(value, str) or not value:
        report.error(f"{label} must be a non-empty repository-relative path")
        return None
    path = PurePosixPath(value)
    normalized = path.as_posix()
    if (
        path.is_absolute()
        or ".." in path.parts
        or normalized == "."
        or normalized != value
        or "\x00" in value
        or any(part.casefold() == ".git" for part in path.parts)
    ):
        report.error(f"{label} must be a safe repository-relative path")
        return None
    return normalized


def _commit_blob(
    root: Path, commit: str, path: str, label: str, report: Report,
) -> bytes | None:
    entry = run_authority_git(
        ["git", "-C", str(root), "ls-tree", "-z", commit, "--", path],
        check=False,
        capture_output=True,
    )
    if entry.returncode or not _regular_tree_entry(entry.stdout, path):
        report.error(f"{label} must be a regular file at {path}")
        return None
    result = run_authority_git(
        ["git", "-C", str(root), "show", f"{commit}:{path}"],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        report.error(f"{label} is absent from receipt commit at {path}")
        return None
    return result.stdout


def _regular_tree_entry(raw: bytes, path: str) -> bool:
    entries = [item for item in raw.split(b"\0") if item]
    if len(entries) != 1 or b"\t" not in entries[0]:
        return False
    metadata, name = entries[0].split(b"\t", 1)
    fields = metadata.split()
    try:
        decoded_name = name.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return (
        len(fields) == 3
        and fields[0] in REGULAR_MODES
        and fields[1] == b"blob"
        and decoded_name == path
    )


def _json_object(raw: bytes, label: str, report: Report) -> dict[str, Any] | None:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.error(f"{label} must be valid UTF-8 JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"{label} must be a JSON object")
        return None
    return value


def _require_materialized_receipts(
    manifests: dict[str, dict[str, Any]], report: Report,
) -> None:
    for name in MANIFEST_NAMES:
        if not isinstance(manifests[name].get("github_reconciliation"), dict):
            report.error(
                f"receipt commit {name} github_reconciliation must be materialized"
            )


def _clone_without_checkout(root: Path, destination: Path, report: Report) -> bool:
    result = run_authority_git(
        [
            "git", "clone", "--quiet", "--shared", "--no-checkout", "--",
            str(root), str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        report.error(f"cannot create no-checkout receipt snapshot: {detail}")
        return False
    return True


def _write_snapshot(root: Path, blobs: dict[str, bytes], report: Report) -> None:
    for path, raw in blobs.items():
        target = root.joinpath(*PurePosixPath(path).parts)
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        except OSError as exc:
            report.error(f"cannot materialize receipt snapshot {path}: {exc}")


def _validate_with_trusted_code(root: Path, report: Report) -> None:
    # Function-local import avoids publication_comment -> validator -> comment cycles.
    from validate_publication import validate

    pack = root.joinpath(*PACK_ROOT.parts)
    result = validate(
        pack / "dashboard-companions.json",
        pack / "build-order.json",
        pack / "publication.json",
    )
    for error in result.errors:
        report.error(f"receipt commit validation: {error}")
    for warning in result.warnings:
        report.error(f"receipt commit validation warning: {warning}")


def _derive_authority(
    manifests: dict[str, dict[str, Any]], root: Path,
    trusted_repository: str, report: Report,
) -> ReceiptAuthority | None:
    build = manifests["build-order.json"]
    companions = manifests["dashboard-companions.json"]
    repository = companions.get("repository")
    root_id = build.get("build_order_id")
    plan_version = companions.get("plan_version")
    approved = companions.get("approved_planning_commit")
    github_root = build.get("github_root")
    publication = manifests["publication.json"]
    root_url = github_root.get("url") if isinstance(github_root, dict) else None
    root_number = (
        github_root.get("number") if isinstance(github_root, dict) else None
    )
    trusted_ref = publication.get("trusted_repository_ref")
    publication_receipt = publication.get("github_reconciliation")
    comment_matches = (
        publication_receipt.get("root_reconciliation_comment_matches")
        if isinstance(publication_receipt, dict) else None
    )
    root_comment_url = (
        comment_matches[0].get("url")
        if isinstance(comment_matches, list) and len(comment_matches) == 1
        and isinstance(comment_matches[0], dict)
        else None
    )
    if not isinstance(repository, str):
        report.error("validated receipt repository is unavailable")
    elif repository != trusted_repository:
        report.error(
            "validated receipt repository must equal configured GitHub origin "
            f"{trusted_repository}"
        )
    if not isinstance(root_id, str):
        report.error("validated receipt root ID is unavailable")
    elif not root_id.startswith(f"{trusted_repository}:"):
        report.error(
            "validated receipt root ID must use configured GitHub repository namespace"
        )
    if type(plan_version) is not int:
        report.error("validated receipt plan version is unavailable")
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("validated receipt approval commit is unavailable")
    elif not exact_commit(root, approved, "approved_planning_commit", report):
        pass
    if not isinstance(root_url, str):
        report.error("validated receipt root issue URL is unavailable")
    elif root_url != (
        f"https://github.com/{trusted_repository}/issues/{root_number}"
    ):
        report.error(
            "validated receipt root issue URL must use configured GitHub repository namespace"
        )
    if not valid_trusted_branch_ref(trusted_ref):
        report.error(
            "validated receipt trusted_repository_ref must be an exact "
            "refs/heads/... repository-owned branch ref"
        )
    if not isinstance(root_comment_url, str):
        report.error("validated receipt root reconciliation comment URL is unavailable")
    elif isinstance(root_url, str) and not re.fullmatch(
        re.escape(root_url) + r"#issuecomment-[1-9][0-9]*", root_comment_url
    ):
        report.error(
            "validated receipt root reconciliation comment URL must belong to "
            "the mapped root issue"
        )
    if report.errors:
        return None
    assert isinstance(repository, str)
    assert isinstance(root_id, str)
    assert type(plan_version) is int
    assert isinstance(approved, str)
    assert isinstance(root_url, str)
    assert isinstance(root_comment_url, str)
    assert isinstance(trusted_ref, str)
    return ReceiptAuthority(
        repository=trusted_repository,
        root_id=root_id,
        plan_version=plan_version,
        approved_commit=approved,
        root_issue_url=root_url,
        root_comment_url=root_comment_url,
        trusted_repository_ref=trusted_ref,
        receipt_manifests=manifests,
    )


def _require_remote_ref_containment(
    authority: ReceiptAuthority, receipt_commit: str,
    checker: RemoteRefContainmentChecker, report: Report,
) -> None:
    commits = (receipt_commit, authority.approved_commit)
    try:
        contains = checker(
            authority.repository, authority.trusted_repository_ref, commits
        )
    except Exception:
        contains = False
    if contains is not True:
        report.error(
            "receipt_commit and approved_planning_commit must remain ancestors "
            f"of configured GitHub repository branch "
            f"{authority.repository}:{authority.trusted_repository_ref}"
        )


def _require_local_receipt_order(
    root: Path, approved_commit: str, receipt_commit: str, report: Report,
) -> None:
    result = run_authority_git(
        [
            "git", "-C", str(root), "merge-base", "--is-ancestor",
            approved_commit, receipt_commit,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        report.error(
            "receipt_commit must descend from approved_planning_commit in the "
            "no-substitution repository graph"
        )


def _github_repository_ref_contains(
    repository: str, trusted_ref: str, commits: tuple[str, ...],
) -> bool:
    if not valid_trusted_branch_ref(trusted_ref):
        return False
    target_sha = _github_branch_target(repository, trusted_ref)
    if target_sha is None or not commits or not all(
        isinstance(commit, str) and bool(SHA.fullmatch(commit)) for commit in commits
    ):
        return False
    contained = all(
        _github_compare_proves_ancestor(repository, commit.lower(), target_sha)
        for commit in commits
    )
    # A force-push between the ref and compare reads must not produce a
    # self-consistent-looking receipt from two different remote snapshots.
    return contained and _github_branch_target(repository, trusted_ref) == target_sha


def _github_branch_target(repository: str, trusted_ref: str) -> str | None:
    ref_payload = _github_json(
        f"repos/{repository}/git/ref/{trusted_ref.removeprefix('refs/')}"
    )
    if not isinstance(ref_payload, dict) or ref_payload.get("ref") != trusted_ref:
        return None
    target = ref_payload.get("object")
    if (
        not isinstance(target, dict)
        or target.get("type") != "commit"
        or not isinstance(target.get("sha"), str)
        or not SHA.fullmatch(target["sha"])
    ):
        return None
    return target["sha"].lower()


def _github_compare_proves_ancestor(
    repository: str, commit: str, target: str,
) -> bool:
    comparison = _github_json(f"repos/{repository}/compare/{commit}...{target}")
    if not isinstance(comparison, dict):
        return False
    base = comparison.get("base_commit")
    merge_base = comparison.get("merge_base_commit")
    base_sha = base.get("sha") if isinstance(base, dict) else None
    merge_base_sha = (
        merge_base.get("sha") if isinstance(merge_base, dict) else None
    )
    behind_by = comparison.get("behind_by")
    ahead_by = comparison.get("ahead_by")
    if (
        not isinstance(base, dict)
        or not isinstance(merge_base, dict)
        or not isinstance(base_sha, str)
        or not isinstance(merge_base_sha, str)
        or base_sha.lower() != commit
        or merge_base_sha.lower() != commit
        or type(behind_by) is not int
        or behind_by != 0
    ):
        return False
    status = comparison.get("status")
    if status == "identical":
        return type(ahead_by) is int and target == commit and ahead_by == 0
    return (
        status == "ahead"
        and target != commit
        and type(ahead_by) is int
        and ahead_by > 0
    )


def _github_json(endpoint: str) -> object | None:
    try:
        result = subprocess.run(
            [
                "gh", "api",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                endpoint,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.errors.extend(
        f"receipt authority warning: {warning}" for warning in source.warnings
    )
