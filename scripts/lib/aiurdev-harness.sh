#!/usr/bin/env bash
# shellcheck shell=bash
#
# aiurdev rebuild entry point and dev test/debug harness.
# Sourced by scripts/aiurdev (dev-only; not part of the npm package). Shares its
# variables and functions; do not execute directly.

# Internal entry point for the rebuild `aiur restart` runs between its stop and
# its start (the engine invokes it through AIUR_RESTART_BUILD_CMD). It is a
# separate process so it takes the build lock in its own right, and it applies
# the same build-if-stale rule as any other dev launch: a release the sources
# have not outrun is already the latest build, and a forced rebuild of an
# unchanged tree would only lengthen the window where no daemon is running. Use
# `aiurdev build` when you want the unconditional force-rebuild.
#
# It sits ABOVE the tmux guard on purpose. It starts no session, so the guard
# does not apply — and an inherited $TMUX would otherwise make a rebuild that
# never ran look like a failed one, with the daemon already stopped.
if [ "${1:-}" = "__ensure-build" ]; then
  # The fleet is down for the whole of this step, including any wait for a
  # rebuild another shell is holding the lock for. Say so, so a long wait reads
  # as an outage the operator can act on rather than an idle prompt.
  echo "🔁 refreshing the release; the daemon is stopped until this finishes" >&2
  ensure_build_status=0
  ensure_built || ensure_build_status=$?
  if [ "$ensure_build_status" -eq 0 ]; then
    write_restart_receipt
  fi
  exit "$ensure_build_status"
fi

# Refuse a cwd/target mismatch before anything is built, started, or stopped.
# `__ensure-build` above is exempt: it runs with AIUR_REPO_ROOT pinned by the
# parent that already passed this guard, mid-restart with the daemon down, where
# a refusal would only strand the fleet on a decision already made.
guard_checkout_target "$@"

# `aiur upgrade` installs a published npm release. It can never make sense
# under a development launcher, and the acceptance contract is that it changes
# nothing on disk here — so refuse before anything is built, started, or
# touched. The shared engine refuses dev release dirs too; this is the launcher
# check that fires even before a build would be considered (#2109).
if [ "${1:-}" = "upgrade" ]; then
  echo "❌ aiur upgrade cannot run under aiurdev (a development checkout)." >&2
  echo "   aiurdev runs code built from the local tree; aiur upgrade installs a published" >&2
  echo "   npm release and would not touch this working tree. Nothing has been changed." >&2
  echo "   Install aiur from npm and run \`aiur upgrade\` from the installed CLI instead." >&2
  exit 64
fi

# aiur spawns its own tmux on a dedicated socket and does not nest cleanly.
if [ -n "${TMUX:-}" ]; then
  echo "❌ already inside a tmux session (\$TMUX is set)" >&2
  echo "Open a fresh terminal without tmux and try again." >&2
  exit 1
fi

# `aiurdev build` force-rebuilds; otherwise rebuild only when stale.
if [ "${1:-}" = "build" ]; then
  acquire_build_lock
  trap 'release_build_lock' EXIT INT TERM
  build_status=0
  if [ "${2:-}" = "--deps" ]; then
    echo "🔨 clean force-rebuild incl. deps (wiping _build/dev)" >&2
    rm -rf "$elixir_dir/_build/dev"
    ensure_elixir_deps || build_status=$?
  else
    echo "🔨 force-rebuild aiur app + release (keeping dep artifacts)" >&2
    rm -rf "$elixir_dir/_build/dev/rel"
    ensure_elixir_deps || build_status=$?
    require_mise || build_status=$?
  fi
  if [ "$build_status" -eq 0 ]; then
    build_aiur || build_status=$?
  fi
  release_build_lock
  trap - EXIT INT TERM
  exit "$build_status"
fi

# --- dev test/debug harness (dev-only; never lives in the shared engine) -------
# These flags don't exist in the product CLI. The shim consumes them, turns them
# into a GitHub sandbox reset + AIUR_DEBUG, then hands the rest to the engine for
# a normal foreground run.
#
#   --test    reset the single sandbox ticket (issue 99) then launch
#   --test3   reset the 3-ticket blocker chain (drives the remote agent) then launch
#   --debug   verbose logging (AIUR_DEBUG=1)
#   --clear   delete this instance's inactive log sessions (requires --debug)
debug_mode=0
clear_mode=0
test_single=0
test3_mode=0
allow_remote=0
has_port=0
expect_port_value=0
passthrough=()
for arg in "$@"; do
  if [ "$expect_port_value" -eq 1 ]; then
    passthrough+=("$arg")
    expect_port_value=0
    continue
  fi

  case "$arg" in
    --debug) debug_mode=1 ;;
    --clear) clear_mode=1 ;;
    --allow-remote) allow_remote=1 ;;
    --force) passthrough+=("$arg") ;; # forward to the engine (e.g. `init --force`)
    --port) has_port=1; passthrough+=("$arg"); expect_port_value=1 ;;
    --port=*) has_port=1; passthrough+=("$arg") ;;
    --test) test_single=1 debug_mode=1 clear_mode=1 ;;
    --test3) test3_mode=1 debug_mode=1 allow_remote=1 ;;
    *) passthrough+=("$arg") ;;
  esac
