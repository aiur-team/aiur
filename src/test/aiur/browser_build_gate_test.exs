defmodule Aiur.BrowserBuildGateTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentBuildGuard

  test "installed browser guard serializes workspace runs and shares host admission" do
    root = Path.join(System.tmp_dir!(), "browser-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert :ok = AgentBuildGuard.install(root)

    script = Path.expand("../support/browser_build_gate_check.py", __DIR__)
    hook = Path.expand("../../priv/build_gate.bash", __DIR__)
    assert {output, 0} = System.cmd("python3", [script, root, hook], stderr_to_stdout: true)
    assert output =~ "workspace serialization, host cap, nested lease, passthrough: passed"
  end
end
