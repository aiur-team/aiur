defmodule Aiur.ExecutorAttention.DecisionEscalationTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAttentionSignals, DecisionValidation}
  alias Aiur.ExecutorAttention.DecisionEscalation

  @now ~U[2026-10-15 12:00:00Z]
  @source %{agent_id: "codex", session_id: "session-1", event_id: nil}

  describe "stage/2" do
    test "re-wakes at 15 and 30 minutes and reaches the operator at 45 minutes, then hourly" do
      assert DecisionEscalation.stage(14 * 60 + 59, 0) == {0, 0}
      assert DecisionEscalation.stage(15 * 60, 0) == {1, 0}
      assert DecisionEscalation.stage(30 * 60, 0) == {2, 0}
      assert DecisionEscalation.stage(45 * 60, 0) == {2, 1}
      assert DecisionEscalation.stage(104 * 60, 0) == {2, 1}
      assert DecisionEscalation.stage(105 * 60, 0) == {2, 2}
      assert DecisionEscalation.stage(165 * 60, 0) == {2, 3}
    end

    test "a Decision that gates 10 or more tickets reaches the operator at 15 minutes" do
      assert DecisionEscalation.stage(15 * 60, 9) == {1, 0}
      assert DecisionEscalation.stage(15 * 60, 10) == {1, 1}
      assert DecisionEscalation.stage(75 * 60, 38) == {2, 2}
    end
  end

  describe "run/2" do
    test "wakes the Executor at each re-wake threshold, alerts the operator at 45 minutes, and repeats hourly" do
      decision = decision("ladder", "3141", minutes_ago(0))
      {opts, events} = recorder(decision)

      fired = DecisionEscalation.run(%{}, opts.(@now))
      assert events.() == []

      fired = DecisionEscalation.run(fired, opts.(at(15)))
      assert [{:wake, %{"escalation" => "rewake", "decision_id" => id, "ticket" => "3141"}}] = events.()
      assert id == decision.decision_id

      fired = DecisionEscalation.run(fired, opts.(at(16)))
      assert events.() == []

      fired = DecisionEscalation.run(fired, opts.(at(30)))
      assert [{:wake, _record}] = events.()

      fired = DecisionEscalation.run(fired, opts.(at(45)))
      assert [{:alert, topic, alert_opts}, {:wake, _record}] = events.()
      assert topic == DecisionAttentionSignals.stale_topic(decision)
      assert alert_opts[:needs_attention] == true
      assert alert_opts[:issue] == "3141"

      fired = DecisionEscalation.run(fired, opts.(at(104)))
      assert events.() == []

      _fired = DecisionEscalation.run(fired, opts.(at(105)))
      assert [{:alert, ^topic, _opts}, {:wake, _record}] = events.()
    end

    test "a Decision gating 10 or more tickets alerts the operator at 15 minutes" do
      decision = decision("urgent", "3141", minutes_ago(0))
      {opts, events} = recorder(decision, gates: 38)

      _fired = DecisionEscalation.run(%{}, opts.(at(15)))
      assert [{:alert, _topic, alert_opts}, {:wake, %{"gates" => 38}}] = events.()
      assert alert_opts[:message] =~ "gates 38"
    end

    test "answering a Decision clears its escalation" do
      decision = decision("answered", "3141", minutes_ago(0))
      {opts, events} = recorder(decision)
      fired = DecisionEscalation.run(%{}, opts.(at(20)))
      assert [{:wake, _record}] = events.()
      assert Map.has_key?(fired, decision.decision_id)

      {answered_opts, answered_events} = recorder(%{decision | decision_status: :decided})
      fired = DecisionEscalation.run(fired, answered_opts.(at(200)))
      assert fired == %{}
      assert answered_events.() == []
    end

    test "after a restart the ladder resumes from Decision age without alerting the operator twice" do
      decision = decision("restart", "3141", minutes_ago(0))
      firing = %{DecisionAttentionSignals.stale_topic(decision) => :firing}
      {opts, events} = recorder(decision, states: firing)

      fired = DecisionEscalation.run(%{}, opts.(at(50)))
      # One catch-up wake for the Executor; the operator alert is still firing.
      assert [{:wake, _record}] = events.()
      assert %{wake: 2, operator: 1} = fired[decision.decision_id]

      _fired = DecisionEscalation.run(fired, opts.(at(105)))
      assert [{:alert, _topic, _opts}, {:wake, _record}] = events.()
    end

    test "a restart with no firing alert re-raises the current operator stage once" do
      decision = decision("restart-unalerted", "3141", minutes_ago(0))
      {opts, events} = recorder(decision)

      fired = DecisionEscalation.run(%{}, opts.(at(50)))
      assert [{:alert, _topic, _opts}, {:wake, _record}] = events.()

      _fired = DecisionEscalation.run(fired, opts.(at(51)))
      assert events.() == []
    end
  end

  describe "backstop/2" do
    test "surfaces an aged open Decision that no event backs, then throttles it for 15 minutes" do
      decision = decision("backstop", "3141", minutes_ago(0))
      {opts, events} = recorder(decision)

      # The ladder already woke at 15 minutes, so a wait at 20 minutes adds nothing.
      fired = DecisionEscalation.run(%{}, opts.(at(15)))
      assert [{:wake, _record}] = events.()
      _fired = DecisionEscalation.backstop(fired, opts.(at(20)))
      assert events.() == []

      # Without ladder state (no event, fresh process), the first wait surfaces it.
      fired = DecisionEscalation.backstop(%{}, opts.(at(20)))
      assert [{:wake, %{"escalation" => "rewake"}}] = events.()

      fired = DecisionEscalation.backstop(fired, opts.(at(29)))
      assert events.() == []

      # Between ladder steps (the 45-minute wake, the next one at 105), a wait
      # surfaces the Decision again once 15 minutes have passed.
      fired = DecisionEscalation.run(fired, opts.(at(45)))
      assert [{:alert, _topic, _opts}, {:wake, _record}] = events.()
      fired = DecisionEscalation.backstop(fired, opts.(at(59)))
      assert events.() == []

      _fired = DecisionEscalation.backstop(fired, opts.(at(61)))
      assert [{:wake, %{"escalation" => "backstop", "topic" => "ticket.3141.agent.attention.operator-decision"}}] = events.()
    end

    test "never surfaces a Decision younger than 15 minutes or one that does not block" do
      young = decision("young", "3141", minutes_ago(0))
      {opts, events} = recorder(young)
      _fired = DecisionEscalation.backstop(%{}, opts.(at(14)))
      assert events.() == []

      nonblocking = decision("nonblocking", "3141", minutes_ago(0), blocking: false)
      {opts, events} = recorder(nonblocking)
      _fired = DecisionEscalation.backstop(%{}, opts.(at(60)))
      assert events.() == []
    end
  end

  describe "status_line/3" do
    test "names the count, the oldest age, its ticket and gate count" do
      old = decision("old", "3141", minutes_ago(372))
      new = decision("new", "4000", minutes_ago(5))

      assert DecisionEscalation.status_line([new, old], @now, fn "3141" -> 38 end) ==
               "DECISIONS open 2 oldest 6h12m (#3141, gates 38) ATTENTION (answer with `aiur commands`)"
    end

    test "is not attention under 15 minutes and ignores answered or non-blocking Decisions" do
      young = decision("young", "4000", minutes_ago(14))
      answered = %{decision("answered", "3141", minutes_ago(300)) | decision_status: :decided}
      nonblocking = decision("nb", "3142", minutes_ago(300), blocking: false)

      assert DecisionEscalation.status_line([young, answered, nonblocking], @now, fn _ -> 0 end) ==
               "DECISIONS open 1 oldest 14m (#4000, gates 0)"

      assert DecisionEscalation.status_line([answered], @now) == "DECISIONS open 0"
    end
  end

  test "wake records carry the decision identity and sanitize agent text" do
    record = DecisionEscalation.wake_record("3141", "dec_1", "Ship it?", %{option_id: "scoped"}, gates: 38, event_id: 7)

    assert %{
             "topic" => "ticket.3141.agent.attention.operator-decision",
             "topic_class" => "ticket.agent.attention.operator-decision",
             "ticket" => "3141",
             "event_id" => 7,
             "needs_attention" => true,
             "decision_id" => "dec_1",
             "question" => "Ship it?",
             "recommendation" => "scoped",
             "gates" => 38,
             "untrusted_fields" => ["question", "recommendation"]
           } = record
  end

  defp recorder(decision, opts \\ []) do
    test_pid = self()
    ref = make_ref()

    build = fn now ->
      [
        now: now,
        decisions_fun: fn -> {:ok, [decision]} end,
        gates_fun: fn _ticket -> Keyword.get(opts, :gates, 0) end,
        condition_states_fun: fn topics -> Map.new(topics, &{&1, Map.get(Keyword.get(opts, :states, %{}), &1, :unknown)}) end,
        wake_fun: fn record -> send(test_pid, {ref, {:wake, record}}) end,
        alert_fun: fn topic, alert_opts -> send(test_pid, {ref, {:alert, topic, alert_opts}}) end
      ]
    end

    {build, fn -> drain(ref, []) end}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, event} -> drain(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp at(minutes), do: DateTime.add(@now, minutes * 60, :second)
  defp minutes_ago(minutes), do: DateTime.add(@now, -minutes * 60, :second)

  defp decision(source_id, ticket, created_at, overrides \\ []) do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{
          "question" => "May this renderer defer composed mobile pixels?",
          "blocking" => Keyword.get(overrides, :blocking, true),
          "authority" => "human_required",
          "context" => %{"authority_basis" => "security"},
          "source_id" => source_id
        },
        ticket: %{identifier: ticket, title: "Renderer", url: nil},
        source: @source,
        now: created_at
      )

    decision
  end
end
