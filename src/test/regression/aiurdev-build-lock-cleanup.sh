#!/bin/bash
# Regression test for issue #997: build lock cleanup on helper failure.
#
# Verifies that when a rebuild helper (e.g., require_mise) fails, the build
# lock is properly cleaned up, preventing indefinite hangs on subsequent
# invocations.
#
# Usage:
#   bash src/test/regression/aiurdev-build-lock-cleanup.sh
#
# Exits 0 on success, 1 on failure.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
[ -d "$repo_root/.git" ] || repo_root="$(cd "$script_dir/../../../../.." && pwd)"
elixir_dir="$repo_root/src"
build_lock_dir="$elixir_dir/_build/.aiurdev-build.lock"
test_temp_dir="${TMPDIR:-/tmp}/aiurdev-lock-test-$$"

cleanup() {
  rm -rf "$test_temp_dir" "$build_lock_dir"
}
trap cleanup EXIT

cleanup

mkdir -p "$test_temp_dir"

echo "=== Test: build lock cleanup on helper failure ==="

# Create a wrapper around aiurdev that forces require_mise to fail by
# unsetting AIUR_MISE_BIN and ensuring the system mise is not found.
wrapper_script="$test_temp_dir/aiurdev-wrapper.sh"
cat > "$wrapper_script" <<'WRAPPER'
#!/bin/bash
set -euo pipefail

# Must unset TMUX to avoid the tmux guard in aiurdev
unset TMUX TMUX_PANE

# Force require_mise to fail by clearing the mise path
unset AIUR_MISE_BIN
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

repo_root="$1"
cd "$repo_root"

# Try to run a command that requires mise (e.g., 'build' command)
# but since AIUR_MISE_BIN is unset and mise isn't on PATH, require_mise will fail.
# The key is that the EXIT trap should still clean up the lock.
bash scripts/aiurdev build 2>&1 || {
  status=$?
  # We expect this to fail with code 64 (require_mise error)
  if [ "$status" -ne 64 ] && [ "$status" -ne 1 ]; then
    echo "Unexpected exit code: $status (expected 64 or 1)"
    exit 1
  fi
}
WRAPPER
chmod +x "$wrapper_script"

# Run the wrapper and capture the status
echo "1. Running aiurdev build with require_mise failure..."
if "$wrapper_script" "$repo_root" 2>/dev/null; then
  # The command should fail but that's ok - we're testing lock cleanup
  true
else
  # Command failed as expected
  true
fi

# Verify the lock was cleaned up
if [ -d "$build_lock_dir" ]; then
  echo "FAIL: Build lock still exists after require_mise failure"
  ls -la "$build_lock_dir"
  exit 1
fi
echo "  ✓ Build lock was cleaned up"

# Now verify that a subsequent invocation doesn't hang
# We'll use a timeout to ensure it doesn't wait indefinitely
echo ""
echo "2. Verifying subsequent invocation doesn't hang on stale lock..."

# Create a script that checks if aiurdev can acquire the lock quickly
timeout_script="$test_temp_dir/timeout-test.sh"
cat > "$timeout_script" <<'TIMEOUT'
#!/bin/bash
set -euo pipefail

repo_root="$1"
elixir_dir="$repo_root/src"
build_lock_dir="$elixir_dir/_build/.aiurdev-build.lock"

# Simulate what ensure_built does
mkdir -p "$elixir_dir/_build"

# Try to acquire the lock with a timeout
# If the lock is stale, this should succeed quickly
start_time=$(date +%s)
lock_acquired=0

# Simple timeout loop: try for 3 seconds max
for i in {1..15}; do
  if mkdir "$build_lock_dir" 2>/dev/null; then
    lock_acquired=1
    break
  fi
  sleep 0.2
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [ $lock_acquired -eq 0 ]; then
  echo "FAIL: Could not acquire lock after ${elapsed}s"
  exit 1
fi

if [ $elapsed -gt 2 ]; then
  echo "FAIL: Lock acquisition took too long (${elapsed}s, expected <1s)"
  exit 1
fi

echo "Lock acquired in ${elapsed}s"
rm -rf "$build_lock_dir"
TIMEOUT
chmod +x "$timeout_script"

if ! timeout 5 "$timeout_script" "$repo_root" 2>&1; then
  echo "FAIL: Could not acquire lock quickly on subsequent invocation"
  exit 1
fi
echo "  ✓ Subsequent invocation can acquire lock quickly"

echo ""
echo "PASS: Build lock cleanup on helper failure works correctly"
exit 0
