defmodule Aiur.DecisionAttentionSignalsTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAttentionSignals, DecisionValidation}

  @ticket %{identifier: "42", title: "Attention signals", url: nil}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @now ~U[2026-08-21 12:00:00Z]

  test "opens and resolves a keyed suspicious-classification warning" do
    parent = self()
    decision = suspicious_decision()

    assert :ok =
             DecisionAttentionSignals.sync_classification(decision,
               condition_state_fun: fn _topic -> :unknown end,
               alert_fun: fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    assert_received {:alert, topic, opts}
    assert topic =~ "ticket.42.agent.attention.decision-classification-"
    assert opts[:needs_attention] == true
    assert opts[:reason] =~ "supervisor_allowed"

    terminal = %{decision | decision_status: :decided}

    assert :ok =
             DecisionAttentionSignals.sync_classification(terminal,
               condition_state_fun: fn candidate ->
                 if candidate == topic, do: :firing, else: :unknown
               end,
               alert_fun: fn resolved_topic, resolved_opts ->
                 send(parent, {:resolved, resolved_topic, resolved_opts})
                 :ok
               end
             )

    assert_received {:resolved, resolved_topic, resolved_opts}
    assert resolved_topic == topic <> ".resolved"
    assert resolved_opts[:needs_attention] == false
  end

  test "does not repeat a classification warning that is already firing" do
    assert :ok =
             DecisionAttentionSignals.sync_classification(suspicious_decision(),
               condition_state_fun: fn topic ->
                 if String.contains?(topic, "decision-classification"), do: :firing, else: :unknown
               end,
               alert_fun: fn _topic, _opts -> flunk("an active warning must not be emitted again") end
             )
  end

  test "does not resolve a stale warning while the Command remains blocking and open" do
    decision = %{suspicious_decision() | authority: :supervisor_allowed}

    assert :ok =
             DecisionAttentionSignals.sync_classification(decision,
               condition_state_fun: fn topic ->
                 if String.contains?(topic, "decision-stale"), do: :firing, else: :unknown
               end,
               alert_fun: fn _topic, _opts -> flunk("a still-stale warning must remain firing") end
             )
  end

  test "resolves a firing stale warning after the Command becomes terminal" do
    decision = %{suspicious_decision() | authority: :supervisor_allowed, decision_status: :decided}

    assert :ok =
             DecisionAttentionSignals.sync_classification(decision,
               condition_state_fun: fn topic ->
                 if String.contains?(topic, "decision-stale"), do: :firing, else: :unknown
               end,
               alert_fun: fn topic, opts ->
                 send(self(), {:resolved, topic, opts})
                 :ok
               end
             )

    assert_received {:resolved, topic, opts}
    assert topic =~ "decision-stale"
    assert String.ends_with?(topic, ".resolved")
    assert opts[:needs_attention] == false
  end

  test "reconciliation batches topic state and preserves firing expiry edges" do
    parent = self()
    decision = suspicious_decision()

    assert :ok =
             DecisionAttentionSignals.reconcile([decision], [decision], [], @now,
               condition_states_fun: fn topics ->
                 send(parent, {:topics, topics})
                 Map.new(topics, &{&1, :unknown})
               end,
               alert_fun: fn topic, _opts ->
                 send(parent, {:alert, topic})
                 :ok
               end
             )

    assert_received {:topics, topics}
    assert length(Enum.uniq(topics)) == 2
    assert_received {:alert, classification_topic}
    assert_received {:alert, stale_topic}
    assert classification_topic =~ "decision-classification"
    assert stale_topic =~ "decision-stale"

    assert :ok =
             DecisionAttentionSignals.reconcile([decision], [decision], [], @now,
               condition_states_fun: &Map.new(&1, fn topic -> {topic, :firing} end),
               alert_fun: fn _topic, _opts -> flunk("firing warnings must not repeat") end
             )
  end

  test "stale and expired signals name the actionable pattern" do
    parent = self()
    decision = suspicious_decision()

    for signal <- [:stale_blocking, :expired_unanswerable] do
      assert :ok =
               DecisionAttentionSignals.sync_expiry(decision, signal, @now,
                 condition_state_fun: fn _topic -> :unknown end,
                 alert_fun: fn topic, opts ->
                   send(parent, {:alert, signal, topic, opts})
                   :ok
                 end
               )
    end

    assert_received {:alert, :stale_blocking, stale_topic, stale_opts}
    assert stale_topic =~ "decision-stale"
    assert stale_opts[:reason] =~ "older than one day"
    assert stale_opts[:needs_attention] == true

    assert_received {:alert, :expired_unanswerable, expired_topic, expired_opts}
    assert expired_topic =~ "decision-expired-unanswerable"
    assert expired_opts[:reason] =~ "outside the Executor's floor"
    assert expired_opts[:needs_attention] == true
  end

  defp suspicious_decision do
    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{
                 "question" => "Use either reversible operational option?",
                 "blocking" => true,
                 "authority" => "human_required",
                 "reversibility" => "reversible",
                 "options" => [
                   %{"id" => "one", "label" => "One", "risk" => "low"},
                   %{"id" => "two", "label" => "Two", "risk" => "low"}
                 ],
                 "recommendation" => %{"option_id" => "one", "reason" => "Lowest cost."}
               },
               ticket: @ticket,
               source: @source,
               now: DateTime.add(@now, -86_400, :second)
             )

    decision
  end
end
