defmodule Aiur.TestSupport.AwaitingCommandsTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionStore
  alias Aiur.TestSupport.AwaitingCommands

  # The stub sits in global Endpoint config, so an unrelated process can call it
  # mid-test. A crash there takes the linked test down with it (#4838).
  test "survives a second caller's reads while installed" do
    store = AwaitingCommands.start(awaiting: 2)

    other =
      Task.async(fn ->
        {DecisionStore.recent_audit_history(50, store), GenServer.call(store, {:recent_decisions, 50}), GenServer.call(store, :list)}
      end)

    assert {%{records: [], contexts: %{}, actions: %{}, revisions: %{}}, [], {:error, :unsupported_by_stub}} =
             Task.await(other)

    assert {:ok, %{counts: %{awaiting: 2}, health: :writable}} = GenServer.call(store, :retained_counts)
  end
end
