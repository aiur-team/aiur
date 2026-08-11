#!/usr/bin/env bash
# Test harness for scripts/verify-webhook-ingress.
#
# The guard's whole value is that it distinguishes a correctly scoped tunnel
# from one that publishes the daemon's dashboard and Decision API. These cases
# assert it actually makes that distinction, rather than passing on anything
# that answers.

set -euo pipefail

fixture="scripts/test-fixtures/webhook-ingress/fake_ingress.py"

if [[ ! -f "$fixture" ]]; then
  echo "webhook ingress tests: fixture not found: $fixture" >&2
  echo "run from the repository root" >&2
  exit 1
fi

server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

trap cleanup EXIT

fixture_base=""

# Start the fixture in the requested mode and set `fixture_base` to the URL it
# bound. This assigns globals rather than echoing, because a command
# substitution would run it in a subshell where the background PID -- the thing
# `cleanup` needs -- would be discarded.
start_fixture() {
  local mode="$1"
  local port_file attempt port

  port_file="$(mktemp)"

  python3 "$fixture" "$mode" >"$port_file" &
  server_pid=$!

  # The fixture prints its OS-assigned port once the listener is bound, so
  # polling for that line is also the readiness check.
  for attempt in $(seq 1 100); do
    port="$(head -n 1 "$port_file")"
    [[ -n "$port" ]] && break

    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "webhook ingress tests: fixture ($mode) exited before binding" >&2
      cat "$port_file" >&2
      rm -f "$port_file"
      exit 1
    fi

    sleep 0.1
  done

  rm -f "$port_file"

  if [[ -z "$port" ]]; then
    echo "webhook ingress tests: fixture ($mode) did not report a port" >&2
    exit 1
  fi

  fixture_base="http://127.0.0.1:$port"
}

run_guard() {
  AIUR_WEBHOOK_INGRESS_ALLOW_HTTP=1 scripts/verify-webhook-ingress "$@" 2>&1
}

expect_pass() {
  local mode="$1"
  local output

  start_fixture "$mode"

  if ! output="$(run_guard "$fixture_base")"; then
    echo "expected the guard to PASS against a $mode edge, but it failed:" >&2
    echo "$output" >&2
    exit 1
  fi

  cleanup
  echo "ok: guard passes a $mode edge"
}

expect_failure() {
  local mode="$1"
  local expected_reason="$2"
  local output

  start_fixture "$mode"

  if output="$(run_guard "$fixture_base")"; then
    echo "expected the guard to REJECT a $mode edge, but it passed:" >&2
    echo "$output" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_reason" <<<"$output"; then
    echo "guard rejected a $mode edge for the wrong reason:" >&2
    echo "  wanted: $expected_reason" >&2
    echo "$output" >&2
    exit 1
  fi

  cleanup
  echo "ok: guard rejects a $mode edge ($expected_reason)"
}

# The intended posture.
expect_pass "scoped"

# The dashboard and every /api/v1/* route reachable through the tunnel. This is
# the case the ticket's AC 4 is about; a guard that cannot fail here is useless.
expect_failure "wide-open" "PUBLICLY REACHABLE"

# A rule that publishes only one POST-only API route is still too broad. Every
# GET outside the webhook receives the edge 404 in this mode, so only the
# method-correct token probe can distinguish it from the intended posture.
expect_failure "post-leak" "POST /api/v1/streamdeck/token"

# Reachable receiver that accepts a delivery carrying no signature at all.
expect_failure "unsigned" "ACCEPTED an unsigned delivery"

# An ingress rule that never matches the webhook path, so the catch-all answers
# it too. Every "not publicly routable" assertion passes in this posture -- the
# reachability assertion is the only thing standing between a tunnel that
# silently delivers nothing and a green guard.
expect_failure "misrouted" "is the ingress rule matching this exact path?"

# Nothing listening: a dead tunnel must not read as "everything is scoped out".
dead_base="http://127.0.0.1:1"

if output="$(run_guard "$dead_base")"; then
  echo "expected the guard to REJECT an unreachable edge, but it passed:" >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "no response" <<<"$output"; then
  echo "guard rejected an unreachable edge for the wrong reason:" >&2
  echo "$output" >&2
  exit 1
fi

echo "ok: guard rejects an unreachable edge (no response)"

# A plaintext base URL without the test escape must be refused outright, so the
# guard can never certify a posture that carries signed payloads in the clear.
set +e
output="$(scripts/verify-webhook-ingress "http://example.invalid" 2>&1)"
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
  echo "expected exit 2 for a plaintext base URL, got $status:" >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "base URL must be https://" <<<"$output"; then
  echo "plaintext base URL rejected for the wrong reason:" >&2
  echo "$output" >&2
  exit 1
fi

echo "ok: guard refuses a plaintext base URL"

# DENY_STATUS describes a deny response, not an arbitrary expected response.
# Accepting 200 here would let a caller turn a wide-open edge green by declaring
# every successful dashboard response to be the catch-all.
start_fixture "wide-open"
set +e
output="$(
  AIUR_WEBHOOK_INGRESS_ALLOW_HTTP=1 \
    DENY_STATUS=200 \
    scripts/verify-webhook-ingress "$fixture_base" 2>&1
)"
status=$?
set -e
cleanup

if [[ "$status" -ne 2 ]]; then
  echo "expected exit 2 for DENY_STATUS=200, got $status:" >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "DENY_STATUS must be 403 or 404" <<<"$output"; then
  echo "unsafe DENY_STATUS rejected for the wrong reason:" >&2
  echo "$output" >&2
  exit 1
fi

echo "ok: guard refuses an unsafe DENY_STATUS"

