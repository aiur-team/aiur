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
echo "webhook ingress tests passed"
