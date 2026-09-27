#!/usr/bin/env python3
"""Evaluate only the two pure launcher classification functions, never launch/build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def probe(snapshot):
    source = (snapshot / 'scripts/aiurdev').read_text()
    functions = []
    for name in ('pure_control_command', 'builds_after_stop'):
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)
        if not match:
            raise ValueError('Missing classification function: ' + name)
        functions.append(match[0])
    script = '\n'.join(functions) + '''
for command in status agents pause resume stop message executor-wait watch restart build; do
  if builds_after_stop "$command"; then
    kind=after_stop
  elif pure_control_command "$command"; then
    kind=control_surface
  else
    kind=ensure_built
  fi
  printf '%s %s\\n' "$command" "$kind"
done
'''
    result = subprocess.run(['bash', '-c', script], check=True, capture_output=True, text=True)
    return {'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
            'method': 'Extract and evaluate only pure_control_command and builds_after_stop. Classify the same-checkout dispatch branch. The full launcher, build, daemon and control commands are never executed.',
            'same_checkout_classification': dict(line.split() for line in result.stdout.splitlines()),
            'limits': 'ensure_built checks whether rebuilding is required; classification alone does not say every invocation rebuilds. Divergent-checkout control paths use ensure_control_surface instead. Missing/incomplete releases may trigger repair builds even through ensure_control_surface. AIUR_SKIP_BUILD overrides must be considered separately.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    print(json.dumps(probe(args.snapshot), indent=2))
