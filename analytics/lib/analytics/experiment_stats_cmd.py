"""Atomic frozen-directory analysis and reproducibility checks."""

import argparse
from datetime import datetime, timezone
import difflib
import json
from pathlib import Path
import sys

from .materialize import _atomic_write
from .stats import analyze
from .stats.canonical import encode


def read(path):
    def reject_constant(value):
        raise ValueError(f"nonfinite JSON number: {value}")
    return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-dir", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--now", help="ISO8601 generated_at override (outside computed body)")
    args = parser.parse_args(argv)
    try:
        root = args.experiment_dir
        snapshot, spec = read(root / "snapshot.json"), read(root / "spec.json")
        annotations_path = root / "annotations.json"
        annotations = read(annotations_path) if annotations_path.exists() else {}
        body = analyze(snapshot, spec, annotations)
        path = root / "result.json"
        if args.check:
            stored = read(path)["body"]
            # Do not round the stored body: even a sub-precision hand edit must fail.
            expected = json.dumps(body, sort_keys=True, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
            actual = json.dumps(stored, sort_keys=True, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
            if actual != expected:
                sys.stderr.writelines(difflib.unified_diff(actual.splitlines(True), expected.splitlines(True),
                                                         fromfile="result.json/body", tofile="recomputed/body"))
                return 1
            print("experiment result body matches")
            return 0
        now = args.now or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        from .stats.inputs import timestamp
        timestamp(now)
        _atomic_write(path, encode({"generated_at": now, "body": body}))
        return 0
    except (ValueError, TypeError, KeyError, AttributeError, OSError, OverflowError) as error:
        print(f"experiment-stats: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
