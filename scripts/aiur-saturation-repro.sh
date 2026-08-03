#!/usr/bin/env bash
# Bounded, operator-run reproduction of the #852 daemon crash trigger.
#
# The daemon BEAM crashed under sustained CPU saturation when external,
# UNMANAGED, UNcapped BEAMs (background PR-processors running `mix dialyzer`)
# stacked load on top of an already-loaded fleet. The #465 dispatch gate does
# not count external processor load, so nothing held new work and the box
# oversubscribed until the ERTS native port-spawn helper died
# (`erl_child_setup: 104` = ECONNRESET; see
# docs/measurements/2026-08-03-daemon-saturation-root-cause.md).
#
# This script reproduces that profile against a RUNNING daemon: it
#   (1) optionally waits for the fleet to reach a target agent count,
#   (2) spawns N external uncapped BEAMs (full scheduler set, daemon env
#       scrubbed) that burn CPU for a bounded duration — the exact class of
#       load the #852 trigger came from, and
#   (3) watches the daemon BEAM and the #856 crash-dump path for the window.
# On a daemon death it captures the crash-dump slogan + host load and exits
# non-zero (reproduced); on a clean window it reports the peak load reached.
#
# SAFETY — read before running:
#   * OPERATOR ONLY. This must NOT be run from inside an agent workspace and
#     must NOT be run on the shared host by an agent. It intentionally pushes
#     a host toward saturation.
#   * Bounded by default: 4 external beams, 300 s of external load, 600 s
#     watch window, cleaned up on EXIT regardless of outcome.
#   * External beams are uncapped ON PURPOSE (that is the trigger). The script
#     unsets ELIXIR_ERL_OPTIONS / ERL_AFLAGS / AIUR_AGENT_MIX_SCHEDULERS for
#     them so they reproduce the unmanaged external processor profile rather
#     than inheriting Aiur's agent cap.
#   * The external-beam count is capped at 4 (cores-scaled) to avoid an
#     accidental runaway; raise AIUR_REPRO_EXTERNAL_BEAMS only to deliberately
#     probe the crash threshold.
#
# Usage:
#   scripts/aiur-saturation-repro.sh [--window SECONDS] [--external N]
#     [--duration SECONDS] [--fleet-target N] [--fleet-wait SECONDS] [--cores N]
#
# Environment overrides:
#   AIUR_REPRO_WINDOW_SECONDS   watch window after load starts (default 600)
#   AIUR_REPRO_EXTERNAL_BEAMS   external uncapped BEAM count   (default 4)
#   AIUR_REPRO_EXTERNAL_SECONDS per-beam CPU-burn duration     (default 300)
#   AIUR_REPRO_FLEET_TARGET     optional fleet agent-count target to wait for
#   AIUR_REPRO_FLEET_WAIT       max seconds to wait for the fleet (default 900)
#   AIUR_REPRO_CORES            override host core count for the load cap
#   AIUR_REPRO_EXTERNAL_CMD     workload command for each external beam
#                               (default: uncapped Elixir CPU burn, see below)
#   AIUR_REPRO_DUMP             explicit erl_crash.dump path (default: newest
#                               under $HOME/.aiur/logs or $AIUR_LOGS_ROOT)
#   AIUR_BIN                    aiur CLI to use for fleet/status probes
#
# Exit codes: 0 = window elapsed without a daemon crash; 1 = daemon crashed
# during the window (reproduced, dump details printed); 2 = usage/preflight
# error; 3 = fleet target not reached within the fleet-wait window.

set -euo pipefail

repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ---- config ----------------------------------------------------------------

window_seconds="${AIUR_REPRO_WINDOW_SECONDS:-600}"
external_beams="${AIUR_REPRO_EXTERNAL_BEAMS:-4}"
external_seconds="${AIUR_REPRO_EXTERNAL_SECONDS:-300}"
fleet_target="${AIUR_REPRO_FLEET_TARGET:-}"
fleet_wait="${AIUR_REPRO_FLEET_WAIT:-900}"
cores="${AIUR_REPRO_CORES:-$(nproc 2>/dev/null || echo 1)}"
aiur_bin="${AIUR_BIN:-aiur}"
dump_path="${AIUR_REPRO_DUMP:-}"
external_cmd="${AIUR_REPRO_EXTERNAL_CMD:-}"

# Safety cap: external-beam count must stay small. Each uncapped beam defaults
# to `cores` schedulers, so the count is already the load multiplier; this cap
# only refuses a blatant misconfiguration.
load_cap_beams=4

log_prefix="[aiur-saturation-repro]"
external_pids=()

# ---- helpers ---------------------------------------------------------------

err() { echo "$log_prefix error: $*" >&2; }
info() { echo "$log_prefix $*"; }

