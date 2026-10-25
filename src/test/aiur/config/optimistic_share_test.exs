defmodule Aiur.Config.OptimisticShareTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema

  test "optimistic share defaults to half and accepts both endpoints" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.build_queue.optimistic_slot_share == 0.5

    assert {:ok, null_settings} = Schema.parse(%{"build_queue" => %{"optimistic_slot_share" => nil}})
    assert null_settings.build_queue.optimistic_slot_share == 0.5

    for share <- [0, 0.25, 1] do
      assert {:ok, settings} = Schema.parse(%{"build_queue" => %{"optimistic_slot_share" => share}})
      assert settings.build_queue.optimistic_slot_share == share
    end
  end

  test "optimistic share rejects out-of-range and invalid values" do
    for share <- [-0.1, 1.5, "invalid"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{"optimistic_slot_share" => share}})
      assert message =~ "build_queue.optimistic_slot_share"
    end
  end
end
