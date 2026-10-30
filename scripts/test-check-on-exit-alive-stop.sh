#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/fixtures"

cat > "$tmpdir/fixtures/cleanup_test.exs" <<'EOF'
defmodule CleanupTest do
  use ExUnit.Case

  setup do
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    on_exit(fn -> GenServer.stop(pid) end)
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
  end
end
EOF

if python3 "$repo_root/scripts/check-on-exit-alive-stop.py" "$tmpdir/fixtures" >"$tmpdir/checker.out" 2>&1; then
  echo "checker accepted alive?-then-stop cleanup" >&2
  exit 1
fi
grep -q 'cleanup_test.exs:5' "$tmpdir/checker.out"
grep -q 'cleanup_test.exs:6' "$tmpdir/checker.out"
grep -q 'cleanup_test.exs:7' "$tmpdir/checker.out"
if [ "$(grep -c 'cleanup_test.exs:' "$tmpdir/checker.out")" != 3 ]; then
  cat "$tmpdir/checker.out" >&2
  echo "checker reported a non-stop teardown" >&2
  exit 1
fi

python3 "$repo_root/scripts/check-on-exit-alive-stop.py"
