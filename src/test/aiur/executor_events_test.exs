defmodule Aiur.ExecutorEventsTest do
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.ExecutorEvents
  alias Aiur.JsonStore

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
    assert {:ok, [%{"id" => ^id, "topic" => "executor.notify.release"}]} = ExecutorEvents.replay(["executor.#"], nil)
  end

  test "reconnect replay starts after the persisted Executor cursor" do
    assert {:ok, first_id, _} = ExecutorEvents.publish("executor.notify.first", %{message: "first"})
    assert {:ok, second_id, _} = ExecutorEvents.publish("executor.notify.second", %{message: "second"})

    cursor_path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.subscriptions.json")
    JsonStore.write!(cursor_path, %{"subscribed_to" => ["executor.#"], "last_seen_event_id" => first_id})

    assert ExecutorEvents.last_seen_event_id() == first_id

    assert {:ok, [%{"id" => ^second_id, "topic" => "executor.notify.second"}]} =
             ExecutorEvents.replay(ExecutorEvents.subscriptions(), ExecutorEvents.last_seen_event_id())
  end

  test "rejects GitHub-sourced executor events" do
    assert {:error, :executor_namespace_rejects_github_source} =
             ExecutorEvents.publish("executor.notify.untrusted", %{message: "nope"}, source: :github)

    assert {:error, :executor_namespace_rejects_github_source} =
             ExecutorEvents.publish("executor.notify.untrusted", %{message: "nope"}, source: %{"kind" => "github"})

    assert {:error, :executor_namespace_rejects_github_source} =
             ExecutorEvents.publish("executor.notify.untrusted", %{message: "nope", source: "github"})

    assert {:ok, []} = ExecutorEvents.replay(["executor.#"], nil)
  end

  test "publishes deferred decisions with dashboard provenance" do
    :ok = Exchange.subscribe("executor.decision.deferred")

    decision = %Decision{
      decision_id: "dec-deferred",
      version: 1,
      ticket: %{identifier: "1380", title: "Executor events", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Should the Executor handle this?",
      context: %{short_summary: "A deferred decision", long_context_markdown: nil},
      options: [%{id: "yes", label: "Yes", description: nil, benefits: nil, drawbacks: nil, risk: nil}],
      artifacts: [],
      created_at: DateTime.utc_now(),
      content_hash: "content-hash"
    }

    assert {:ok, _id, _count} = ExecutorEvents.publish_deferred(decision)

    assert_receive {:event,
                    %{
                      topic: "executor.decision.deferred",
                      decision_id: "dec-deferred",
                      issue_identifier: "1380",
                      provenance: :operator_dashboard
                    }},
                   500
  end

  test "persists subscription management and rejects malformed topics" do
    assert ExecutorEvents.subscriptions() == []
    assert ExecutorEvents.last_seen_event_id() == nil

    assert :ok = ExecutorEvents.subscribe("executor.notify.*")
    assert ExecutorEvents.subscriptions() == ["executor.notify.*"]
    assert :ok = ExecutorEvents.unsubscribe("executor.notify.*")
    assert ExecutorEvents.subscriptions() == []

    assert {:error, :invalid_topic} = ExecutorEvents.subscribe("executor..notify")
    assert {:error, :invalid_topic} = ExecutorEvents.unsubscribe(".executor.notify")
    assert {:error, :invalid_topic} = ExecutorEvents.publish("", %{message: "nope"})
    assert {:error, :invalid_topic} = ExecutorEvents.publish("ticket.42.agent.decision.requested", %{message: "nope"})
    assert {:error, :invalid_topic} = ExecutorEvents.subscribe("#")
  end

  test "listener delivers live events and advances the persisted cursor" do
    listener = spawn(fn -> ExecutorEvents.listen(topic: "executor.#") end)
    on_exit(fn -> if Process.alive?(listener), do: Process.exit(listener, :kill) end)

    assert eventually(fn -> "executor.#" in Exchange.bindings_for(listener) end)
    assert {:ok, id, _count} = ExecutorEvents.publish("executor.notify.live", %{message: "wake"})
    assert eventually(fn -> ExecutorEvents.last_seen_event_id() == id end)
  end

  test "fails replay closed when the executor journal has interior corruption" do
    journal_path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.events.ndjson")

    File.mkdir_p!(Path.dirname(journal_path))

    File.write!(
      journal_path,
      ~s({"id":1,"topic":"executor.notify.before"}\nnot-json\n{"id":2,"topic":"executor.notify.after"}\n)
    )

    assert {:error, {:corrupt, 2, _reason}} = ExecutorEvents.replay(["executor.#"], nil)
    assert ExecutorEvents.last_seen_event_id() == nil
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
