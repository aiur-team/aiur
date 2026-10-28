"""Reuse the portable meta skill's canonical feature-share classification."""
from pathlib import Path
import runpy

classify = runpy.run_path(str(Path(__file__).resolve().parents[2] /
                             ".claude/skills/aiur-meta/scripts/classification.py"))["classify"]
