defmodule Aiur.ExecutorListenerWakeTest do
  use Aiur.TestSupport

  alias Aiur.Alerts
  alias Aiur.BuildQueue.Attention, as: BuildQueueAttention
  alias Aiur.Events.Publisher
  alias Aiur.ExecutorBindings
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox

  @listener_name Aiur.ExecutorListener.WakeTest
  @inbox_name Aiur.ExecutorWakeInbox.ListenerWakeTest

  defp start_listener(opts) do
    start_supervised!({ExecutorListener, Keyword.merge([name: @listener_name, resubscribe_interval_ms: 100], opts)})
  end

  test "attention alerts wake the Executor when their ticket has no running agent" do
    ticket_identifier = Integer.to_string(System.unique_integer([:positive]))
    inbox = start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})

    listener =
      start_listener(
        inbox: @inbox_name,
        patterns: ["ticket.*.agent.attention.*"],
        reconcile?: false,
        resubscribe_interval_ms: :infinity,
        escalation_interval_ms: :infinity
      )

    Publisher.set_tracked_fn(fn _ticket -> false end)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ticket -> true end) end)

    assert :ok =
             Alerts.emit_system("ticket.#{ticket_identifier}.agent.attention.waiting_for_human",
               issue: ticket_identifier,
               reason: "Agent has been waiting for Executor input.",
               needs_attention: true,
               severity: "warning",
               central: true
             )

    topic = "ticket.#{ticket_identifier}.agent.attention.waiting_for_human"

    assert is_map(:sys.get_state(listener))
    send(inbox, :flush)
    assert is_map(:sys.get_state(inbox))

    assert {:ok, records} = ExecutorWakeInbox.wait(0, @inbox_name)

    assert [
             %{
               "topic" => ^topic,
               "topic_class" => "ticket.agent.attention.waiting_for_human",
               "ticket" => ^ticket_identifier,
               "needs_attention" => true
             }
           ] = own_records(records, ticket_identifier)

    assert [%{"topic" => ^topic}] = own_records(ExecutorWakeInbox.pending(@inbox_name), ticket_identifier)
  end

  test "every ticket attention binding wakes the Executor when its ticket is untracked" do
    patterns =
      ExecutorBindings.defaults()
      |> Enum.filter(fn {pattern, class} -> class == "attention:auto" and String.starts_with?(pattern, "ticket.") end)
      |> Enum.map(&elem(&1, 0))

    ticket_identifier = Integer.to_string(System.unique_integer([:positive]))
    topics = Enum.map(patterns, &concrete_ticket_topic(&1, ticket_identifier))
    inbox = start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})

    listener =
      start_listener(
        inbox: @inbox_name,
        patterns: patterns,
        reconcile?: false,
        resubscribe_interval_ms: :infinity,
        escalation_interval_ms: :infinity
      )

    Publisher.set_tracked_fn(fn _ticket -> false end)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ticket -> true end) end)

    for topic <- topics do
      if String.contains?(topic, ".queue.attention.") do
        assert :ok = BuildQueueAttention.transient(:prerequisite_failed, ticket_identifier, %{})
      else
        assert :ok =
                 Alerts.emit_system(topic,
                   issue: ticket_identifier,
                   message: "Attention requires Executor review.",
                   reason: "Attention requires Executor review.",
                   needs_attention: true,
                   severity: "warning",
                   central: true
                 )
      end
    end

    # Every publication is sent by this test process. The listener barrier
    # proves it handled all of them; flushing the inbox then makes the durable
    # assertion independent of its debounce timer and host scheduling.
    assert is_map(:sys.get_state(listener))
    send(inbox, :flush)
    assert is_map(:sys.get_state(inbox))

    assert own_topics(ExecutorWakeInbox.pending(@inbox_name), ticket_identifier) == Enum.sort(topics)
    assert {:ok, records} = ExecutorWakeInbox.wait(0, @inbox_name)
    assert own_topics(records, ticket_identifier) == Enum.sort(topics)
    assert Enum.all?(own_records(records, ticket_identifier), &(&1["count"] == 1))
    assert own_topics(ExecutorWakeInbox.pending(@inbox_name), ticket_identifier) == Enum.sort(topics)
  end

  # The listener subscribes to the shared bus, so attention alerts from other
  # tests' background work (such as the live orchestrator's comment-rework
  # retries, #4812) land in this inbox too. Assert only on this test's ticket.
  defp own_records(records, ticket_identifier), do: Enum.filter(records, &(&1["ticket"] == ticket_identifier))

  defp own_topics(records, ticket_identifier), do: records |> own_records(ticket_identifier) |> Enum.map(& &1["topic"]) |> Enum.sort()

  defp concrete_ticket_topic(pattern, ticket_identifier) do
    pattern
    |> String.split(".")
    |> Enum.with_index()
    |> Enum.map_join(".", fn
      {"*", 1} -> ticket_identifier
      {"*", _index} -> "waiting_for_human"
      {"#", _index} -> "prerequisite_failed"
      {segment, _index} -> segment
    end)
  end
end
