#!/usr/bin/env python3
"""Exercise Git's ignored-directory -> tracked-symlink transition in real Codex.

Run: mise exec -- python3 scripts/test-codex-skills-integration.py --codex /path/to/codex
Inside an existing Codex sandbox, add --private-tmp (requires Bubblewrap).
The private tmpfs keeps the nested sandbox's sockets and mount registry separate
from the outer sandbox's protected daemon paths. No Aiur run or tracker is used.
Requires a Codex CLI with `sandbox --permission-profile` support.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def run(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=kwargs.pop("stderr", subprocess.STDOUT), **kwargs)


def git(workspace, *args):
    result = run(["git", "-C", str(workspace), *args])
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


def fixture(root):
    source = root / "source"
    source.mkdir()
    workspace = source
    git(workspace, "init", "-b", "main")
    git(workspace, "config", "user.name", "Skills Regression")
    git(workspace, "config", "user.email", "skills@example.invalid")
    skill = workspace / ".claude/skills/aiur-agent/SKILL.md"
    skill.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / ".claude/skills/aiur-agent/SKILL.md", skill)
    git(workspace, "add", ".claude")
    git(workspace, "commit", "-m", "Before tracked skills link")
    checkout = root / "checkout"
    git(workspace, "clone", str(source), str(checkout))
    (workspace / ".agents").mkdir()
    (workspace / ".agents/skills").symlink_to("../.claude/skills")
    git(workspace, "add", ".agents/skills")
    git(workspace, "commit", "-m", "Track skills link")
    workspace = checkout
    git(workspace, "config", "user.name", "Skills Regression")
    git(workspace, "config", "user.email", "skills@example.invalid")
    git(workspace, "fetch", "origin")
    skill = workspace / ".claude/skills/aiur-agent/SKILL.md"
    (workspace / "feature.txt").write_text("preserve the feature branch\n")
    git(workspace, "add", "feature.txt")
    git(workspace, "commit", "-m", "Worker change")
    # Provisioning on an old tree leaves an ignored Muse skills directory.
    # The newer tracked symlink must replace this directory during the merge.
    installed = workspace / ".agents/skills/aiur-agent/SKILL.md"
    installed.parent.mkdir(parents=True)
    shutil.copyfile(skill, installed)
    (workspace / ".codex").mkdir()
    (workspace / ".codex/skills").symlink_to("../.claude/skills")
    with (workspace / ".git/info/exclude").open("a") as exclude:
        exclude.write("\n/.agents/skills/\n/.codex/\n")
    assert git(workspace, "status", "--porcelain") == ""
    return workspace, skill.read_text()


def runtime_roots(workspace):
    # Load the production modules directly: no daemon, dependencies, or copied
    # policy implementation. This also permits isolated worktree mutation runs.
    code = """
    [workspace] = System.argv()
    {:ok, policy} = Aiur.Config.CodexSandboxPolicy.resolve_runtime(nil, workspace, nil)
    Enum.each(policy["writableRoots"], &IO.puts/1)
    """
    result = run(["mise", "exec", "--", "elixir",
                  "-r", str(ROOT / "src/lib/aiur/path_safety.ex"),
                  "-r", str(ROOT / "src/lib/aiur/config/codex_sandbox_policy.ex"),
                  "-e", code, "--", str(workspace)], cwd=ROOT, stderr=subprocess.PIPE, check=True)
    return result.stdout.strip().splitlines()


def sandbox(codex, workspace, roots, command, private_tmp):
    filesystem = {":root": "read", ":tmpdir": "write", ":minimal": "read"}
    filesystem.update({root: "write" for root in roots})
    config = "permissions.aiur-skills-regression.filesystem={" + ",".join(
        json.dumps(key) + "=" + json.dumps(value)
        for key, value in filesystem.items()) + "}"
    args = [codex, "sandbox", "-P", "aiur-skills-regression", "-c", config,
            "-C", str(workspace), "--", *command]
    if private_tmp:
        args = ["bwrap", "--bind", "/", "/", "--tmpfs", "/tmp",
                "--dev", "/dev", "--setenv", "TMPDIR", "/tmp", "--", *args]
    return run(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--private-tmp", action="store_true")
    options = parser.parse_args()
    if not options.codex:
        parser.error("Codex CLI is required")
    with tempfile.TemporaryDirectory(prefix="2978-skills-", dir=os.environ.get("TMPDIR")) as tmp:
        workspace, expected_skill = fixture(Path(tmp))
        roots = runtime_roots(workspace)
        # Control proves that the fixture reaches the original failure mode.
        baseline = [root for root in roots if root != str(workspace / ".agents")]
        command = ["git", "-C", str(workspace), "merge", "--no-edit", "origin/main"]
        broken = sandbox(options.codex, workspace, baseline, command, options.private_tmp)
        assert broken.returncode != 0 and ".agents/skills" in broken.stdout and "Read-only file system" in broken.stdout, broken.stdout
        print("Baseline: merge fails on read-only .agents/skills")
        fixed = sandbox(options.codex, workspace, roots, command, options.private_tmp)
        assert fixed.returncode == 0, fixed.stdout
        assert (workspace / "feature.txt").read_text() == "preserve the feature branch\n"
        assert (workspace / ".agents/skills").is_symlink()
        for path in [".agents/skills/aiur-agent/SKILL.md", ".codex/skills/aiur-agent/SKILL.md"]:
            result = sandbox(options.codex, workspace, roots,
                             ["cat", str(workspace / path)], options.private_tmp)
            assert result.returncode == 0 and expected_skill in result.stdout, result.stdout
        protected = sandbox(options.codex, workspace, roots,
                            ["touch", str(workspace / ".codex/should-stay-protected")], options.private_tmp)
        assert protected.returncode != 0 and "should-stay-protected" in protected.stdout and "Read-only file system" in protected.stdout, protected.stdout
        print("Runtime policy: merge passes; feature and skills retained; .codex stays read-only")


if __name__ == "__main__":
    main()