done

if [ "$expect_port_value" -eq 1 ]; then
  echo "❌ --port requires a value (e.g. --port 0 or --port=4000)" >&2
  exit 64
fi

if [ "$clear_mode" -eq 1 ] && [ "$debug_mode" -ne 1 ]; then
  echo "❌ --clear requires --debug (e.g. aiurdev --debug --clear)" >&2
  exit 64
fi

agent_workspace_marker=""
if marker="$(in_agent_workspace_tree)"; then
  agent_workspace_marker="$marker"
fi

if [ -n "$agent_workspace_marker" ] && { [ "$test_single" -eq 1 ] || [ "$test3_mode" -eq 1 ]; }; then
  echo "❌ manual --test runs are blocked inside agent workspaces" >&2
  echo "   workspace marker: $agent_workspace_marker" >&2
  echo "   This path resets pinned GitHub sandbox tickets and can mutate the live dogfood backlog." >&2
  echo "   Agents must stop here: do not retry from a copied /tmp harness, clone, or alternate checkout." >&2
  echo "   Executor-root manual test runs remain allowed outside agent turns." >&2
  exit 64
fi

# These are internal launch values. Clear inherited copies before deciding
# whether this invocation is scoped, then set them only for the pinned test run.
# Validate the scope before build, log clearing, stop, or GitHub reset so an
# unreadable pinned file cannot start an unbounded test run.
unset AIUR_DEV_TEST_TICKET_IDS AIUR_GITHUB_BUDGET_DIR AIUR_DEV_TEST_STATE_DIR AIUR_DEV_TEST_RUN_ID
test_scope_ids=""
if [ "$test_single" -eq 1 ] || [ "$test3_mode" -eq 1 ]; then
  tickets_file="$repo_root/.aiur-test-tickets.json"
  if ! command -v jq >/dev/null 2>&1 || [ ! -r "$tickets_file" ]; then
    echo "❌ test launch requires jq and a readable $tickets_file; no tickets were reset" >&2
    exit 64
  fi

  if ! test_scope_ids="$(jq -er --argjson single "$test_single" '
    .tickets
    | if type == "array" and length > 0 and all(.[]; type == "number" and . > 0 and floor == .)
      then (if $single == 1 then .[0:1] else . end | map(tostring) | join(","))
      else error("invalid pinned tickets") end
  ' "$tickets_file" 2>/dev/null)"; then
    echo "❌ test launch requires positive pinned ticket IDs in $tickets_file; no tickets were reset" >&2
    exit 64
  fi
fi

if [ -n "$agent_workspace_marker" ]; then
  enable_agent_ir_sandbox "$agent_workspace_marker" 0
fi

if builds_after_stop "${passthrough[0]:-}"; then
  # Normally a no-op: a complete release is already there and the real rebuild
  # waits until the daemon is down. When there is no complete release, the stop
  # itself cannot run without one, so the repair build necessarily lands before
  # the stop — announce that inversion instead of performing it silently.
  release_ready || echo "⚠️  no complete release; building one BEFORE the stop (this rewrites the release the running daemon booted from)" >&2
  ensure_control_surface
elif pure_control_command "${passthrough[0]:-}" || [ "$checkout_diverges" -eq 1 ]; then
  # The divergent case reaches here only for commands the guard let through, and
  # those must not rebuild a checkout the operator is not standing in. Reusing
  # the complete release is exactly what a control command needs anyway.
  ensure_control_surface
else
  ensure_built
fi

[ "$debug_mode" -eq 1 ] && export AIUR_DEBUG=1
if [ "$clear_mode" -eq 1 ]; then
  clear_key="$("$engine" __identity | sed -n 's/^AIUR_INSTANCE_KEY=//p')"
  bash "$script_dir/aiur-clear-logs" "${AIUR_AGENT_IR_LOGS_PARENT:-$HOME/.aiur/logs}" "$clear_key"
fi