# Resolve the crash-dump path: explicit override, else $AIUR_LOGS_ROOT, else
# the newest erl_crash.dump under the durable per-run logs root (~/.aiur/logs).
resolve_dump_path() {
  if [ -n "$dump_path" ]; then printf '%s\n' "$dump_path"; return; fi
  if [ -n "${AIUR_LOGS_ROOT:-}" ]; then printf '%s\n' "$AIUR_LOGS_ROOT/erl_crash.dump"; return; fi
  local logs_root="${HOME}/.aiur/logs"
  if [ -d "$logs_root" ]; then
    local newest
    newest="$(find "$logs_root" -maxdepth 2 -name erl_crash.dump -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -1 | cut -d' ' -f2- || true)"
    if [ -n "$newest" ]; then printf '%s\n' "$newest"; return; fi
  fi
  printf '%s\n' "$HOME/.aiur/logs/erl_crash.dump"
}

# Snapshot the current 1-min load average (matches Aiur.SystemLoad).
read_load1() {
  awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
}

# Float comparison: true when $1 > $2 (handles non-integer load values).
float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a > b)}'
}

# Probe daemon control-plane liveness via the release `rpc` (mirrors the
# engine's probe_control_liveness). Falls back to `aiur status`' exit marker.
daemon_up() {
  local expr output rc
  expr='case Process.whereis(Aiur.Orchestrator) do pid when is_pid(pid) -> case Aiur.Orchestrator.status(Aiur.Orchestrator, 100) do statuses when is_list(statuses) -> IO.puts("__AIUR_CONTROL_READY__"); _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end; _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end'
  set +e
  output="$("$aiur_bin" rpc "$expr" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [[ "$output" == *"__AIUR_CONTROL_READY__"* ]]; then
    printf 'up'
    return 0
  fi
  set +e
  output="$("$aiur_bin" status 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [[ "$output" == *"__AIUR_CONTROL_EXIT__:0"* ]]; then
    printf 'up'
    return 0
  fi
  printf 'down'
}

# Best-effort count of running agents from `aiur status` output. Prefers the
# authoritative `AGENTS occupied/max` capacity line; falls back to counting
# status-table rows. Lenient: on any parsing failure prints 0 (callers proceed
# without hard-failing).
running_agent_count() {
  set +e
  local out count
  out="$("$aiur_bin" status 2>/dev/null)"
  set -e
  count="$(printf '%s\n' "$out" | sed -n 's/^AGENTS \([0-9][0-9]*\)\/.*/\1/p' | head -1)"
  if [ -n "$count" ]; then
    printf '%s\n' "$count"
    return
  fi
  printf '%s\n' "$out" | awk '/^#|^[0-9]+[[:space:]]/ {c++} END {print c+0}'
}

# Print the crash slogan (first meaningful lines) of a dump.
dump_slogan() {
  local path="$1"
  if [ ! -f "$path" ]; then echo "no dump at $path"; return; fi
  head -n 20 "$path" 2>/dev/null | grep -v '^$' | head -n 8 || true
}

# Default external workload: an UNcapped Elixir BEAM (full scheduler set) that
# burns CPU until killed. Spawns one busy process per online scheduler, so it
# reproduces an unmanaged `mix dialyzer`-class BEAM without needing a project.
# Overridable via AIUR_REPRO_EXTERNAL_CMD.
default_external_burn() {
  cat <<'ELIXIR'
spin = fn spin, n -> spin.(spin, n + 1) end
for _ <- 1..System.schedulers_online() do
  spawn(fn -> spin.(spin, 0) end)
end
Process.sleep(:infinity)
ELIXIR
}

# ---- cleanup ---------------------------------------------------------------

repro_cleanup() {
  local pid
  for pid in "${external_pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
  # Defense in depth: kill any leftover external-beam children that escaped.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "aiur-repro-external-beam" 2>/dev/null || true
  fi
}

# ---- usage -----------------------------------------------------------------

usage() {
  sed -n '2,52p' "$0" | sed -n 's/^# \{0,1\}//p' >&2
}

# ---- main ------------------------------------------------------------------

