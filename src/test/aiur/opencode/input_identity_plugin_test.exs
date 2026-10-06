defmodule Aiur.Opencode.InputIdentityPluginTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.WorkspaceSetup

  test "slot installs the executable transport plugin that preserves original action identity" do
    workspace = Aiur.TestSupport.tmp_root!("identity-plugin")
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, _token} = WorkspaceSetup.materialize_slot(workspace, "http://127.0.0.1:4097", ["identity"], 92, 1)
    config = workspace |> Path.join("opencode.json") |> File.read!() |> Jason.decode!()
    plugin = Path.join(workspace, "input-identity.mjs")
    assert config["plugin"] == ["file://" <> plugin]

    fixture = Path.expand("../../fixtures/opencode_input_identity.mjs", __DIR__)
    {output, status} = System.cmd("node", [fixture, plugin], stderr_to_stdout: true)
    assert status == 0, output
    assert output == "identity transport assertions passed\n"
  end
end
