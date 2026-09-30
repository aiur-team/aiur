"""Reproduce frozen review/simplify diff scope mismatches in a disposable repo."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("snapshot", type=Path)
args = parser.parse_args()
review = args.snapshot / ".claude/skills/ce-code-review"
persona = (review / "references/personas/data-migration-reviewer.md").read_text()
dispatch = (review / "references/dispatch-reviewers.md").read_text()
simplify = (args.snapshot / ".claude/skills/ce-simplify-code/SKILL.md").read_text()
assert "git diff <review-base> -- db/schema.rb" in persona
assert "(`BASE:` marker)" in dispatch
assert "configured upstream" in simplify and "git diff origin/main..." in simplify

with tempfile.TemporaryDirectory(prefix="review-diff-scope-") as td:
    root = Path(td)
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    def git(*argv, check=True):
        return subprocess.run(["git", "-C", td, *argv], env=env,
                              text=True, capture_output=True, check=check)
    git("init", "-q")
    git("config", "user.name", "Scope Fixture")
    git("config", "user.email", "scope@example.invalid")
    (root / "db/migrate").mkdir(parents=True)
    schema = root / "db/schema.rb"
    schema.write_text("base_schema\n")
    git("add", ".")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD").stdout.strip()
    git("checkout", "-qb", "feature")
    schema.write_text("base_schema\nrequested_column\n")
    (root / "db/migrate/001_add_column.rb").write_text("requested_migration\n")
    git("add", ".")
    git("commit", "-qm", "feature")
    head = git("rev-parse", "HEAD").stdout.strip()
    git("update-ref", "refs/remotes/origin/feature", head)
    git("update-ref", "refs/remotes/origin/main", base)
    upstream = git("diff", "origin/feature...").stdout
    proper = git("diff", "origin/main...").stdout
    assert not upstream and "requested_column" in proper
    schema.write_text("base_schema\nrequested_column\nuncommitted_column\n")
    branch_only = git("diff", "origin/main...").stdout
    tree_diff = git("diff", base).stdout
    assert "uncommitted_column" not in branch_only
    assert "uncommitted_column" in tree_diff
    git("checkout", "--", "db/schema.rb")
    git("checkout", "-q", "--detach", base)
    schema.write_text("base_schema\nambient_column\n")
    literal = git("diff", base, "--", "db/schema.rb").stdout
    bound = git("diff", base, head, "--", "db/schema.rb").stdout
    bad_marker = git("diff", "pr:123", "--", "db/schema.rb", check=False)
    assert "ambient_column" in literal and "requested_column" not in literal
    assert "requested_column" in bound and "ambient_column" not in bound
    assert bad_marker.returncode != 0
    print(json.dumps({
        "scope_marker_diff_rejected": bad_marker.returncode,
        "one_ended_diff_reads_ambient_tree": True,
        "two_endpoint_control_reads_requested_revision": True,
        "same_feature_upstream_diff_empty": True,
        "integration_base_control_nonempty": True,
        "triple_dot_omits_uncommitted_edit": True,
        "working_tree_control_includes_edit": True
    }, indent=2))
