"""Run the pinned aiur-build v3 receipt contract without vendoring it."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from publication_common import SHA, Report
from publication_rendering import exact_commit, repository_root, run_authority_git


PINNED_SKILL_COMMIT = "afd9828c61005a84ee316e3b2c995c0122b896ff"
SKILL_ROOT = ".claude/skills/aiur-build/scripts"
PINNED_MODULES = (
    "validation_common.py",
    "validation_github_evidence.py",
    "validation_github_approved.py",
    "validation_github_receipt.py",
    "validation_github_rendering.py",
    "validation_github_live.py",
)
ADAPTER = """\
import json
import sys
from pathlib import Path
from validation_common import Report
from validation_github_approved import ApprovedIssueExpectations
from validation_github_receipt import validate_reconciliation

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raw_expected = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = ApprovedIssueExpectations(
    bodies=raw_expected["bodies"], titles=raw_expected["titles"]
)
tickets = data.get("tickets") if isinstance(data.get("tickets"), list) else []
by_id = {
    item.get("id"): item for item in tickets
    if isinstance(item, dict) and isinstance(item.get("id"), str)
}
root = data.get("github_root") if isinstance(data.get("github_root"), dict) else None
mappings = {
    key: item.get("github") if isinstance(item.get("github"), dict) else None
    for key, item in by_id.items()
}
report = Report()
validate_reconciliation(data, by_id, root, mappings, report, expected)
print(json.dumps({"errors": report.errors, "warnings": report.warnings}))
"""


def contract_repository_root(report: Report) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(Path(__file__).resolve().parent), "rev-parse", "--show-toplevel"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        report.error("publication validator must run from a Git repository")
        return None
    return Path(result.stdout.strip()).resolve()


def validate_commit_reference(
    value: object, label: str, pack_path: Path, report: Report,
) -> bool:
    if not isinstance(value, str) or not SHA.fullmatch(value):
        return False
    root = repository_root(pack_path, report)
    if root is None:
        return False
    return exact_commit(root, value, label, report)


def validate_core_receipt(
    build_path: Path, materialized: bool,
    expected_bodies: dict[str, dict[str, Any]] | None,
    expected_titles: dict[str, str] | None, report: Report,
) -> None:
    if not materialized:
        return
    root = contract_repository_root(report)
    if root is None or not _exact_commit(root, report):
        return
    build = json.loads(build_path.read_text(encoding="utf-8"))
    root_id = build.get("build_order_id") if isinstance(build, dict) else None
    ticket_ids = {
        item.get("id") for item in build.get("tickets", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    } if isinstance(build, dict) else set()
    core_ids = ticket_ids | ({root_id} if isinstance(root_id, str) else set())
    core_expected = {
        key: value for key, value in (expected_bodies or {}).items()
        if key in core_ids
    }
    if set(core_expected) != core_ids:
        report.error("pinned Build Order receipt requires approved body expectations")
        return
    core_titles = {
        key: value for key, value in (expected_titles or {}).items()
        if key in core_ids
    }
    if set(core_titles) != core_ids:
        report.error("pinned Build Order receipt requires approved title expectations")
        return
    result = _run_pinned(
        root, build_path, {"bodies": core_expected, "titles": core_titles}, report
    )
    if result is not None:
        _apply_result(result, report)


def _run_pinned(
    root: Path, build_path: Path, expected: dict[str, Any], report: Report,
) -> subprocess.CompletedProcess[str] | None:
    with tempfile.TemporaryDirectory() as name:
        base = Path(name)
        if not _extract_modules(root, base, report):
            return None
        adapter = base / "validate_receipt.py"
        adapter.write_text(ADAPTER, encoding="utf-8")
        expected_path = base / "approved-bodies.json"
        expected_path.write_text(json.dumps(expected), encoding="utf-8")
        return subprocess.run(
            [
                sys.executable, str(adapter), str(build_path.resolve()),
                str(expected_path),
            ],
            check=False, capture_output=True, text=True,
        )


def _apply_result(result: subprocess.CompletedProcess[str], report: Report) -> None:
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        report.error(f"pinned Build Order receipt validator failed closed: {detail}")
        return
    try:
        payload: Any = json.loads(result.stdout)
        errors, warnings = payload["errors"], payload["warnings"]
        if not isinstance(errors, list) or not isinstance(warnings, list):
            raise TypeError("non-list diagnostics")
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        report.error(f"pinned Build Order receipt validator returned invalid output: {exc}")
        return
    report.errors.extend(f"Build Order receipt v3: {item}" for item in errors)
    report.warnings.extend(f"Build Order receipt v3: {item}" for item in warnings)


def _exact_commit(root: Path, report: Report) -> bool:
    result = run_authority_git(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{PINNED_SKILL_COMMIT}^{{commit}}"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode or result.stdout.strip() != PINNED_SKILL_COMMIT:
        report.error("pinned aiur-build receipt contract commit is unavailable")
        return False
    return True


def _extract_modules(root: Path, base: Path, report: Report) -> bool:
    for filename in PINNED_MODULES:
        result = run_authority_git(
            ["git", "-C", str(root), "show", f"{PINNED_SKILL_COMMIT}:{SKILL_ROOT}/{filename}"],
            check=False, capture_output=True,
        )
        if result.returncode:
            report.error(f"pinned aiur-build receipt module unavailable: {filename}")
            return False
        (base / filename).write_bytes(result.stdout)
    return True
