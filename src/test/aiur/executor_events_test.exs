defmodule Aiur.ExecutorEventsTest do
  use Aiur.TestSupport

  alias Aiur.{ExecutorEvents, JsonStore}
  alias Aiur.Config.Paths
  alias Aiur.Events.Exchange

  setup do
    previous = Application.get_env(:aiur, :log_file)
    root = Path.join(System.tmp_dir!(), "aiur-executor-events-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :log_file, Path.join(root, "aiur.log"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :log_file, previous), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(root)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    :ok
  end

  test "publishes executor events immediately and replays them from the persisted cursor journal" do
    :ok = Exchange.subscribe("executor.#")

    assert {:ok, id, count} = ExecutorEvents.publish("executor.notify.release", %{message: "ready"})
    assert count >= 1
    assert_receive {:event, %{id: ^id, topic: "executor.notify.release", message: "ready"}}, 500

    :ok = ExecutorEvents.subscribe("executor.#")
    assert [%{"id" => ^id, "topic" => "executor.notify.release"}] = ExecutorEvents.replay(["executor.#"], nil)
  end

  test "reconnect replay starts after the persisted Executor cursor" do
    assert {:ok, first_id, _} = ExecutorEvents.publish("executor.notify.first", %{message: "first"})
    assert {:ok, second_id, _} = ExecutorEvents.publish("executor.notify.second", %{message: "second"})

    cursor_path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.subscriptions.json")
    JsonStore.write!(cursor_path, %{"subscribed_to" => ["executor.#"], "last_seen_event_id" => first_id})

    assert ExecutorEvents.last_seen_event_id() == first_id
    assert [%{"id" => ^second_id, "topic" => "executor.notify.second"}] = ExecutorEvents.replay(ExecutorEvents.subscriptions(), ExecutorEvents.last_seen_event_id())
  end

  test "rejects GitHub-sourced executor events" do
    assert {:error, :executor_namespace_rejects_github_source} =
             ExecutorEvents.publish("executor.notify.untrusted", %{message: "nope"}, source: :github)
  end
end
