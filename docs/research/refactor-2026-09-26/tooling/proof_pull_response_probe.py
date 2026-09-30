#!/usr/bin/env python3
"""Exercise the frozen Proof pull write command with synthetic responses; no network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]) / ".claude/skills/ce-proof/SKILL.md"
command = next(line for line in source.read_text().splitlines()
               if line.startswith("jq -jr '.markdown'"))
assert command == 'jq -jr \'.markdown\' "$STATE_TMP" > "$TMP" && mv "$TMP" "$LOCAL"'
command = command.rstrip()
cases = [
    ("document", json.dumps({"ok": True, "markdown": "# Valid\n\n"}), "# Valid\n\n"),
    ("error", json.dumps({"ok": False, "error": {"code": "AUTH"}}), "null"),
    ("empty_response", "", ""),
    ("malformed_json", "{", "original document"),
]
with tempfile.TemporaryDirectory(prefix="proof-pull-probe-") as directory:
    root = Path(directory)
    for name, response, expected in cases:
        local, state, temporary = (root / item for item in ("local.md", "response.json", "next.md"))
        local.write_text("original document")
        state.write_text(response)
        result = subprocess.run(["bash", "-c", command], env={
            **os.environ, "LOCAL": str(local), "STATE_TMP": str(state), "TMP": str(temporary)
        }, capture_output=True, text=True)
        actual = local.read_text()
        assert actual == expected, (name, actual, expected)
        assert (result.returncode == 0) == (name != "malformed_json")
        print(json.dumps({"case": name, "exit": result.returncode, "local_content": actual}))
