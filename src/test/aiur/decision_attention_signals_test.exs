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

  test "a live blocking Command raises the stale needs-attention signal" do
    parent = self()
    decision = suspicious_decision()

    assert :ok =
             DecisionAttentionSignals.sync_expiry(decision, :stale_blocking, @now,
               condition_state_fun: fn _topic -> :unknown end,
               alert_fun: fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    assert_received {:alert, stale_topic, stale_opts}
    assert stale_topic =~ "decision-stale"
    assert stale_opts[:reason] =~ "older than one day"
    assert stale_opts[:needs_attention] == true
  end

  test "an expired-unanswerable Command is retired, never raised as needs-attention" do
    parent = self()
    decision = suspicious_decision()

    # A raised entry from an older build is cleared via the `.resolved` record —
    # the only form `AlertFeed.resolve_attention_alerts/1` treats as a clear —
    # rather than re-raised (#2458).
    assert :ok =
             DecisionAttentionSignals.sync_expiry(decision, :expired_unanswerable, @now,
               condition_state_fun: fn _topic -> :firing end,
               alert_fun: fn topic, opts ->
                 send(parent, {:resolved, topic, opts})
                 :ok
               end
             )

    assert_received {:resolved, expired_topic, expired_opts}
    assert expired_topic =~ "decision-expired-unanswerable"
    assert String.ends_with?(expired_topic, ".resolved")
    assert expired_opts[:needs_attention] == false

    # A Command that was never raised (no firing record) emits nothing at all —
    # no needs-attention entry and no resolution noise.
    assert :ok =
             DecisionAttentionSignals.sync_expiry(decision, :expired_unanswerable, @now,
               condition_state_fun: fn _topic -> :unknown end,
               alert_fun: fn _topic, _opts -> flunk("an expired Command must not emit an alert") end
             )
  end

  test "a live Command still raises inside the same reconcile that retires expired Commands" do
    parent = self()
    live = blocking_command()
    expired = %{live | decision_status: :expired}

    # The expired topic is already firing (backlog from an older build) while
    # the live Command's stale topic is not yet raised. Blanket suppression
    # would swallow both; the reconcile must retire the expired backlog while
    # still raising the live Command that needs an operator answer.
    assert :ok =
             DecisionAttentionSignals.reconcile([live], [live], [expired], @now,
               condition_states_fun: fn topics ->
                 Map.new(topics, fn topic ->
                   if String.contains?(topic, "decision-expired-unanswerable"),
                     do: {topic, :firing},
                     else: {topic, :unknown}
                 end)
               end,
               alert_fun: fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    assert_received {:alert, stale_topic, stale_opts}
    assert stale_topic =~ "decision-stale"
    assert stale_opts[:needs_attention] == true

    assert_received {:alert, expired_topic, expired_opts}
    assert expired_topic =~ "decision-expired-unanswerable"
    assert String.ends_with?(expired_topic, ".resolved")
    assert expired_opts[:needs_attention] == false
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

  # A live blocking Command that still needs an operator answer: not a
  # suspicious classification (no options), so the reconcile raises only the
  # stale signal for it.
  defp blocking_command do
    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{
                 "question" => "Still actionable?",
                 "blocking" => true,
                 "authority" => "human_required",
                 "source_id" => "live-blocking-1"
               },
               ticket: @ticket,
               source: @source,
               now: DateTime.add(@now, -86_400, :second)
             )

    decision
  end
end
