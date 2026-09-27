"""Run the frozen policy test unchanged in a disposable Git repository.
Usage: python3 tooling/github_body_policy_probe.py SNAPSHOT ELIXIR
No application boot, network requests, or production edits.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

snapshot, elixir = sys.argv[1:]
source = Path(snapshot) / "src/test/aiur/github_body_file_policy_test.exs"
with tempfile.TemporaryDirectory(prefix="aiur-policy-probe-") as directory:
    root = Path(directory)
    test = root / "src/test/aiur/github_body_file_policy_test.exs"
    test.parent.mkdir(parents=True)
    test.write_bytes(source.read_bytes())
    script = root / "scripts/example.sh"
    script.parent.mkdir()
    def git(*args):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
    def check(name):
        result = subprocess.run(
            [elixir, "-e", "ExUnit.start(); Code.require_file(hd(System.argv()))", str(test)],
            cwd=root, text=True, capture_output=True)
        if result.returncode not in (0, 2):
            print(result.stderr, file=sys.stderr)
        summaries = [line for line in result.stdout.splitlines() if "tests," in line]
        return {"case": name, "exit_code": result.returncode, "summary": summaries}
    git("init", "-q")
    script.write_text('gh pr comment 42 --body-file "$reply_file"\n')
    git("add", "scripts/example.sh")
    results = [check("safe_index_safe_worktree")]
    script.write_text('gh pr comment 42 --body "$reply"\n')
    results.append(check("safe_index_unsafe_worktree"))
    git("add", "scripts/example.sh")
    results.append(check("unsafe_index_unsafe_worktree"))
    print(json.dumps(results, indent=2))
    assert [row["exit_code"] for row in results] == [0, 0, 2], results
