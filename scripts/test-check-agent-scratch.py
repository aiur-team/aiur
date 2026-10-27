#!/usr/bin/env python3
"""Exercise the PR diff guard against forbidden and allowed paths."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile


CHECKER = Path(__file__).with_name('check-agent-scratch.py')
SPEC = importlib.util.spec_from_file_location('check_agent_scratch', CHECKER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def git(root: Path, *args: str) -> None:
    subprocess.run(['git', '-C', str(root), *args], check=True, stdout=subprocess.DEVNULL)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix='agent-scratch-') as temporary:
        root = Path(temporary)
        git(root, 'init', '-q')
        git(root, 'config', 'user.email', 'test@example.invalid')
        git(root, 'config', 'user.name', 'Test')
        (root / 'README.md').write_text('base\n')
        git(root, 'add', 'README.md')
        git(root, 'commit', '-qm', 'base')
        base = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        for path in ('.agents/workpad-1.md', 'docs/pr-body-1.md'):
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('scratch\n')
        git(root, 'add', '-f', '.agents/workpad-1.md', 'docs/pr-body-1.md')
        git(root, 'commit', '-qm', 'add scratch')
        assert MODULE.forbidden('.agents/workpad-1.md')
        assert MODULE.forbidden('docs/pr-body-1.md')
        assert not MODULE.forbidden('.agents/skills/aiur-agent/SKILL.md')
        result = subprocess.run(
            [sys.executable, str(CHECKER), '--base', base], cwd=root,
            capture_output=True, text=True,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        assert '.agents/workpad-1.md' in result.stderr
        assert 'docs/pr-body-1.md' in result.stderr
        git(root, 'rm', '-q', '.agents/workpad-1.md', 'docs/pr-body-1.md')
        git(root, 'commit', '-qm', 'remove scratch')
        skill = root / '.agents/skills/example/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('skill\n')
        git(root, 'add', '.agents/skills/example/SKILL.md')
        git(root, 'commit', '-qm', 'add skill')
        result = subprocess.run(
            [sys.executable, str(CHECKER), '--base', base], cwd=root,
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (Path(__file__).resolve().parents[1] / 'scripts/pre-handoff-guards.list').read_text().find(
            'python3 scripts/check-agent-scratch.py --base <BASE_SHA>'
        ) >= 0
    print('test-check-agent-scratch: forbidden scratch paths rejected; skills-only diff passes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
