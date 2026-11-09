defmodule Aiur.Config.ProvenanceCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Config.ProvenanceCLI
  alias Aiur.ControlCall

  test "text output renders owner, unavailable layers and freshness" do
    out = capture_io(fn -> ProvenanceCLI.explain("max_vertical_panes", []) end)
    assert out =~ "max_vertical_panes = 3"
    assert out =~ "owner L0 default"
    assert out =~ "unavailable L4 shared intent (intent_store_not_implemented)"
    assert out =~ ~r/as of \S+ \(age 0 ms, live\)/
  end

  test "json output decodes with a string layer" do
    out = capture_io(fn -> ProvenanceCLI.explain("max_vertical_panes", json: true) end)
    assert %{"layer" => "L0", "value" => 3} = out |> String.split("\n") |> hd() |> Jason.decode!()
  end

  test "unknown key exits 64 with a suggestion" do
    out = capture_io(fn -> capture_io(:stderr, fn -> ProvenanceCLI.explain("max_vertical_pane", []) end) end)
    assert out =~ "max_vertical_panes"
    assert out =~ "64"
  end

  test "allowlist accepts explain as :read and rejects unknown options" do
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.Config.ProvenanceCLI.explain(\"a.b\", json: true)")
    assert {:error, _} = ControlCall.parse("Aiur.Config.ProvenanceCLI.explain(\"a\", write: true)")
  end
end
