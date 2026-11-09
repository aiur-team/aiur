defmodule Aiur.ControlCLI.ConfigExplainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.ControlCall
  alias Aiur.ControlCLI.ConfigExplain
  alias Aiur.Machine.Settings

  # Every layer reader is injected so the test never reads ~/.aiur, instance overrides or the live orchestrator.
  defp injected do
    [
      candidates: ["/nonexistent/project/config", "/nonexistent/user/config"],
      machine_fun: fn -> {:ok, %Settings{}} end,
      overrides_fun: fn -> {:ok, []} end,
      session_cap_fun: fn -> nil end,
      load_fun: fn _path -> :missing end,
      now: ~U[2026-11-06 16:00:00Z]
    ]
  end

  defp run(key, opts) do
    capture_io(fn -> capture_io(:stderr, fn -> ConfigExplain.explain(key, opts, injected()) end) |> then(&send(self(), {:stderr, &1})) end)
  end

  test "text output renders owner, unavailable layers and freshness" do
    out = run("max_vertical_panes", [])
    assert out =~ "max_vertical_panes = 3"
    assert out =~ "owner L0 default"
    assert out =~ "unavailable L4 shared intent (intent_store_not_implemented)"
    assert out =~ "as of 2026-11-06T16:00:00Z (age 0 ms, live)"
    assert out =~ "#{Aiur.ControlCLI.Protocol.exit_marker()}0"
  end

  test "json output decodes with a string layer" do
    out = run("max_vertical_panes", json: true)
    assert %{"layer" => "L0", "value" => 3} = out |> String.split("\n") |> hd() |> Jason.decode!()
  end

  test "unknown key exits 64 with a suggestion" do
    out = run("max_vertical_pane", [])
    assert out =~ "max_vertical_panes"
    assert out =~ "#{Aiur.ControlCLI.Protocol.exit_marker()}64"
  end

  test "allowlist accepts explain as :read and rejects unknown options" do
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.ControlCLI.ConfigExplain.explain(\"a.b\", json: true)")
    assert {:error, _} = ControlCall.parse("Aiur.ControlCLI.ConfigExplain.explain(\"a\", write: true)")
    assert {:error, _} = ControlCall.parse("Aiur.ControlCLI.ConfigExplain.explain(\"a\", [], [])")
  end
end
