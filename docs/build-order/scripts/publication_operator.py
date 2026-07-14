#!/usr/bin/env python3
"""Compatibility wrapper for the skill-owned Build Order publisher."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SKILL_SCRIPTS = ROOT / ".claude/skills/aiur-build/scripts"
sys.path.insert(0, str(SKILL_SCRIPTS))

from publish_build_order import main  # noqa: E402


if __name__ == "__main__":
    arguments = list(sys.argv)
    if "--build" not in arguments:
        arguments.extend(["--build", str(Path(__file__).resolve().parents[1] / "build-order.json")])
    raise SystemExit(main(arguments))
