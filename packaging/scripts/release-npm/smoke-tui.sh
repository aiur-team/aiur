#!/usr/bin/env bash
# Boot the installed aiur in tmux against a memory-tracker fixture and assert
# the TUI renders.
set -euo pipefail
mkdir -p fixture/.aiur
# `.aiur/config` is plain YAML. It is NOT the old `.aiurconfig`
# front-matter form (`---` / config / `---` / markdown body): wrapping
# it in document markers makes the parser yield an empty config, so
# every key here is silently ignored — including base_branch, whose
# absence then raises at boot as if the key were never written.
cat > fixture/.aiur/config <<'YAML'
tracker:
  kind: memory
  # Required: Config.base_branch/2 raises rather than defaulting, so a
  # fixture without it fails the boot with an unresolved-config error
  # that reads like a packaging fault rather than a missing key.
  base_branch: main
polling:
  interval_seconds: 5
max_vertical_panes: 3
pre_warmed_sessions: 0
server:
  host: 127.0.0.1
  port: 4000
workspace:
  root: /tmp/aiur-smoke-workspaces
YAML
cd fixture
tmux new-session -d -s smoke -x 200 -y 50 "cd $PWD; aiur >run.log 2>&1"
for i in $(seq 1 40); do
  tmux capture-pane -t smoke -p 2>/dev/null | grep -q 'AIUR' && break
  sleep 1
done
tmux capture-pane -t smoke -p | tee pane.txt || true
tmux send-keys -t smoke q 2>/dev/null || true
if ! grep -q 'AIUR' pane.txt; then
  echo "TUI did not render; run log:" >&2
  cat run.log >&2 || true
  exit 1
fi