# --- AC 5: restarting the daemon does not change the webhook URL -------------
#
# Every case above collapses the edge and the daemon into one process, so none
# of them can say anything about a restart: killing that process takes the
# public URL down with it. The hazard the runbook's port prerequisite exists to
# prevent lives in the seam between the two tiers -- the hostname stays put
# while the origin moves out from under it -- so these cases run them apart.
#
# The edge is started once and never restarted, which is the point: its port
# cannot drift, so whether the guard still passes after an origin restart
# depends only on whether the origin came back where the edge is looking.

edge_pid=""
origin_pid=""
# Declared before the trap that reads them: `set -u` would abort the trap on an
# unset name if a failure fired it before `start_tier` ran.
tier_pid=""
tier_port=""

restart_cleanup() {
  # `tier_pid` is in this list because `start_tier` sets it before the caller
  # copies it into `origin_pid`/`edge_pid`. A failure in between would otherwise
  # leave that process running with the test's stderr still open, which hangs
  # any caller reading this script through a pipe rather than just leaking.
  for pid in "$tier_pid" "$origin_pid" "$edge_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  tier_pid=""
  origin_pid=""
  edge_pid=""
}

trap 'cleanup; restart_cleanup' EXIT

# Starts one tier and sets `tier_pid` / `tier_port`. Same reason as
# `start_fixture` for assigning globals rather than echoing: a command
# substitution would discard the background PID in a subshell.
start_tier() {
  local port_file attempt

  tier_pid=""
  tier_port=""
  port_file="$(mktemp)"

  python3 "$fixture" "$@" >"$port_file" &
  tier_pid=$!

  for attempt in $(seq 1 100); do
    tier_port="$(head -n 1 "$port_file")"
    [[ -n "$tier_port" ]] && break

    if ! kill -0 "$tier_pid" 2>/dev/null; then
      echo "webhook ingress tests: tier ($*) exited before binding" >&2
      cat "$port_file" >&2
      rm -f "$port_file"
      exit 1
    fi

    sleep 0.1
  done

  rm -f "$port_file"

  if [[ -z "$tier_port" ]]; then
    echo "webhook ingress tests: tier ($*) did not report a port" >&2
    exit 1
  fi
}

stop_origin() {
  kill "$origin_pid" 2>/dev/null || true
  wait "$origin_pid" 2>/dev/null || true
  origin_pid=""
}

start_tier origin
origin_pid="$tier_pid"
origin_port="$tier_port"

start_tier edge --origin-port "$origin_port"
edge_pid="$tier_pid"
edge_base="http://127.0.0.1:$tier_port"

if ! output="$(run_guard "$edge_base")"; then
  echo "expected the guard to PASS against a two-tier edge before any restart," >&2
  echo "but it failed -- the restart cases below would be meaningless:" >&2
  echo "$output" >&2
  exit 1
fi

echo "ok: guard passes a two-tier edge (origin up, nothing restarted yet)"

# A pinned restart. The daemon goes away and comes back on the same port, which
# is what `server.port: <n>` in .aiur/config buys. The URL under test is byte
# for byte the one that just passed, and nothing about the edge was touched --
# so this is the ticket's AC 5 claim, checked rather than asserted.
stop_origin
start_tier origin --port "$origin_port"
origin_pid="$tier_pid"

if [[ "$tier_port" != "$origin_port" ]]; then
  echo "fixture did not honour --port: wanted $origin_port, got $tier_port" >&2
  exit 1
fi

if ! output="$(run_guard "$edge_base")"; then
  echo "expected the guard to PASS after a PINNED origin restart, but it failed:" >&2
  echo "$output" >&2
  exit 1
fi

echo "ok: the webhook URL survives a restart when the origin port is pinned"

# The negative control, and the reason the case above is not vacuous: an
# unpinned restart must break the very same URL. Without this, a guard that
# passed unconditionally would look like a clean AC 5 result.
#
# The expected reason is load-bearing too. The edge is up and its ingress rule
# still matches, so the guard has to blame the origin; a guard that reports
# this as a routing problem sends the operator to the one file that is correct.
stop_origin

# An unpinned restart takes a fresh OS-assigned port -- but "fresh" is the
# kernel's choice, and it is allowed to hand back the port just released. That
# happens rarely and would make the URL keep working for a reason that has
# nothing to do with pinning, so retry instead of failing: a security guard that
# goes red for reasons unrelated to the property it checks is a guard people
# learn to ignore, which costs more than the case is worth.
moved=""

for attempt in $(seq 1 10); do
  start_tier origin
  origin_pid="$tier_pid"

  if [[ "$tier_port" != "$origin_port" ]]; then
    moved=1
    break
  fi

  stop_origin
done

if [[ -z "$moved" ]]; then
  echo "ten unpinned restarts all landed back on port $origin_port, so the" >&2
  echo "moved-origin case could not be exercised. That is not a port-pinning" >&2
  echo "failure -- suspect the fixture or the platform's port assignment." >&2
  exit 1
fi

if output="$(run_guard "$edge_base")"; then
  echo "expected the guard to REJECT the same URL after an UNPINNED origin" >&2
  echo "restart, but it passed -- a moved origin would go unnoticed:" >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "pin server.port in .aiur/config" <<<"$output"; then
  echo "guard rejected a moved origin without pointing at the port pin:" >&2
  echo "$output" >&2
  exit 1
fi

if grep -Fq "is the ingress rule matching this exact path?" <<<"$output"; then
  echo "guard blamed the ingress rule for a moved origin; the rule is correct" >&2
  echo "and the operator would be sent to the wrong file:" >&2
  echo "$output" >&2
  exit 1
fi

restart_cleanup
echo "ok: guard rejects the same URL after an unpinned restart, naming the port pin"

echo "webhook ingress tests passed"
