#!/usr/bin/env python3
import datetime as dt
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import importlib.util

MODULE_PATH = Path(__file__).with_name("audit-hex-dependencies.py")
spec = importlib.util.spec_from_file_location("audit_hex_dependencies", MODULE_PATH)
audit = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(audit)


class AuditPolicyTest(unittest.TestCase):
    CLEAN = audit.NO_ADVISORIES

    def test_current_high_fails_even_when_present_on_base(self):
        finding = ("bandit", "1.12.5", "EEF-HIGH", "HIGH")
        self.assertEqual(audit.evaluate({finding}, {finding}, {}), ["bandit 1.12.5: unallowlisted HIGH advisory EEF-HIGH"])

    def test_high_allowlist_requires_explicit_acceptance(self):
        finding = ("bandit", "1.12.5", "EEF-HIGH", "HIGH")
        plain_entry = {"EEF-HIGH": {"reason": "temporary exception", "expires": "2026-11-20"}}
        explicit_entry = {**plain_entry, "EEF-HIGH": {**plain_entry["EEF-HIGH"], "accept_high": True}}
        self.assertEqual(
            audit.evaluate(set(), {finding}, plain_entry),
            ["bandit 1.12.5: HIGH advisory EEF-HIGH requires explicit accept_high: true"],
        )
        self.assertEqual(audit.evaluate(set(), {finding}, explicit_entry), [])

    def test_fixed_base_high_does_not_fail_candidate(self):
        base = {("bandit", "1.12.5", "EEF-HIGH", "HIGH")}
        self.assertEqual(audit.evaluate(base, set(), {}), [])

    def test_new_medium_fails(self):
        finding = ("decimal", "3.1.1", "EEF-MEDIUM", "MEDIUM")
        self.assertEqual(audit.evaluate(set(), {finding}, {}), ["decimal 3.1.1: unallowlisted MEDIUM advisory EEF-MEDIUM"])

    def test_dated_allowlist_accepts_finding_until_expiry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "allowlist.json"
            path.write_text(json.dumps({"version": 1, "entries": [{"advisory": "EEF-MEDIUM", "reason": "upstream fix pending", "expires": "2026-11-20"}]}))
            allowed = audit.load_allowlist(path, dt.date(2026, 10, 20))
            finding = ("decimal", "3.1.1", "EEF-MEDIUM", "MEDIUM")
            self.assertEqual(audit.evaluate(set(), {finding}, allowed), [])
            with self.assertRaisesRegex(ValueError, "expired"):
                audit.load_allowlist(path, dt.date(2026, 11, 21))

    def test_unused_allowlist_entry_fails(self):
        self.assertEqual(audit.evaluate(set(), set(), {"EEF-STALE": {}}), ["allow-list entry EEF-STALE matches no base or candidate finding"])

    def test_vulnerable_fixture_lock_fails_and_allowlisted_lock_passes(self):
        vulnerable_lock = b'  "bandit": {:hex, :bandit, "1.12.5"}'
        fixed_lock = b'  "bandit": {:hex, :bandit, "1.13.1"}'
        finding = ("bandit", "1.12.5", "EEF-HIGH", "HIGH")

        def fixture_audit(lock_bytes, _label):
            return {finding} if b'"1.12.5"' in lock_bytes else set()

        errors = audit.evaluate_locks(b"", vulnerable_lock, {}, fixture_audit)
        self.assertEqual(errors, ["bandit 1.12.5: unallowlisted HIGH advisory EEF-HIGH"])
        self.assertEqual(audit.evaluate_locks(b"", fixed_lock, {}, fixture_audit), [])
        self.assertEqual(
            audit.evaluate_locks(
                b"", vulnerable_lock,
                {"EEF-HIGH": {"accept_high": True}},
                fixture_audit,
            ),
            [],
        )

    def test_audit_uses_supplied_lock_without_resolving_dependencies(self):
        lock_bytes = b'  "bandit": {:hex, :bandit, "1.12.5"}'
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "mix.lock"
            commands = []

            def runner(command, **kwargs):
                commands.append((command, lock_path.read_bytes(), kwargs))
                return self.CLEAN if command[-1] == "hex.audit" else ""

            with patch.object(audit, "LOCK", lock_path):
                self.assertEqual(audit.audit_lock(lock_bytes, "fixture", runner), set())

        self.assertEqual([command[-1] for command, _, _ in commands], ["deps.get", "hex.audit"])
        self.assertTrue(all(audited_lock == lock_bytes for _, audited_lock, _ in commands))
        self.assertTrue(commands[1][2]["allow_advisories"])

    def test_audit_refuses_dependency_resolution_that_changes_lock(self):
        lock_bytes = b'  "bandit": {:hex, :bandit, "1.12.5"}'
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "mix.lock"

            def runner(command, **_kwargs):
                if command[-1] == "deps.get":
                    lock_path.write_bytes(b"rewritten lock")
                return ""

            with patch.object(audit, "LOCK", lock_path):
                with self.assertRaisesRegex(RuntimeError, "changed the lock"):
                    audit.audit_lock(lock_bytes, "fixture", runner)

    def test_audit_requires_recognized_clean_output(self):
        for output in ("", "garbage output"):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                lock_path = Path(directory) / "mix.lock"
                with patch.object(audit, "LOCK", lock_path):
                    with self.assertRaisesRegex(RuntimeError, "lacks a recognized clean result"):
                        audit.audit_lock(b"lock", "fixture", lambda command, **_: self.CLEAN if command[-1] == "deps.get" else output)

    def test_audit_rejects_one_unparsed_advisory_among_valid_findings(self):
        output = (
            "Advisories:\n"
            "  bandit 1.12.5 - EEF-HIGH (HIGH)\n"
            "    https://osv.dev/vulnerability/EEF-HIGH\n"
            "  decimal 3.1.1 - EEF-MEDIUM (UNKNOWN)\n"
            "    https://osv.dev/vulnerability/EEF-MEDIUM\n"
            "Found packages with security advisories\n"
        )
        with self.assertRaisesRegex(RuntimeError, "unparsed or unmatched advisories"):
            audit.parse_audit_output(output, "fixture")
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "mix.lock"

            def runner(command, **_kwargs):
                return self.CLEAN if command[-1] == "deps.get" else output

            with patch.object(audit, "LOCK", lock_path):
                with self.assertRaisesRegex(RuntimeError, "unparsed or unmatched advisories"):
                    audit.audit_lock(b"lock", "fixture", runner)

    def test_registry_cache_fallback_fails_closed(self):
        result = type("Result", (), {"stdout": "Failed to fetch record for bandit from registry (using cache instead)", "returncode": 0})()
        with patch.object(audit.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "refusing to use cached results"):
                audit.run(["mix", "hex.audit"], cwd=Path("."), allow_advisories=True)

    def test_hex_offline_fails_closed(self):
        with patch.dict(audit.os.environ, {"HEX_OFFLINE": "1"}):
            with self.assertRaisesRegex(RuntimeError, "HEX_OFFLINE is set"):
                audit.run(["mise", "exec", "--", "mix", "hex.audit"], cwd=Path("."), allow_advisories=True)

    def test_allowlist_entry_is_stale_after_candidate_fix_even_if_base_had_it(self):
        finding = ("decimal", "3.1.1", "EEF-MEDIUM", "MEDIUM")
        self.assertEqual(audit.evaluate({finding}, set(), {"EEF-MEDIUM": {}}), ["allow-list entry EEF-MEDIUM matches no base or candidate finding"])

    def test_parser_extracts_severity_and_id(self):
        output = (
            "Advisories:\n"
            "  bandit 1.12.5 - EEF-HIGH (HIGH)\n"
            "    https://osv.dev/vulnerability/EEF-HIGH\n"
            "  decimal 3.1.1 - EEF-MEDIUM (MEDIUM)\n"
            "    https://osv.dev/vulnerability/EEF-MEDIUM\n"
            "Found packages with security advisories\n"
        )
        self.assertEqual(audit.parse_findings(output), {("bandit", "1.12.5", "EEF-HIGH", "HIGH"), ("decimal", "3.1.1", "EEF-MEDIUM", "MEDIUM")})


if __name__ == "__main__":
    unittest.main()
