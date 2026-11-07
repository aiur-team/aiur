defmodule Aiur.Intent.ChangeTest do
  use ExUnit.Case, async: true

  alias Aiur.Intent.Change

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        slot: "human",
        author_id: "dashboard:kevin",
        entity_kind: "ticket",
        entity_key: "aiur-team/aiur#7626",
        field: "order_key",
        value_json: "a0",
        hlc_wall_ms: 1,
        hlc_counter: 0
      },
      overrides
    )
    |> Change.new()
  end

  test "a valid change passes and round-trips through JSON" do
    c = base()
    assert Change.validate(c) == :ok
    assert Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, c.change_id)
    assert {:ok, ^c} = c |> Change.to_json() |> Jason.encode!() |> Jason.decode!() |> Change.from_json()
  end

  test "uuid binary round-trip" do
    id = Change.new_id()
    assert id |> Change.uuid_to_binary() |> Change.uuid_from_binary() == id
  end

  for {name, overrides, error} <- [
        {"slot", %{slot: "robot"}, :invalid_slot},
        {"kind", %{entity_kind: "galaxy"}, :invalid_entity_kind},
        {"field for kind", %{field: "pause"}, :invalid_field},
        {"daemon pause", %{entity_kind: "gateway", entity_key: "g", field: "pause", slot: "default"}, :daemon_pause_rejected},
        {"force without reason", %{slot: "executor", force: true, reason: "", supersedes: "x"}, :force_requires_reason_and_supersedes},
        {"force without supersedes", %{slot: "executor", force: true, reason: "r"}, :force_requires_reason_and_supersedes},
        {"force in human slot", %{force: true, reason: "r", supersedes: "x"}, :force_requires_executor_slot},
        {"project path key", %{entity_kind: "project", entity_key: "/home/u/code/x", field: "priority"}, :invalid_entity_key},
        {"project non-repo key", %{entity_kind: "project", entity_key: "justname", field: "priority"}, :invalid_entity_key},
        {"traversal key", %{entity_key: "a/../b"}, :invalid_entity_key},
        {"big value", %{value_json: String.duplicate("x", 9000)}, :value_too_large},
        {"negative hlc", %{hlc_wall_ms: -1}, :invalid_hlc},
        {"counter overflow", %{hlc_counter: 2_147_483_648}, :invalid_hlc}
      ] do
    test "rejects #{name}" do
      assert Change.validate(base(unquote(Macro.escape(overrides)))) == {:error, unquote(error)}
    end
  end

  test "error terms never carry the offending path" do
    refute inspect(Change.validate(base(%{entity_kind: "project", entity_key: "/home/u/secret", field: "priority"}))) =~ "secret"
  end
end
