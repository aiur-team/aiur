---
tracker:
  kind: github
  active_states:
    - todo
    - in-progress
  terminal_states:
    - done
github:
  repo: test-org/test-repo
  label_prefix: agent
polling:
  interval_seconds: 5
max_vertical_panes: 3
pre_warmed_sessions: 3
server:
  host: 127.0.0.1
  port: 4000
workspace:
  root: /tmp/aiur-test-workspaces
hooks:
  after_create: |
    echo "noop"
  before_run: |
    echo "noop"
  before_remove: |
    echo "noop"
agent:
  max_turns: 12
events:
  block_state_debounce_seconds: 30
  custom_events_per_turn_max: 10
  codeowners_refresh_seconds: 3600
---

# Test Workflow

Minimal workflow used as a CI/test fallback when no per-machine
`WORKFLOW.md` or `local-workflows/WORKFLOW.aiur.local.md` is present.
Real config lives in those untracked files; this fixture only exists
so `Aiur.Config.settings!/0` can load during tests.
