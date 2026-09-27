"""Exercise the frozen engine in two temporary checkouts of a local bare repo."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("snapshot", type=Path)
args = parser.parse_args()
engine = args.snapshot.resolve() / ".claude/skills/ce-sweep/scripts/sweep-state.py"

def git(where, *args):
    return subprocess.check_output(
        ["git", "-C", str(where), *args], text=True, stderr=subprocess.PIPE
    ).strip()

def call(where, command, *args):
    result = subprocess.run(
        [sys.executable, str(engine), command, "--state", str(where / "state.yml"), *args],
        text=True, capture_output=True, check=True,
    )
    lines = result.stdout.splitlines()
    return lines[0], json.loads(lines[1]) if len(lines) > 1 else None

def configure(where):
    git(where, "config", "user.name", "Research Fixture")
    git(where, "config", "user.email", "fixture@example.invalid")

def publish(where, message):
    git(where, "add", "state.yml")
    git(where, "commit", "-m", message)
    git(where, "push", "origin", "HEAD:main")
    git(where, "fetch", "origin")
    assert git(where, "rev-parse", "HEAD") == git(where, "rev-parse", "origin/main")

with tempfile.TemporaryDirectory(prefix="sweep-lease-probe-") as temp:
    root = Path(temp)
    remote, a, b = [root / x for x in ("remote.git", "a", "b")]
    subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(remote)],
                   check=True, capture_output=True)
    git(root, "clone", str(remote), str(a))
    configure(a)
    assert call(a, "lease-acquire", "--writer", "A", "--ttl-minutes", "60",
                "--now", "2026-01-01T00:00:00+00:00")[0] == "OK"
    publish(a, "Acquire A")
    # A refreshes its local lease during work; the remote still has acquisition time.
    assert call(a, "upsert-item", "--writer", "A", "--source", "fixture",
                "--id", "1", "--json", '{"status":"acknowledged"}',
                "--now", "2026-01-01T00:50:00+00:00")[0] == "OK"
    git(root, "clone", str(remote), str(b))
    configure(b)
    takeover = call(b, "lease-acquire", "--writer", "B", "--ttl-minutes", "60",
                    "--now", "2026-01-01T01:01:00+00:00")[0]
    assert takeover == "STALE-RECLAIMED"
    publish(b, "Acquire B")
    stale_write = call(a, "upsert-item", "--writer", "A", "--source", "fixture",
                      "--id", "2", "--json", '{"status":"acknowledged"}',
                      "--now", "2026-01-01T01:02:00+00:00")[0]
    assert stale_write == "OK"
    # Control: the same stale writer is rejected against the current shared state.
    current_write = call(b, "upsert-item", "--writer", "A", "--source", "fixture",
                        "--id", "3", "--json", '{"status":"acknowledged"}',
                        "--now", "2026-01-01T01:02:00+00:00")[0]
    assert current_write == "LEASE-LOST"
    # Follow the prescribed wrap-up order in B: publish, then record and release.
    assert call(b, "upsert-item", "--writer", "B", "--source", "fixture",
                "--id", "4", "--json", '{"status":"acknowledged"}',
                "--now", "2026-01-01T01:02:00+00:00")[0] == "OK"
    publish(b, "Publish final item state")
    assert call(b, "run-record", "--writer", "B", "--outcome", "completed",
                "--counts", "{}", "--timestamp", "2026-01-01T01:03:00+00:00")[0] == "OK"
    assert call(b, "lease-release", "--writer", "B")[0] == "OK"
    local = call(b, "read")[1]
    remote_state = git(b, "show", "origin/main:state.yml")
    assert "lease" not in local
    assert "lease:" in remote_state
    assert '"completed"' not in remote_state
    assert git(b, "status", "--porcelain", "--", "state.yml")
    print(json.dumps({
        "takeover": takeover,
        "old_checkout_write": stale_write,
        "current_checkout_control": current_write,
        "local_release_and_completion_unpublished": True,
        "scope": "Local Git and actual frozen engine; no source-side API writes."
    }, indent=2))
