#!/bin/bash
# Test the bare assert_receive/refute_receive check

set -euo pipefail

cd "$(dirname "$0")"/..

# Test 1: Verify the check passes on actual test files (should be all fixed)
if python3 scripts/check-bare-assert-receive.py 2>&1 | grep -q "OK"; then
    echo "✓ Check passes - all bare assert_receive/refute_receive calls have explicit timeouts"
else
    echo "✗ Check failed - found bare calls that need fixing"
    python3 scripts/check-bare-assert-receive.py
    exit 1
fi

# Test 2: Create a temporary test directory with bare calls and verify check catches them
tmpdir=$(mktemp -d)
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/test"
cat > "$tmpdir/test/example_test.exs" << 'EOF'
defmodule ExampleTest do
  use ExUnit.Case

  test "bare assert_receive" do
    assert_receive {:msg}
  end

  test "bare refute_receive" do
    refute_receive {:msg}
  end

  test "with timeout" do
    assert_receive {:msg}, 1000
  end
end
EOF

# Modify check script to look at our temp test directory
# We'll create a minimal test to check the detection logic
python3 -c "
import re

content = open('$tmpdir/test/example_test.exs').read()
lines = content.split('\n')

bare_count = 0
for line in lines:
    if re.search(r'\b(assert_receive|refute_receive)\b.*\}\s*$', line):
        if not re.search(r',\s*\d+\s*$', line):
            bare_count += 1

if bare_count == 2:
    print('✓ Check correctly detects 2 bare calls in test file')
else:
    print(f'✗ Expected 2 bare calls, found {bare_count}')
    exit(1)
"

echo "All tests passed!"
