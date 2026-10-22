"""Validate the shipped access ownership contract against tracked sources."""
import importlib.util
from pathlib import Path
import subprocess

from .manifest import read_manifest


def check():
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('component_checker', root / 'scripts/check-components.py')
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    # priv is outside the production scan roots; still validate its manifest assignment.
    checker.ROOTS = (*checker.ROOTS, 'src/priv')
    files = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).splitlines()
    manifest = read_manifest(root)
    problems, _, owners = checker.ownership(manifest, files)
    relevant = [(p, message) for p, message in problems if not p.startswith('src/priv/')
                or p == 'src/priv/github_budget.py' or p.startswith('src/priv/github_guard/gh/')]
    assert not relevant, relevant
    github_files = [p for p in files if p.startswith('src/lib/aiur/github/')]
    assert github_files and all(p in owners for p in github_files)
    assert owners['src/priv/github_budget.py'] == 'github-access'
    guard_files = [p for p in files if p.startswith('src/priv/github_guard/gh/')]
    assert guard_files and all(owners[p] == 'github-access' for p in guard_files)
    assert owners['src/lib/aiur/github/transport.ex'] == 'github-access'
    assert owners['src/lib/aiur/github/config.ex'] == 'github'
    assert owners['src/lib/aiur/github/queue_cost.ex'] == 'github'
    assert owners['src/lib/aiur/github/read_cache/policy.ex'] == 'github-access'
    assert owners['src/lib/aiur/github/resource_store/memory.ex'] == 'github-access'
    assert owners['src/lib/aiur/github/config/budget_sandbox_roots.ex'] == 'github'
    assert owners['src/lib/aiur/github/access_settings.ex'] == 'github'
    assert owners['src/lib/aiur/github/access/settings.ex'] == 'github-access'
    assert owners['src/lib/aiur/github/access/token.ex'] == 'github-access'
    # Future split files inherit the same owner without a manifest amendment.
    for stem in ('transport', 'quota', 'budget', 'credential', 'resource_store'):
        probes = [f'src/lib/aiur/github/{stem}_split.ex', f'src/lib/aiur/github/{stem}/split.ex']
        _, _, probe_owners = checker.ownership(manifest, files + probes)
        assert all(probe_owners[path] == 'github-access' for path in probes)
    print(f'PASS: GitHub access ownership ({len(github_files)} Elixir files; {len(guard_files)} wrapper parts)')
