defmodule Aiur.Config.QueueSetsTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema

  test "absent set settings default to none, unlimited sets and no reserve" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.build_queue.set_order == "none"
    assert settings.build_queue.max_active_sets == nil
    assert settings.build_queue.spill_reserve_slots == 0
  end

  test "set overrides survive parsing and reject invalid orders, bounds and types" do
    assert {:ok, settings} = Schema.parse(%{"build_queue" => %{"set_order" => "ranked", "max_active_sets" => 1, "spill_reserve_slots" => 6}})
    assert settings.build_queue.set_order == "ranked"
    assert settings.build_queue.max_active_sets == 1
    assert settings.build_queue.spill_reserve_slots == 6

    for {key, values} <- [{"set_order", ["other"]}, {"max_active_sets", [0, -1, "oops"]}, {"spill_reserve_slots", [-1, "oops"]}], value <- values do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{key => value}})
      assert message =~ "build_queue.#{key}"
    end
  end
end
