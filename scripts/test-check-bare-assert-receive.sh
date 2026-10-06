#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/fixtures"

cat > "$tmpdir/fixtures/receive_test.exs" <<'EOF'
defmodule ReceiveTest do
  use ExUnit.Case

  test "bare forms are reported" do
    assert_receive :atom_message
    refute_receive {:tuple, ^pinned}
    assert_receive {:guarded, pid} when is_pid(pid)
    assert_receive(
      {:multiline, %{value: value}}
    )
  end

  test "explicit bounds are accepted" do
    assert_receive :message, 1000
    refute_receive {:message, _}, 0
    refute_receive :message, 100
    assert_received :instant_message
  end
end
EOF

output="$tmpdir/checker.out"
if python3 scripts/check-bare-assert-receive.py "$tmpdir/fixtures" >"$output" 2>&1; then
  echo "checker accepted fixture calls without explicit timeouts" >&2
  exit 1
fi

for expected in ":5" ":6" ":7" ":8"; do
  if ! grep -q "receive_test.exs${expected}" "$output"; then
    cat "$output" >&2
    echo "checker did not report expected fixture line ${expected}" >&2
    exit 1
  fi
done

cat > "$tmpdir/fixtures/receive_test.exs" <<'EOF'
defmodule ReceiveTest do
  use ExUnit.Case

  test "explicit bounds including zero pass" do
    assert_receive :message, 1000
    refute_receive {:message, _}, 0
    refute_receive :message, 100
    assert_received :instant_message
  end
end
EOF

python3 scripts/check-bare-assert-receive.py "$tmpdir/fixtures"
python3 scripts/check-bare-assert-receive.py