if [ "$test_single" -eq 1 ] || [ "$test3_mode" -eq 1 ]; then
  reset_cmd=(mix aiur.test.reset)
  require_mise || exit 64
  echo "🛑 stopping any running aiur" >&2
  "$engine" stop >/dev/null 2>&1 || true

  export AIUR_DEV_TEST_TICKET_IDS="$test_scope_ids"
  AIUR_GITHUB_BUDGET_DIR=""
  AIUR_DEV_TEST_STATE_DIR=""

  cleanup_test_launch_state() {
    local path recorded_ids basename
    for path in "${AIUR_GITHUB_BUDGET_DIR:-}" "${AIUR_DEV_TEST_STATE_DIR:-}"; do
      [ -n "$path" ] || continue
      basename="${path##*/}"
      case "$basename" in
        aiur-test-budget.*|aiur-test-state.*) ;;
        *) continue ;;
      esac
      [ -f "$path/.aiur-test-private" ] || continue
      recorded_ids="$(cat "$path/.aiur-test-private" 2>/dev/null || true)"
      [ "$recorded_ids" = "$test_scope_ids" ] || continue
      rm -rf -- "$path"
    done
  }
  trap cleanup_test_launch_state EXIT

  AIUR_GITHUB_BUDGET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiur-test-budget.XXXXXX")" || {
    echo "❌ could not create isolated GitHub budget directory" >&2
    exit 1
  }
  export AIUR_GITHUB_BUDGET_DIR
  AIUR_DEV_TEST_RUN_ID="${AIUR_GITHUB_BUDGET_DIR##*/}"
  export AIUR_DEV_TEST_RUN_ID
  printf '%s\n' "$test_scope_ids" >"$AIUR_GITHUB_BUDGET_DIR/.aiur-test-private"
  AIUR_DEV_TEST_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiur-test-state.XXXXXX")" || {
    echo "❌ could not create isolated Executor state directory" >&2
    exit 1
  }
  export AIUR_DEV_TEST_STATE_DIR
  printf '%s\n' "$test_scope_ids" >"$AIUR_DEV_TEST_STATE_DIR/.aiur-test-private"

  reset_args=("--confirm" "--force")
  [ "$test_single" -eq 1 ] && reset_args+=("--single")
  [ "$allow_remote" -eq 1 ] && reset_args+=("--allow-remote")
  if [ "${AIUR_AGENT_IR_SANDBOX:-}" = "1" ]; then
    reset_cmd=(env "XDG_CONFIG_HOME=${AIUR_AGENT_IR_XDG_CONFIG_HOME:?}" "XDG_STATE_HOME=${AIUR_AGENT_IR_XDG_STATE_HOME:?}" "${reset_cmd[@]}")
  fi
  if ! (cd "$elixir_dir" && "$mise_bin" exec -- "${reset_cmd[@]}" "${reset_args[@]}"); then
    echo "❌ test reset failed; refusing to launch. Inspect the output above." >&2
    exit 1
  fi

  # GitHub's label index is eventually consistent — wait until the pinned
  # tickets show under agent:todo (or fall through after 30s) so the
  # orchestrator's first poll doesn't miss a freshly-labelled ticket.
  tickets_file="$repo_root/.aiur-test-tickets.json"
  expected=0
  if command -v jq >/dev/null 2>&1 && [ -r "$tickets_file" ]; then
    if [ "$test_single" -eq 1 ]; then
      expected=1
    else
      expected="$(jq -r '.tickets | length' "$tickets_file" 2>/dev/null || echo 0)"
    fi
  fi
  if [ "$expected" -gt 0 ]; then
    echo "⏳ settling GitHub label index" >&2
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
      actual="$(gh issue list --label agent:todo --json number 2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)"
      [ "$actual" -ge "$expected" ] && break
      sleep 1
    done
  fi
fi

# --test3 wall-clock timer: a detached poller that appends a JSON line to
# .aiur-test3-runs.jsonl when all 3 tickets reach agent:human-review (or 90m).
if [ "$test3_mode" -eq 1 ]; then
  pid_file="$repo_root/.aiur-test3-timer.pid"
  if [ -r "$pid_file" ]; then
    prior_pid="$(cat "$pid_file" 2>/dev/null || true)"
    { [ -n "$prior_pid" ] && kill -0 -- "-$prior_pid" 2>/dev/null && kill -- "-$prior_pid" 2>/dev/null; } || true
    rm -f "$pid_file"
  fi
  timer="$repo_root/scripts/aiur-test3-timer"
  if [ -x "$timer" ]; then
    echo "⏱  test3 timer started (results append to .aiur-test3-runs.jsonl)" >&2
    "$script_dir/aiur-test3-start-timer" "$repo_root" "$timer" "$(date +%s)" || exit 1
  fi
fi

export AIUR_RELEASE_DIR="$release_dir"

