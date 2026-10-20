#!/usr/bin/env python3
"""Compare Hex advisories on the base and candidate locks, failing closed."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
LOCK = SRC / "mix.lock"
ALLOWLIST = ROOT / "docs/security/hex-advisories-allowlist.json"
FINDING = re.compile(r"^\s+(\S+)\s+(\S+)\s+-\s+(\S+)\s+\((HIGH|MEDIUM|LOW)\)$", re.M)
ADVISORY_ROW = re.compile(r"^ {2}\S+\s+\S+\s+-\s+\S+.*$", re.M)
OSV_LINK = re.compile(r"^ {4}https://osv\.dev/vulnerability/(\S+)\s*$", re.M)
FETCH_FAILURE = re.compile(r"Failed to fetch (?:record|retired|advisory).*?(?:registry|cache)", re.I)
ADVISORIES_HEADER = "Advisories:"
ADVISORIES_FOUND = "Found packages with security advisories"
NO_ADVISORIES = "No retired or security advisory packages found"


def parse_findings(output: str) -> set[tuple[str, str, str, str]]:
    return set(FINDING.findall(output))


def load_allowlist(path: Path, today: dt.date) -> dict[str, dict[str, str]]:
    data = json.loads(path.read_text())
    if data.get("version") != 1 or not isinstance(data.get("entries"), list):
        raise ValueError("allow-list must have version 1 and an entries array")
    entries: dict[str, dict[str, str]] = {}
    for entry in data["entries"]:
        advisory = entry.get("advisory")
        reason = entry.get("reason")
        expiry = entry.get("expires")
        if not all(isinstance(value, str) and value.strip() for value in (advisory, reason, expiry)):
            raise ValueError("each allow-list entry needs advisory, reason, and expires")
        if "accept_high" in entry and not isinstance(entry["accept_high"], bool):
            raise ValueError(f"allow-list entry {advisory} accept_high must be a boolean")
        if advisory in entries:
            raise ValueError(f"duplicate allow-list entry: {advisory}")
        expires = dt.date.fromisoformat(expiry)
        if expires < today:
            raise ValueError(f"allow-list entry {advisory} expired on {expiry}")
        entries[advisory] = entry
    return entries


def evaluate(base: set[tuple[str, str, str, str]], head: set[tuple[str, str, str, str]], allowed: dict[str, dict[str, object]]) -> list[str]:
    base_ids = {finding[2] for finding in base}
    head_ids = {finding[2] for finding in head}
    errors: list[str] = []
    for package, version, advisory, severity in sorted(head):
        newly_introduced = advisory not in base_ids
        entry = allowed.get(advisory)
        if entry is not None:
            if severity != "HIGH" or entry.get("accept_high") is True:
                continue
            errors.append(f"{package} {version}: HIGH advisory {advisory} requires explicit accept_high: true")
            continue
        if severity == "HIGH" or (severity == "MEDIUM" and newly_introduced):
            errors.append(f"{package} {version}: unallowlisted {severity} advisory {advisory}")
        else:
            errors.append(f"{package} {version}: advisory {advisory} needs a dated allow-list entry")
    stale = allowed.keys() - head_ids
    errors.extend(f"allow-list entry {advisory} matches no base or candidate finding" for advisory in sorted(stale))
    return errors


def run(command: list[str], *, cwd: Path, allow_advisories: bool = False) -> str:
    if "HEX_OFFLINE" in os.environ:
        raise RuntimeError("HEX_OFFLINE is set; refusing to audit potentially stale cached advisories")
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    output = result.stdout
    if FETCH_FAILURE.search(output):
        raise RuntimeError(f"Hex registry fetch failed; refusing to use cached results:\n{output}")
    if "Failed to fetch" in output:
        raise RuntimeError(f"Hex registry fetch failed; refusing to use cached results:\n{output}")
    if result.returncode and not (allow_advisories and "Found packages with security advisories" in output):
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{output}")
    if "Found retired packages" in output:
        raise RuntimeError(f"retired Hex dependency found:\n{output}")
    return output


def audit_lock(lock_bytes: bytes, label: str, runner=run) -> set[tuple[str, str, str, str]]:
    LOCK.write_bytes(lock_bytes)
    runner(["mise", "exec", "--", "mix", "deps.get"], cwd=SRC)
    if LOCK.read_bytes() != lock_bytes:
        raise RuntimeError(f"{label} dependency resolution changed the lock; refusing to audit a different snapshot")
    output = runner(["mise", "exec", "--", "mix", "hex.audit"], cwd=SRC, allow_advisories=True)
    return parse_audit_output(output, label)


def parse_audit_output(output: str, label: str) -> set[tuple[str, str, str, str]]:
    findings = parse_findings(output)
    rows = ADVISORY_ROW.findall(output)
    links = OSV_LINK.findall(output)
    if findings:
        if ADVISORIES_HEADER not in output or ADVISORIES_FOUND not in output:
            raise RuntimeError(f"{label} audit output has findings without the expected headers; failing closed:\n{output}")
        finding_ids = [finding[2] for finding in FINDING.findall(output)]
        if len(rows) != len(findings) or len(links) != len(findings) or set(links) != set(finding_ids):
            raise RuntimeError(f"{label} audit output contains unparsed or unmatched advisories; failing closed:\n{output}")
        return findings
    if rows or links or ADVISORIES_HEADER in output or ADVISORIES_FOUND in output:
        raise RuntimeError(f"{label} audit output contains malformed advisories; failing closed:\n{output}")
    if NO_ADVISORIES not in output:
        raise RuntimeError(f"{label} audit output lacks a recognized clean result; failing closed:\n{output}")
    return set()


def evaluate_locks(base_lock: bytes, head_lock: bytes, allowed: dict[str, dict[str, object]], auditor=audit_lock) -> list[str]:
    base_findings = auditor(base_lock, "base")
    head_findings = auditor(head_lock, "candidate")
    return evaluate(base_findings, head_findings, allowed)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: audit-hex-dependencies.py <base-ref>", file=sys.stderr)
        return 2
    base_ref = sys.argv[1]
    original_lock = LOCK.read_bytes()
    try:
        base_lock = subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{base_ref}:src/mix.lock"],
            text=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        today = dt.date.fromisoformat(os.environ.get("AUDIT_TODAY", dt.date.today().isoformat()))
        allowlist = load_allowlist(ALLOWLIST, today)
        errors = evaluate_locks(base_lock, original_lock, allowlist)
        if errors:
            print("Hex dependency audit failed:", file=sys.stderr)
            print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
            return 1
        print("Hex dependency audit passed; candidate lock advisories satisfy the dated policy.")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Hex dependency audit failed closed: {error}", file=sys.stderr)
        return 1
    finally:
        LOCK.write_bytes(original_lock)


if __name__ == "__main__":
    raise SystemExit(main())
