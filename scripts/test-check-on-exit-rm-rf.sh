#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/fixtures"

cat > "$tmpdir/fixtures/cleanup_test.exs" <<'EOF'
defmodule CleanupTest do
  use ExUnit.Case

  setup do
    on_exit(fn -> File.rm_rf!(dir) end)

    on_exit(fn ->
      restore(env)
      Enum.each(dirs, &File.rm_rf!/1)
    end)

    File.rm_rf!(outside_on_exit)
    on_exit(fn -> File.rm_rf(not_bang) end)
    # on-exit-rm-rf: allow fixture
    on_exit(fn -> File.rm_rf(raw) end)
    on_exit(fn -> File.rm_rf_other(x) end)
    on_exit(fn -> File.rm_rf(line_after_allowed) end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
  end
end
EOF

output="$tmpdir/checker.out"
if python3 scripts/check-on-exit-rm-rf.py "$tmpdir/fixtures" >"$output" 2>&1; then
  echo "checker accepted a bare File.rm_rf inside on_exit" >&2
  exit 1
fi

for expected in ":5" ":9" ":13" ":17"; do
  if ! grep -q "cleanup_test.exs${expected}" "$output"; then
    cat "$output" >&2
    echo "checker did not report expected fixture line ${expected}" >&2
    exit 1
  fi
done

if [ "$(grep -c "cleanup_test.exs:" "$output")" != 4 ]; then
  cat "$output" >&2
  echo "checker reported a line that is not a bare File.rm_rf in on_exit" >&2
  exit 1
fi

python3 scripts/check-on-exit-rm-rf.py --fix "$tmpdir/fixtures"
python3 scripts/check-on-exit-rm-rf.py "$tmpdir/fixtures"
grep -q "File.rm_rf!(outside_on_exit)" "$tmpdir/fixtures/cleanup_test.exs"
grep -q "File.rm_rf(raw)" "$tmpdir/fixtures/cleanup_test.exs"
python3 scripts/check-on-exit-rm-rf.py
