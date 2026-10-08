defmodule Aiur.ExecutorWakeGapCharacterizationTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.Executor.StatePaths
  alias Aiur.{ExecutorEvents, ExecutorListener, ExecutorWakeInbox, JsonStore}

  @listener_name Aiur.ExecutorListener.WakeGapTest

  setup do
    previous = Application.get_env(:aiur, :executor_command_alerts?)
    Application.put_env(:aiur, :executor_command_alerts?, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :executor_command_alerts?),
        else: Application.put_env(:aiur, :executor_command_alerts?, previous)
    end)

    refute Process.whereis(ExecutorWakeInbox)
    inbox = start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
    assert Process.whereis(ExecutorWakeInbox) == inbox
    :ok
  end

  # Characterization, deliberately green on main: documents contract §7.1 gap.
  # A Bucket 2 fix must flip the wake-gap test and say so in its PR.
  test "an allowlisted ticket wake published while the listener is down is not replayed (characterization)" do
    listener = start_listener()
    assert "ticket.*.pr.merged" in Exchange.bindings_for(listener)
    stop_supervised!(ExecutorListener)
    assert Exchange.bindings_for(listener) == []

    Exchange.publish("ticket.42.pr.merged", %{
      id: System.unique_integer([:positive]),
      topic: "ticket.42.pr.merged",
      pr: %{"number" => 7}
    })

    restarted = start_listener()
    assert "ticket.*.pr.merged" in Exchange.bindings_for(restarted)
    :sys.get_state(restarted)
    assert ExecutorWakeInbox.wait(300) == :timeout
    assert watermark() == nil
  end

  test "an executor.* Command published while the listener is down is replayed (characterization)" do
    :ok = Exchange.subscribe("executor.command.requested")
    listener = start_listener()
    stop_supervised!(ExecutorListener)
    assert Exchange.bindings_for(listener) == []

    assert {:ok, id, _count} = ExecutorEvents.publish_requested(command_decision("dec-wake-gap-control"))
    refute_received {:event, %{"topic" => "executor.command.requested"}}

    restarted = start_listener()
    state = :sys.get_state(restarted)

    assert_received {:event, %{"topic" => "executor.command.requested", "message" => message}}
    assert message =~ "dec-wake-gap-control"
    assert state.watermark >= id
    assert is_integer(watermark()) and watermark() >= id
  end

  defp start_listener do
    start_supervised!({ExecutorListener, name: @listener_name, resubscribe_interval_ms: :infinity})
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
