defmodule Aiur.Events.ExecutorJournalGoldenCharacterizationTest do
  use Aiur.TestSupport

  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorEvents

  @fixture Path.expand("../../fixtures/events/executor_journal_golden.ndjson", __DIR__)

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-journal-golden")
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    :ok
  end

  # Deliberately green before the facade extraction; characterization, not change coverage.
  test "Executor journal bytes and replay retain the golden contract (characterization)" do
    assert {:ok, first, _} = ExecutorEvents.publish("executor.notify.release", %{message: "ready"})
    assert {:ok, second, _} = ExecutorEvents.publish("executor.decision.requested", %{decision_id: "golden-decision", decision_version: 1})
    bytes = File.read!(StatePaths.journal_path())
    normalized = bytes |> String.replace(Integer.to_string(first), "1") |> String.replace(Integer.to_string(second), "2")
    assert normalized == File.read!(@fixture)
    File.write!(StatePaths.journal_path(), normalized)
    Aiur.JsonStore.write!(StatePaths.subscriptions_path(), %{"subscribed_to" => ["executor.#"], "last_seen_event_id" => nil})
    assert {:ok, events} = ExecutorEvents.replay(["executor.#"], nil)

    assert events == [
             %{"id" => 1, "topic" => "executor.notify.release", "source" => "executor_cli", "message" => "ready"},
             %{"id" => 2, "topic" => "executor.decision.requested", "source" => "executor_cli", "decision_id" => "golden-decision", "decision_version" => 1}
           ]
  end
end
