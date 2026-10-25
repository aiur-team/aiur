Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.StartOptionsTest do
  use Aiur.DecisionStoreCase, async: false

  test "unnamed stores require an explicit durable state directory" do
    assert {:error, :unnamed_store_requires_state_dir} =
             DecisionStore.start_link(filesystem_sync_fun: fn -> :ok end)
  end

  test "non-singleton stores require an explicit durable state directory" do
    custom_name = Module.concat(__MODULE__, CustomStore)

    result = DecisionStore.start_link(name: custom_name, filesystem_sync_fun: fn -> :ok end)

    case result do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end

    assert {:error, :non_singleton_store_requires_state_dir} = result
  end

  test "non-singleton stores reject invalid durable state directories" do
    custom_name = Module.concat(__MODULE__, InvalidDirectoryStore)

    for name <- [nil, custom_name, DecisionStore], state_dir <- [nil, "", :invalid] do
      assert {:error, :invalid_state_dir} =
               DecisionStore.start_link(name: name, state_dir: state_dir, filesystem_sync_fun: fn -> :ok end)
    end
  end

  test "two unnamed stores isolate their durable state", %{dir: dir} do
    first_dir = Path.join(dir, "first")
    second_dir = Path.join(dir, "second")

    {:ok, first} =
      start_supervised(
        {
          DecisionStore,
          [
            state_dir: first_dir,
            filesystem_sync_fun: fn -> :ok end
          ]
        },
        id: :first_unnamed_decision_store
      )

    {:ok, second} =
      start_supervised(
        {
          DecisionStore,
          [
            state_dir: second_dir,
            filesystem_sync_fun: fn -> :ok end
          ]
        },
        id: :second_unnamed_decision_store
      )

    assert first != second

    assert {:ok, %{decision: %{decision_id: first_id}}} =
             request(first, %{"source_id" => "first-store", "question" => "First store", "blocking" => false})

    assert {:ok, %{decision: %{decision_id: second_id}}} =
             request(second, %{"source_id" => "second-store", "question" => "Second store", "blocking" => false})

    refute first_id == second_id
    assert File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "First store"
    refute File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "Second store"
    assert File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "Second store"
    refute File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "First store"
  end

  test "custom-named stores isolate their durable state", %{dir: dir} do
    first_dir = Path.join(dir, "named-first")
    second_dir = Path.join(dir, "named-second")
    first_name = Module.concat(__MODULE__, FirstCustomStore)
    second_name = Module.concat(__MODULE__, SecondCustomStore)

    {:ok, first} =
      start_supervised(
        {DecisionStore, [name: first_name, state_dir: first_dir, filesystem_sync_fun: fn -> :ok end]},
        id: :first_custom_decision_store
      )

    {:ok, second} =
      start_supervised(
        {DecisionStore, [name: second_name, state_dir: second_dir, filesystem_sync_fun: fn -> :ok end]},
        id: :second_custom_decision_store
      )

    assert {:ok, %{decision: %{decision_id: first_id}}} =
             request(first, %{"source_id" => "first-custom-store", "question" => "First custom store", "blocking" => false})

    assert {:ok, %{decision: %{decision_id: second_id}}} =
             request(second, %{"source_id" => "second-custom-store", "question" => "Second custom store", "blocking" => false})

    refute first_id == second_id
    assert File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "First custom store"
    refute File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "Second custom store"
    assert File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "Second custom store"
    refute File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "First custom store"
  end
end
