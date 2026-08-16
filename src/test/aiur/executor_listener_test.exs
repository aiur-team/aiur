defmodule Aiur.ExecutorListenerTest do
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.ExecutorEvents
  alias Aiur.ExecutorListener
  alias Aiur.JsonStore

  @listener_name Aiur.ExecutorListener.Test

  setup do
    # The listener reads/writes its durable watermark under the per-test log
    # root (TestSupport isolates :log_file), so a "restart" in a test starts a
    # fresh process over the same watermark.
    on_exit(fn ->
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      :ok
    end)

    :ok
  end

  defp start_listener(opts \\ []) do
    start_supervised!({ExecutorListener, Keyword.merge([name: @listener_name, resubscribe_interval_ms: 100], opts)})
  end

  defp command_decision(decision_id) do
    %Decision{
      decision_id: decision_id,
      version: 1,
      ticket: %{identifier: "1380", title: "Executor events", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Should the Executor handle this?",
      context: %{short_summary: "A command for the Executor", long_context_markdown: nil},
      options: [%{id: "yes", label: "Yes", description: nil, benefits: nil, drawbacks: nil, risk: nil}],
      artifacts: [],
      created_at: DateTime.utc_now(),
      content_hash: "content-hash"
    }
  end

  defp watermark_path do
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.listener.watermark.json")
  end

  defp watermark do
    case JsonStore.read(watermark_path()) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) -> id
      _other -> nil
    end
  end

  test "subscribes to executor.# on launch and reports alive only while listening" do
    pid = start_listener()

    assert is_pid(pid)
    assert "executor.#" in Exchange.bindings_for(pid)
    assert ExecutorListener.alive?(@listener_name)
  end

  test "the periodic re-subscribe check never duplicates the binding" do
    pid = start_listener(resubscribe_interval_ms: 50)

    # Let several re-subscribe ticks pass: the Exchange binding table is a
    # duplicate bag, so an unconditional re-subscribe would multiply delivery.
    Process.sleep(200)
    assert Exchange.bindings_for(pid) == ["executor.#"]
    assert ExecutorListener.alive?(@listener_name)
  end

  test "re-subscribes and replays missed events after the Exchange drops the binding" do
    :ok = Exchange.subscribe("executor.command.requested")
    pid = start_listener(resubscribe_interval_ms: 500)

    first = command_decision("dec-gap-first")
    assert {:ok, _first_id, _count} = ExecutorEvents.publish_requested(first)
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => first_message}}, 500
    assert first_message =~ "dec-gap-first"
    assert eventually(fn -> is_integer(watermark()) end)

    # Simulate the Exchange being restarted by the supervisor: its fresh
    # binding table no longer has this listener's row. The next re-subscribe
    # tick is 500ms out, so the Command below is published during a real gap.
    table = :persistent_term.get({{Aiur.Events.Exchange, :table}, Aiur.Events.Exchange})
    :ets.match_delete(table, {:_, pid, :_})
    assert ExecutorListener.alive?(@listener_name) == false

    second = command_decision("dec-gap-second")
    assert {:ok, _second_id, _count} = ExecutorEvents.publish_requested(second)
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200

    # The next re-subscribe tick re-establishes the binding and replays the
    # missed Command — but never re-notifies the already-delivered one.
    assert eventually(fn -> ExecutorListener.alive?(@listener_name) end)
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => replayed}}, 1_000
    assert replayed =~ "dec-gap-second"
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
  end

  test "reports not alive when no listener is running" do
    refute ExecutorListener.alive?(Aiur.ExecutorListener.NoSuch)
    refute ExecutorListener.alive?(@listener_name)
  end

  test "emits a needs-attention alert for a requested Command and advances its durable watermark" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    decision = command_decision("dec-listener-requested")
    assert {:ok, id, _count} = ExecutorEvents.publish_requested(decision)

    assert_receive {:event,
                    %{
                      "topic" => "executor.command.requested",
                      "source_ticket_id" => "1380",
                      "needs_attention" => true,
                      "message" => message
                    }},
                   500

    assert message =~ "dec-listener-requested"
    assert message =~ "ticket #1380"

    # The listener consumes the Command AND the alert it emitted for it, so the
    # durable watermark lands at or past the Command's journal id (shared id
    # counter). Wait for the write rather than racing the listener's mailbox.
    assert eventually(fn -> is_integer(watermark()) and watermark() >= id end)
  end

  test "emits a needs-attention alert for a deferred Command too" do
    :ok = Exchange.subscribe("executor.command.deferred")
    start_listener()

    assert {:ok, _id, _count} = ExecutorEvents.publish_deferred(command_decision("dec-listener-deferred"))

    assert_receive {:event, %{"topic" => "executor.command.deferred", "source_ticket_id" => "1380"}}, 500
  end

  test "does not alert for non-command executor events" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    assert {:ok, _id, _count} = ExecutorEvents.publish("executor.notify.release", %{message: "ready"})
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
    refute_receive {:event, %{"topic" => "executor.command.deferred"}}, 100
  end

  test "a restarted listener replays only events newer than its durable watermark" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    first = command_decision("dec-restart-first")
    assert {:ok, first_id, _count} = ExecutorEvents.publish_requested(first)
    assert_receive {:event, %{"topic" => "executor.command.requested", "source_ticket_id" => "1380", "message" => first_message}}, 500
    assert first_message =~ "dec-restart-first"

    # Persisted watermark reflects the delivered event.
    assert eventually(fn -> is_integer(watermark()) and watermark() >= first_id end)

    # The listener dies (simulating a mid-run exit); a new Command is published
    # while nothing is listening.
    stop_supervised!(ExecutorListener)
    second = command_decision("dec-restart-second")
    assert {:ok, second_id, _count} = ExecutorEvents.publish_requested(second)
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200

    # A fresh listener over the same watermark replays the missed event but
    # never re-notifies for the already-delivered one.
    start_listener()

    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => replayed_message}}, 500
    assert replayed_message =~ "dec-restart-second"
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
    assert eventually(fn -> is_integer(watermark()) and watermark() >= second_id end)
  end

  defp eventually(fun, attempts \\ 100)
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
