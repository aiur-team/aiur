defmodule Aiur.IntentFixtures do
  @moduledoc false
  alias Aiur.Intent.Change

  def tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    dir
  end

  def change(overrides \\ %{}) do
    %{
      slot: "human",
      author_id: "dashboard:kevin",
      entity_kind: "ticket",
      entity_key: "aiur-team/aiur#7626",
      field: "order_key",
      value_json: "a0",
      origin_gateway: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
      hlc_wall_ms: 1_000,
      hlc_counter: 0
    }
    |> Map.merge(Map.new(overrides))
    |> Change.new()
  end
end