# The dev half of `aiur restart`: the engine owns the stop/build/start ordering,
# this shim owns what "build" means here. %q keeps a repo path with spaces intact
# through the engine's `bash -c`. Exported only for the command that consumes it,
# so no daemon or agent process inherits a rebuild bound to this checkout.
#
# AIUR_REPO_ROOT is pinned into the command rather than left to the child's own
# path resolution: the target was settled here, and re-deriving it in a process
# the engine launches from the operator's cwd is the very ambiguity this restart
# is supposed to have eliminated by the time it stops the daemon.
#
# AIUR_SKIP_BUILD excludes it entirely rather than wiring in a rebuild that will
# decline to build: the engine would stop the daemon, get a success it cannot
# match to the release on disk, and refuse to start. Skipping the build means
# `restart` is a plain bounce, which is what asking to skip the build asks for.
if builds_after_stop "${passthrough[0]:-}" && [ "${AIUR_SKIP_BUILD:-0}" != "1" ]; then
  printf -v AIUR_RESTART_BUILD_CMD 'AIUR_REPO_ROOT=%q %q %q' \
    "$repo_root" "$script_dir/$(basename "$src")" "__ensure-build"
  # Declares that this builder reports a verifiable receipt, so the engine can
  # tell "unverified" apart from "verified and wrong" for a builder it does not
  # own.
  export AIUR_RESTART_BUILD_CMD AIUR_RESTART_BUILD_VERIFIES=1
fi

if requires_pinned_opencode "${passthrough[0]:-}"; then
  ensure_pinned_opencode || exit 64
fi

# ── Processor optimization: cap schedulers on agent-spawned Elixir BEAMs ──
# Every agent pre-PR gate command (`mix compile`, `mix test`, `mix credo`)
# launches its OWN BEAM, and a BEAM defaults to one scheduler thread per
# logical core. Run many agents at once and the scheduler threads multiply
# far past the core count, oversubscribing the CPU (high run-queue, ~0% idle,
# thrash) — the daemon and every agent then fight for the same cores.
#
# ELIXIR_ERL_OPTIONS is read by the `elixir`/`mix`/`iex` launcher (NOT the
# release boot script), and codex runs with shell_environment_policy.inherit=all,
# so this caps ONLY the agents' mix BEAMs — the daemon release keeps its full
# scheduler set and full coordination throughput.
#
# `+S N:N` sets N schedulers (+ N online). Rule of thumb: ~cores / 3.
#   host cores -> cap:    6 -> +S 2:2     12 -> +S 4:4     24 -> +S 8:8
#   Worked example (12-core host, 12 agents):
#     default : 12 agents x 12 schedulers = 144 threads  (~12x oversub;
#               run-queue ~120, idle 0%, 1-min load ~73)
#     +S 4:4  : 12 agents x  4 schedulers =  48 threads  (~4x; load ~7)
# Lower N packs more agents but slows each individual compile; higher N is
# faster per compile but trends back toward saturation.
[ -n "${AIUR_AGENT_MIX_SCHEDULERS:-}" ] && export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +S ${AIUR_AGENT_MIX_SCHEDULERS}:${AIUR_AGENT_MIX_SCHEDULERS}"

apply_agent_ir_xdg_env
if [ "${#passthrough[@]}" -gt 0 ]; then
  if pure_control_command "${passthrough[0]}"; then
    control_retry_signal="$(mktemp "${TMPDIR:-/tmp}/aiurdev-control-retry.XXXXXX")"
    rm -f "$control_retry_signal"
    export AIUR_CONTROL_RELEASE_RETRYABLE=1
    export AIUR_CONTROL_RELEASE_RETRY_SIGNAL="$control_retry_signal"
    set +e
    "$engine" "${passthrough[@]}"
    control_status=$?
    set -e

    if [ "$control_status" -eq 75 ] && [ -f "$control_retry_signal" ]; then
      # The shared engine reserves EX_TEMPFAIL plus this per-invocation signal
      # for a dev release that became incomplete before its RPC launcher exec.
      rm -f "$control_retry_signal"
      echo "⏳ dev release changed during control command; waiting for rebuild and retrying" >&2
      acquire_build_lock
      trap 'release_build_lock' EXIT INT TERM
      if ! release_ready; then
        ensure_built_locked
      fi
      release_build_lock
      trap - EXIT INT TERM
      export AIUR_CONTROL_RELEASE_RETRYABLE=0
      exec "$engine" "${passthrough[@]}"
    fi

    rm -f "$control_retry_signal"
    exit "$control_status"
  fi
  exec "$engine" "${passthrough[@]}"
else
  exec "$engine"
fi
