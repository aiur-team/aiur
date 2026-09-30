"""Exercise the documented fetch against disposable local repositories only."""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

snapshot = Path(sys.argv[1])
scratch_parent = Path(sys.argv[2])
skill = snapshot / ".claude/skills/ce-code-review/SKILL.md"
source = skill.read_text()
match = re.search(r"`(git fetch --no-tags origin <headRefName>:refs/review/pr-<number>-head)`", source)
assert match, "documented fetch changed; reassess the probe"
documented = match.group(1)
env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")
def git(repo, *args):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Research Fixture",
         "-c", "user.email=fixture@example.invalid", *args],
        cwd=repo, env=env, stderr=subprocess.PIPE, text=True).strip()
def commit(repo, content):
    (repo / "reviewed.txt").write_text(content)
    git(repo, "add", "reviewed.txt")
    git(repo, "commit", "-m", "Fixture")
    return git(repo, "rev-parse", "HEAD")

with tempfile.TemporaryDirectory(prefix="review-head-", dir=scratch_parent) as temp:
    root = Path(temp)
    origin, fork, reviewer = [root / name for name in ("origin", "fork", "reviewer")]
    origin.mkdir()
    git(origin, "init", "-b", "main")
    commit(origin, "base\n")
    git(root, "clone", str(origin), str(fork))
    git(origin, "switch", "-c", "feature")
    origin_sha = commit(origin, "base-repository feature\n")
    git(fork, "switch", "-c", "feature")
    pr_head_sha = commit(fork, "fork PR feature\n")
    reviewer.mkdir()
    git(reviewer, "init", "-b", "main")
    git(reviewer, "remote", "add", "origin", str(origin))
    command = documented.replace("<headRefName>", "feature").replace("<number>", "7")
    args = shlex.split(command)
    assert args.pop(0) == "git"
    git(reviewer, *args)
    fetched = git(reviewer, "rev-parse", "refs/review/pr-7-head")
    assert fetched == origin_sha and fetched != pr_head_sha
    assert git(reviewer, "show", "refs/review/pr-7-head:reviewed.txt") == "base-repository feature"
    git(reviewer, "fetch", "--no-tags", str(fork), "feature:refs/review/control")
    assert git(reviewer, "rev-parse", "refs/review/control") == pr_head_sha
    assert git(reviewer, "show", "refs/review/control:reviewed.txt") == "fork PR feature"
    print(json.dumps({
        "documented_fetch": "succeeds_with_wrong_head",
        "same_named_origin_branch": "different_from_fork_PR_head",
        "correct_repository_control": "matches_expected_PR_head",
        "scope": "local Git command reproduction; no GitHub API or agent review execution"
    }, indent=2))
