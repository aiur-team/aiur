"""Run the pinned aiur-build v2 receipt contract without vendoring it."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from publication_common import SHA, Report


PINNED_SKILL_COMMIT = "0daf29726fbe8345a79588e14b6f4c556584a57c"
SKILL_ROOT = ".claude/skills/aiur-build/scripts"
PINNED_MODULES = (
    "validation_common.py",
    "validation_github_evidence.py",
    "validation_github_receipt.py",
)
ADAPTER = """\
import json
import sys
from pathlib import Path
from validation_common import Report
from validation_github_receipt import validate_reconciliation

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
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
validate_reconciliation(data, by_id, root, mappings, report)
print(json.dumps({"errors": report.errors, "warnings": report.warnings}))
"""


def repository_root(report: Report) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(Path(__file__).resolve().parent), "rev-parse", "--show-toplevel"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        report.error("publication validator must run from a Git repository")
        return None
    return Path(result.stdout.strip()).resolve()


def validate_commit_reference(value: object, label: str, report: Report) -> bool:
    if not isinstance(value, str) or not SHA.fullmatch(value):
        return False
    root = repository_root(report)
    if root is None:
        return False
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{value}^{{commit}}"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0 or result.stdout.strip().lower() != value.lower():
        report.error(f"{label} must resolve to an exact commit in this repository")
        return False
    return True


def validate_core_receipt(build_path: Path, materialized: bool, report: Report) -> None:
    if not materialized:
        return
    root = repository_root(report)
    if root is None or not _exact_commit(root, report):
        return
    result = _run_pinned(root, build_path, report)
    if result is not None:
        _apply_result(result, report)


def _run_pinned(
    root: Path, build_path: Path, report: Report,
) -> subprocess.CompletedProcess[str] | None:
    with tempfile.TemporaryDirectory() as name:
        base = Path(name)
        if not _extract_modules(root, base, report):
            return None
        adapter = base / "validate_receipt.py"
        adapter.write_text(ADAPTER, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(adapter), str(build_path.resolve())],
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
    report.errors.extend(f"Build Order receipt v2: {item}" for item in errors)
    report.warnings.extend(f"Build Order receipt v2: {item}" for item in warnings)


def _exact_commit(root: Path, report: Report) -> bool:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{PINNED_SKILL_COMMIT}^{{commit}}"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode or result.stdout.strip() != PINNED_SKILL_COMMIT:
        report.error("pinned aiur-build receipt contract commit is unavailable")
        return False
    return True


def _extract_modules(root: Path, base: Path, report: Report) -> bool:
    for filename in PINNED_MODULES:
        result = subprocess.run(
            ["git", "-C", str(root), "show", f"{PINNED_SKILL_COMMIT}:{SKILL_ROOT}/{filename}"],
            check=False, capture_output=True,
        )
        if result.returncode:
            report.error(f"pinned aiur-build receipt module unavailable: {filename}")
            return False
        (base / filename).write_bytes(result.stdout)
    return True
