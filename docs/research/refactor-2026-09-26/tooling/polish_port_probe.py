"""Run the frozen port helper against two equivalent script maps."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("snapshot", type=Path)
args = parser.parse_args()
helper = args.snapshot / ".claude/skills/ce-polish/scripts/resolve-port.sh"
results = []
with tempfile.TemporaryDirectory(prefix="polish-port-probe-") as td:
    root = Path(td)
    pairs = [("test", "test-tool --port 9123"), ("dev", "vite --port 5174")]
    for entries in (pairs, list(reversed(pairs))):
        (root / "package.json").write_text(json.dumps({"scripts": dict(entries)}))
        result = subprocess.run(["bash", str(helper), td, "--type", "vite"],
                                text=True, capture_output=True, check=True)
        results.append({"script_order": list(dict(entries)), "port": result.stdout.strip()})
assert results[0]["port"] == "9123", results
assert results[1]["port"] == "5174", results
print(json.dumps(results, indent=2))
