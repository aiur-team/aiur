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
#   AIUR_BIN                    aiur CLI to use for every probe (status,
#                               __identity, epmd classification). One value
#                               drives all of them — do NOT point this at the
#                               raw release bin, which has no `status`.
#   AIUR_REPRO_STATUS_TIMEOUT   seconds to allow `aiur status` (default 20); a
#                               timeout means saturated, not dead
#
# Exit codes: 0 = window elapsed without a daemon crash; 1 = REPRODUCED (crash
# dump appeared during the window, details printed); 2 = usage/preflight error;
# 3 = fleet target not reached within the fleet-wait window; 4 = the daemon BEAM
# disappeared but wrote no crash dump (real death, unconfirmed signature).
#
# A daemon that is merely scheduler-saturated — alive per epmd but timing out
# control RPC — is expected under these conditions and is NOT counted as a
# crash.

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
status_timeout="${AIUR_REPRO_STATUS_TIMEOUT:-20}"
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

# Resolve the daemon's distribution node short name and release dir from the
# CLI's own identity report (`aiur __identity`), so we never guess either. Sets
# the globals once and reuses them; missing values stay empty and downstream
# epmd classification degrades to `unknown` rather than lying.
identity_release_dir=""
identity_node_short=""
identity_loaded=0
load_identity() {
  [ "$identity_loaded" -eq 1 ] && return 0
  identity_loaded=1
  local out line node
  set +e
  out="$("$aiur_bin" __identity 2>/dev/null)"
  set -e
  while IFS= read -r line; do
    case "$line" in
      AIUR_RELEASE_DIR=*) identity_release_dir="${line#AIUR_RELEASE_DIR=}" ;;
      AIUR_RELEASE_NODE=*) node="${line#AIUR_RELEASE_NODE=}" ;;
    esac
  done <<<"$out"
  node="${node:-${AIUR_RELEASE_NODE:-}}"
  identity_node_short="${node%@*}"
}

# Classify the daemon's BEAM via epmd, which advertises a node only while its
# BEAM holds the registration (mirrors the engine's probe_node_liveness). Echoes
# exactly one word: `up` (node registered — alive), `down` (epmd answered and
# the node is absent — the BEAM is gone), or `unknown` (epmd unqueryable, so
# state is indeterminate and callers must NOT assume the daemon died).
epmd_node_state() {
  load_identity
  [ -n "$identity_node_short" ] || { printf 'unknown'; return; }
  local epmd names
  for epmd in "$identity_release_dir"/erts-*/bin/epmd $(command -v epmd 2>/dev/null); do
    [ -x "$epmd" ] || continue
    names="$(ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" "$epmd" -names 2>/dev/null)" \
      || { printf 'unknown'; return; }
    case "$names" in
      *"name ${identity_node_short} at port "*) printf 'up' ;;
      *) printf 'down' ;;
    esac
    return
  done
  printf 'unknown'
}

# Classify the daemon into one of four states. This is the crash-detection
# primitive, and the distinction matters: the engine documents that a
# scheduler-saturated-but-ALIVE daemon times out control RPC, which is exactly
# what the target conditions of this repro provoke. Treating that as a death
# would false-positive "REPRODUCED" on every run.
#
#   up        — `aiur status` answered cleanly; control plane is healthy.
#   saturated — control probe failed/timed out but epmd still advertises the
#               node: the BEAM is alive, just not answering. NOT a crash.
#   down      — control probe failed AND epmd says the node is gone: the BEAM
#               died. This is the signal we are hunting.
#   unknown   — control probe failed and epmd could not be queried. Never
#               treated as a crash.
daemon_state() {
  local rc
  set +e
  timeout -k 5 "$status_timeout" "$aiur_bin" status >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'up'
    return
  fi
  case "$(epmd_node_state)" in
    up) printf 'saturated' ;;
    down) printf 'down' ;;
    *) printf 'unknown' ;;
  esac
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

# Watch the daemon + crash-dump path from $1 (epoch) until $2 (epoch), or until
# a terminal condition trips. Sourced-and-callable so tests can drive it with
# stubbed probes. Sets three globals the reporter reads:
#   peak_load  — highest 1-min load seen
#   dump_seen  — 1 when a dump appeared/was rewritten at or after the start
#   crashed    — 1 when the BEAM is gone (dump seen, or epmd says `down`)
# `saturated` and `unknown` states are logged and tolerated: under the target
# conditions a live daemon routinely stops answering control RPC, and calling
# that a crash would false-positive every run.
watch_window() {
  local watch_start="$1" watch_end="$2" load state dump_mtime
  peak_load=0
  crashed=0
  dump_seen=0
  unknown_samples=0
  saturated_samples=0

  while [ "$(date +%s)" -lt "$watch_end" ]; do
    load="$(read_load1)"
    if float_gt "$load" "$peak_load"; then peak_load="$load"; fi

    dump_mtime=0
    if [ -f "$resolved_dump" ]; then
      dump_mtime="$(stat -c %Y "$resolved_dump" 2>/dev/null || echo 0)"
    fi
    if [ "$dump_mtime" -ge "$watch_start" ] && [ "$dump_mtime" -gt 0 ]; then
      dump_seen=1
      crashed=1
      return 0
    fi

    state="$(daemon_state)"
    case "$state" in
      down)
        # Give a dump one grace beat to finish being written before reporting.
        sleep 5
        if [ -f "$resolved_dump" ] &&
          [ "$(stat -c %Y "$resolved_dump" 2>/dev/null || echo 0)" -ge "$watch_start" ]; then
          dump_seen=1
        fi
        crashed=1
        return 0
        ;;
      saturated)
        saturated_samples=$((saturated_samples + 1))
        info "t+$(( $(date +%s) - watch_start ))s load=$load peak=$peak_load daemon=saturated (alive, control rpc not answering)"
        ;;
      unknown)
        unknown_samples=$((unknown_samples + 1))
        info "t+$(( $(date +%s) - watch_start ))s load=$load peak=$peak_load daemon=unknown (epmd unqueryable; not treated as a crash)"
        ;;
      *)
        info "t+$(( $(date +%s) - watch_start ))s load=$load peak=$peak_load daemon=up"
        ;;
    esac
    sleep 5
  done
  return 0
}

