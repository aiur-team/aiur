defmodule Aiur.TestLogTmpTest do
  use ExUnit.Case, async: true

  setup do
    base = Aiur.TestSupport.tmp_root!("test-log-sweep")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, owner: File.stat!(base).uid}
  end

  test "sweeps dead log roots while preserving live roots, symlinks and unrelated files", %{base: base} do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    pid = String.trim(output)
    dead = Path.join(base, "aiur-test-logs-1-#{pid}")
    live = Path.join(base, "aiur-test-logs-1-#{System.pid()}")
    other = Path.join(base, "other")
    link = Path.join(base, "aiur-test-logs-2-#{pid}")
    file = Path.join(base, "aiur-test-logs-3-#{pid}")
    for path <- [dead, live, other], do: File.mkdir!(path)
    File.write!(Path.join(dead, "fixture"), "remove")
    File.write!(Path.join(live, "fixture"), "keep")
    File.ln_s!(other, link)
    File.write!(file, "keep")
    config = Path.expand("../../config/config.exs", __DIR__)
    {output, status} = System.cmd("elixir", ["--erl", "+S 2:2", "-e", "Config.Reader.read!(#{inspect(config)}, env: :test, target: :host)"], stderr_to_stdout: true, env: [{"TMPDIR", base}])
    assert status == 0, output
    refute File.exists?(dead)
    assert File.read!(Path.join(live, "fixture")) == "keep"
    assert File.dir?(other)
    assert File.read_link!(link) == other
    assert File.read!(file) == "keep"
  end

  # Future safety guard: this also passes with cleanup entirely disabled.
  test "keeps foreign owners and inconclusive process checks", %{base: base, owner: owner} do
    root = Path.join(base, "aiur-test-logs-1-99999999")
    File.mkdir!(root)
    Aiur.TestLogTmp.sweep!(base, owner + 1, fn _ -> false end)
    assert File.dir?(root)
    Aiur.TestLogTmp.sweep!(base, owner, fn _ -> true end)
    assert File.dir?(root)
  end
end