main() {
  local waited reached current i load peak_load crashed end_ts start_ts \
    burn_script sentinel dump_dir
  trap 'repro_cleanup' EXIT

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --window) window_seconds="${2:?--window needs a value}"; shift 2 ;;
      --external) external_beams="${2:?--external needs a value}"; shift 2 ;;
      --duration) external_seconds="${2:?--duration needs a value}"; shift 2 ;;
      --fleet-target) fleet_target="${2:?--fleet-target needs a value}"; shift 2 ;;
      --fleet-wait) fleet_wait="${2:?--fleet-wait needs a value}"; shift 2 ;;
      --cores) cores="${2:?--cores needs a value}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "$log_prefix unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if ! [[ "$external_beams" =~ ^[0-9]+$ ]] || [ "$external_beams" -lt 1 ]; then
    err "external_beams must be a positive integer (got '$external_beams')"
    exit 2
  fi
  if [ "$external_beams" -gt "$load_cap_beams" ]; then
    err "external_beams=$external_beams exceeds the internal cap $load_cap_beams"
    exit 2
  fi

  info "host cores=$cores 1-min-load=$(read_load1)"
  info "probing daemon liveness at '$aiur_bin'..."
  if [ "$(daemon_up)" != "up" ]; then
    err "no responding daemon — start one first (this repro stacks load on a RUNNING fleet)"
    exit 2
  fi
  info "daemon is up"

  resolved_dump="$(resolve_dump_path)"
  info "crash-dump watch path: $resolved_dump"

  # Optional phase 1: wait for the fleet to reach a target agent count.
  if [ -n "$fleet_target" ]; then
    info "waiting up to ${fleet_wait}s for fleet >= $fleet_target agents..."
    waited=0
    reached=0
    current=""
    while [ "$waited" -lt "$fleet_wait" ]; do
      current="$(running_agent_count)"
      if [ -n "$current" ] && [ "$current" -ge "$fleet_target" ]; then
        reached=1
        info "fleet reached $current agents after ${waited}s"
        break
      fi
      sleep 10
      waited=$((waited + 10))
    done
    if [ "$reached" -ne 1 ]; then
      err "fleet did not reach $fleet_target agents within ${fleet_wait}s (last count: ${current:-unknown})"
      exit 3
    fi
  else
    info "using current fleet (no --fleet-target); current agent count: $(running_agent_count)"
  fi

  # Spawn one external uncapped beam. Runs in its own subshell with the Aiur
  # scheduler cap scrubbed, under `timeout` so it self-terminates after
  # $external_seconds and cleanup can kill it by pid (the subshell execs into
  # timeout, so the tracked pid IS the timeout process group leader).
  burn_script="$(default_external_burn)"
  spawn_external_beam() {
    (
      unset ELIXIR_ERL_OPTIONS ERL_AFLAGS AIUR_AGENT_MIX_SCHEDULERS
      if [ -n "$external_cmd" ]; then
        exec timeout -k 5 "$external_seconds" bash -c "$external_cmd"
      else
        exec timeout -k 5 "$external_seconds" bash -c \
          'exec -a aiur-repro-external-beam elixir -e "$1"' _ "$burn_script"
      fi
    ) &
    printf '%s\n' "$!"
  }

  # Phase 2: stack external uncapped BEAM load (the #852 trigger).
  info "spawning $external_beams external UNcapped BEAM(s) for ${external_seconds}s of CPU load..."
  start_ts="$(date +%s)"
  i=0
  while [ "$i" -lt "$external_beams" ]; do
    external_pids+=("$(spawn_external_beam)")
    i=$((i + 1))
  done
  info "external beams running: ${external_pids[*]}"

  # Phase 3: watch the daemon and the crash dump for the window.
  peak_load=0
  crashed=0
  end_ts=$((start_ts + window_seconds))
  while [ "$(date +%s)" -lt "$end_ts" ]; do
    load="$(read_load1)"
    if float_gt "$load" "$peak_load"; then peak_load="$load"; fi

    # Crash detection: a NEW/updated dump, or the daemon control plane dropping.
    if [ -f "$resolved_dump" ] && [ "$(stat -c %Y "$resolved_dump" 2>/dev/null || echo 0)" -ge "$start_ts" ]; then
      crashed=1
      break
    fi
    if [ "$(daemon_up)" != "up" ]; then
      crashed=1
      break
    fi

    info "t+$(( $(date +%s) - start_ts ))s load=$load peak=$peak_load"
    sleep 5
  done

  # Phase 4: report.
  if [ "$crashed" -eq 1 ]; then
    echo
    echo "$log_prefix REPRODUCED: daemon control plane died or a crash dump appeared during the window."
    echo "$log_prefix peak load reached: $peak_load"
    if [ -f "$resolved_dump" ]; then
      echo "$log_prefix crash dump: $resolved_dump"
      echo "$log_prefix slogan:"
      dump_slogan "$resolved_dump" | sed 's/^/    /'
    fi
    # Sentinel tail (added alongside this ticket) gives VM-internal context.
    # Written beside the daemon log (<logs-root>/log/saturation.log); also
    # check the logs root directly for older layouts.
    dump_dir="$(dirname "$resolved_dump")"
    sentinel=""
    for candidate in "$dump_dir/log/saturation.log" "$dump_dir/saturation.log"; do
      if [ -f "$candidate" ]; then sentinel="$candidate"; break; fi
    done
    if [ -n "$sentinel" ]; then
      echo "$log_prefix saturation sentinel tail ($sentinel):"
      tail -n 5 "$sentinel" 2>/dev/null | sed 's/^/    /' || true
    fi
    exit 1
  fi

  info "window elapsed without a daemon crash. peak load=$peak_load"
  info "not reproduced in this window — to push further raise --external / --duration,"
  info "add --fleet-target, or raise the internal load_cap_beams in this script."
  exit 0
}

# Run the repro only when executed, not when sourced (tests source the
# script to exercise the pure helpers without touching a live daemon).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