# Tail the saturation sentinel (added alongside this ticket) for VM-internal
# context. Written beside the daemon log (<logs-root>/log/saturation.log); also
# check the logs root directly for older layouts.
print_sentinel_tail() {
  local dump_dir sentinel="" candidate
  dump_dir="$(dirname "$resolved_dump")"
  for candidate in "$dump_dir/log/saturation.log" "$dump_dir/saturation.log"; do
    if [ -f "$candidate" ]; then sentinel="$candidate"; break; fi
  done
  if [ -n "$sentinel" ]; then
    echo "$log_prefix saturation sentinel tail ($sentinel):"
    tail -n 5 "$sentinel" 2>/dev/null | sed 's/^/    /' || true
  fi
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
  sed -n '2,64p' "$0" | sed -n 's/^# \{0,1\}//p' >&2
}

# ---- main ------------------------------------------------------------------

main() {
  local waited reached current i load peak_load crashed end_ts start_ts \
    burn_script sentinel dump_dir preflight_state state dump_seen
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
  preflight_state="$(daemon_state)"
  if [ "$preflight_state" != "up" ]; then
    err "daemon control plane is '$preflight_state', not 'up' — start a healthy daemon first"
    err "(this repro stacks load on a RUNNING fleet; baseline must be a clean 'aiur status')"
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
  watch_window "$start_ts" $((start_ts + window_seconds))

  # Phase 4: report. A crash dump is the only thing that earns "REPRODUCED" —
  # a BEAM death with no dump is a real but weaker signal, and a saturated or
  # unclassifiable control plane is not a death at all.
  if [ "$dump_seen" -eq 1 ]; then
    echo
    echo "$log_prefix REPRODUCED: a crash dump appeared during the window."
    echo "$log_prefix peak load reached: $peak_load"
    echo "$log_prefix crash dump: $resolved_dump"
    echo "$log_prefix slogan:"
    dump_slogan "$resolved_dump" | sed 's/^/    /'
    print_sentinel_tail
    exit 1
  fi

  if [ "$crashed" -eq 1 ]; then
    echo
    echo "$log_prefix DAEMON DOWN, NO DUMP: epmd stopped advertising the node during"
    echo "$log_prefix the window, but no crash dump was written. The BEAM died without"
    echo "$log_prefix dumping (SIGKILL/OOM-killer class), or the #856 dump path is"
    echo "$log_prefix misconfigured. This is NOT a confirmed reproduction of the #852"
    echo "$log_prefix crash signature — check dmesg for an OOM kill before concluding."
    echo "$log_prefix peak load reached: $peak_load"
    echo "$log_prefix watched dump path: $resolved_dump"
    print_sentinel_tail
    exit 4
  fi

  info "window elapsed without a daemon crash. peak load=$peak_load"
  if [ "$saturated_samples" -gt 0 ]; then
    info "daemon was saturated (alive, control rpc timing out) for $saturated_samples sample(s)"
    info "— the load profile bit, but the BEAM survived it."
  fi
  if [ "$unknown_samples" -gt 0 ]; then
    # Preflight proved epmd was queryable and the node registered, so losing
    # that mid-window is a real blind spot: a BEAM death during those samples
    # would have been misread as "no crash". Say so instead of implying a clean
    # run, and point the operator at the independent evidence.
    info "WARNING: daemon state was UNCLASSIFIABLE for $unknown_samples sample(s) — epmd"
    info "became unqueryable after a clean preflight, so a death during that span"
    info "could have been missed. Treat this run as INCONCLUSIVE, not negative:"
    info "check '$aiur_bin status', the daemon log, and $resolved_dump before rerunning."
  fi
  info "not reproduced in this window — to push further raise --external / --duration,"
  info "add --fleet-target, or raise the internal load_cap_beams in this script."
  exit 0
}

# Run the repro only when executed, not when sourced (tests source the
# script to exercise the pure helpers without touching a live daemon).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
