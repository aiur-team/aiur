"""Canonical pack JSON: top-level keys and array records each get a line."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def format_pack(data: dict) -> str:
    def compact(value):
        return json.dumps(value, ensure_ascii=False, separators=(", ", ": "))

    lines = []
    for key, value in data.items():
        prefix = "  " + compact(key) + ": "
        if isinstance(value, list) and value:
            records = ["    " + compact(item) for item in value]
            lines.append(prefix + "[\n" + ",\n".join(records) + "\n  ]")
        else:
            lines.append(prefix + compact(value))
    return "{\n" + ",\n".join(lines) + "\n}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()
    failed = False
    for path in args.files:
        original = path.read_bytes()
        canonical = format_pack(json.loads(original)).encode("utf-8")
        if args.check:
            if original != canonical:
                print(f"{path}: noncanonical pack layout")
                failed = True
        else:
            path.write_bytes(canonical)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
