#!/usr/bin/env python3
"""Fail on machine paths and credential shapes in public research artifacts.

Only paths and line numbers are printed. This lexical check cannot decide
whether a quotation came from a private source; that still needs source review.
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    "absolute home path": re.compile(r"/(?:home|Users)/[A-Za-z0-9_.-]+/"),
    "encoded home path": re.compile(r"-home-(?!user(?:/|\b))[A-Za-z0-9_-]+"),
    "private path scaffold": re.compile(r"(?:/|\{)<private repo>"),
    "GitHub token": re.compile(r"(?:ghp_|gho_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]{12,}"),
    "OpenAI token": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    "AWS key": re.compile(r"\bAKIA[A-Z0-9]{16}\b"),
    "private key": re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----"),
}


def main() -> int:
    findings = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or path == Path(__file__).resolve():
            continue
        try:
            lines = path.read_text().splitlines()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(lines, 1):
            for label, pattern in PATTERNS.items():
                if label == "encoded home path" and "/tmp/aiur-home-" in line:
                    # A public test fixture uses this prefix for an isolated HOME.
                    continue
                if pattern.search(line):
                    findings.append(f"{path.relative_to(ROOT)}:{number}: {label}")
    print("\n".join(findings) if findings else "privacy lexical scan: clean")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
