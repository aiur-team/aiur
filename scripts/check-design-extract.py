#!/usr/bin/env python3
"""Verify a split design extract still concatenates to its recorded sha256.

Usage: check-design-extract.py <manifest.json>
Parts are read from the manifest's directory, in manifest order.
"""
import hashlib
import json
import sys
from pathlib import Path


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    manifest = Path(argv[1])
    data = json.loads(manifest.read_text())
    blob = b"".join((manifest.parent / p["file"]).read_bytes() for p in data["parts"])
    got = hashlib.sha256(blob).hexdigest()
    if got != data["sha256"]:
        print(f"FAIL: parts hash {got}, manifest records {data['sha256']}", file=sys.stderr)
        return 1
    print(f"ok: {len(data['parts'])} parts match {got}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
