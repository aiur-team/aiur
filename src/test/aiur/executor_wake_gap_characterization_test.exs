defmodule Aiur.ExecutorWakeGapCharacterizationTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.Executor.StatePaths
  alias Aiur.{ExecutorEvents, ExecutorListener, ExecutorWakeInbox, JsonStore}

  @listener_name Aiur.ExecutorListener.WakeGapTest
  @inbox_name Aiur.ExecutorWakeInbox.WakeGapTest

  setup do
    previous = Application.get_env(:aiur, :executor_command_alerts?)
    Application.put_env(:aiur, :executor_command_alerts?, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :executor_command_alerts?),
        else: Application.put_env(:aiur, :executor_command_alerts?, previous)
    end)

    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})
    :ok
  end

  # Characterization, deliberately green on main: documents contract §7.1 gap.
  # A Bucket 2 fix must flip the wake-gap test and say so in its PR.
  test "an allowlisted ticket wake published while the listener is down is not replayed (characterization)" do
    id = System.unique_integer([:positive])
    ticket = "wake-gap-#{id}"
    pattern = "ticket.#{ticket}.pr.*"
    listener = start_listener(patterns: [pattern])
    assert pattern in Exchange.bindings_for(listener)
    stop_supervised!(ExecutorListener)
    refute Process.alive?(listener)

    topic = "ticket.#{ticket}.pr.merged"

    Exchange.publish(topic, %{
      id: id,
      topic: topic,
      pr: %{"number" => 7}
    })

    restarted = start_listener(patterns: [pattern])
    assert pattern in Exchange.bindings_for(restarted)
    # An unrelated live wake must not invalidate the missing-event witness.
    other_topic = "ticket.#{ticket}.pr.opened"
    Exchange.publish(other_topic, %{id: System.unique_integer([:positive]), topic: other_topic})
    :sys.get_state(restarted)
    send(@inbox_name, :flush)
    records = ExecutorWakeInbox.pending(@inbox_name)

    assert Enum.any?(records, &(&1["topic"] == other_topic))
    refute Enum.any?(records, &(&1["topic"] == topic and &1["event_id"] == id))
  end

  test "an executor.* Command published while the listener is down is replayed (characterization)" do
    :ok = Exchange.subscribe("executor.command.requested")
    listener = start_listener()
    stop_supervised!(ExecutorListener)
    refute Process.alive?(listener)

    assert {:ok, id, _count} = ExecutorEvents.publish_requested(command_decision("dec-wake-gap-control"))
    refute_received {:event, %{"topic" => "executor.command.requested"}}

    restarted = start_listener()
    state = :sys.get_state(restarted)

    assert_received {:event, %{"topic" => "executor.command.requested", "message" => message}}
    assert message =~ "dec-wake-gap-control"
    assert state.watermark >= id
    assert is_integer(watermark()) and watermark() >= id
  end

  defp start_listener(opts \\ []) do
    start_supervised!({ExecutorListener, Keyword.merge([name: @listener_name, inbox: @inbox_name, patterns: ["executor.#"], reconcile?: false, resubscribe_interval_ms: :infinity], opts)})
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

  defp watermark_path, do: StatePaths.watermark_path()

  defp watermark do
    case JsonStore.read(watermark_path()) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) -> id
      _other -> nil
    end
  end
end
