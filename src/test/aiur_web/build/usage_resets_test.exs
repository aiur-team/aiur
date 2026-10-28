defmodule AiurWeb.Build.UsageResetsTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Build.{Payload, Usage}

  test "per-account resets align with sorted names and validate with or without optional field" do
    work = put_in(I.account(88, 60), [:reading, :windows, Access.at(0), :resets_at], DateTime.add(I.now(), 7200))
    inputs = I.inputs(%{families: [:claude], accounts: %{"work" => work, "personal" => %{reading: nil, observed_at: I.now()}}, meters: %{claude: I.snapshot(:claude, %{"primary" => I.window(50)})}})
    usage = Usage.block({:ok, :streamdeck}, inputs, I.now())
    [row] = usage.providers
    assert row.accounts == ["personal", "work"]
    assert row.session.acc == [nil, 12]
    assert row.session.resets == [nil, DateTime.to_unix(DateTime.add(I.now(), 7200), :millisecond)]
    assert row.weekly.resets == [nil, DateTime.to_unix(DateTime.add(I.now(), 7200), :millisecond)]
    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    wire = Payload.scrub(usage)
    assert Payload.validate(Map.put(fixture, "usage", wire)) == :ok
    old = update_in(wire, ["providers", Access.all(), "session"], &Map.delete(&1, "resets"))
    old = update_in(old, ["providers", Access.all(), "weekly"], &Map.delete(&1, "resets"))
    assert Payload.validate(Map.put(fixture, "usage", old)) == :ok
    invalid = put_in(wire, ["providers", Access.at(0), "session", "resets"], ["bad"])
    assert {:error, _} = Payload.validate(Map.put(fixture, "usage", invalid))
  end
end
