defmodule Aiur.Orchestrator.OperatorMessages.AlertsTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.OperatorMessages

  @pause_causes [:operator_pause, :global_pause, :max_agent_duration, :before_run_failure]

  test "opens and resolves a distinct attention for each local pause cause" do
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    Enum.each(@pause_causes, fn cause ->
      topic = "ticket.local-pause.agent.attention.paused-#{cause}"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      entry = %{identifier: "local-pause", paused_reason: cause}

      assert :ok = OperatorMessages.maybe_emit_agent_control_alert(:working, :paused, entry)
      assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 500

      assert :ok =
               OperatorMessages.maybe_emit_agent_control_alert(
                 :paused,
                 :working,
                 %{
                   identifier: "local-pause"
                 },
                 cause
               )

      assert_receive {:event, %{"needs_attention" => false, topic: ^resolved_topic}}, 500
    end)
  end

  test "tracker generic pause resolution cannot resolve a local pause cause" do
    Publisher.set_tracked_fn(fn _ -> true end)
    topic = "ticket.local-pause.agent.attention.paused-operator_pause"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    assert :ok =
             OperatorMessages.maybe_emit_agent_control_alert(:working, :paused, %{
               identifier: "local-pause",
               paused_reason: :operator_pause
             })

    # Tracker reconciliation resolves only its generic override topic.
    assert :ok =
             Aiur.Alerts.emit_system("ticket.local-pause.agent.paused.resolved",
               issue: "local-pause",
               reason: "tracker pause override removed",
               needs_attention: false,
               severity: "info"
             )

    refute_receive {:event, %{topic: ^resolved_topic}}, 100
  end

  test "GitHub budget pause is informational and does not open an attention" do
    Publisher.set_tracked_fn(fn _ -> true end)
    wait_topic = "ticket.budget-pause.github-budget.wait"
    attention_topic = "ticket.budget-pause.agent.attention.paused-github_budget_hold"
    :ok = Exchange.subscribe(wait_topic)
    :ok = Exchange.subscribe(attention_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    assert :ok =
             OperatorMessages.maybe_emit_agent_control_alert(:working, :paused, %{
               identifier: "budget-pause",
               paused_reason: :github_budget_hold
             })

    assert_receive {:event,
                    %{
                      "needs_attention" => false,
                      "severity" => "info",
                      topic: ^wait_topic
                    }},
                   500

    refute_receive {:event, %{topic: ^attention_topic}}, 100
  end
end
