"""Put the skill-owned publication modules on the import path."""

from __future__ import annotations

import sys
from pathlib import Path


SKILL_SCRIPTS = Path(__file__).resolve().parents[3] / ".claude/skills/aiur-build/scripts"
for _path in (SKILL_SCRIPTS, SKILL_SCRIPTS / "publication"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))
