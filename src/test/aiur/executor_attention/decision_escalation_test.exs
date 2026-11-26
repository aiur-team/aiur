defmodule Aiur.ExecutorAttention.DecisionEscalationTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAttentionSignals, DecisionValidation}
  alias Aiur.DecisionStore.{RetainedIndex, RetainedSnapshot}
  alias Aiur.ExecutorAttention.DecisionEscalation
  alias AiurWeb.OperatorControlCenter.{DecisionCommands, DecisionPresenter}

  import AiurWeb.OperatorControlCenterComponentsFixtures, only: [render_inbox: 2]

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
      old = %{decision("old", "3141", minutes_ago(372)) | decision_id: "older-open"}
      new = %{decision("new", "4000", minutes_ago(5)) | decision_id: "newer-open"}

      assert DecisionEscalation.status_line([new, old], @now, fn "3141" -> 38 end) ==
               "DECISIONS open 2 ids=[newer-open,older-open] oldest 6h12m (#3141, gates 38) ATTENTION (answer with `aiur commands`)"
    end

    test "counts expired blocking unanswered Decisions that remain actionable" do
      expired = %{decision("expired", "3141", minutes_ago(372)) | decision_status: :expired}

      answered_expired = %{
        decision("answered-expired", "4000", minutes_ago(100))
        | decision_status: :expired,
          answer: %{}
      }

      open = decision("open", "4001", minutes_ago(5))
      expired_nonblocking = %{decision("quiet-expired", "4002", minutes_ago(100), blocking: false) | decision_status: :expired}

      expired = %{expired | decision_id: "expired-open"}
      open = %{open | decision_id: "open-one"}

      assert DecisionEscalation.status_line([answered_expired, open, expired, expired_nonblocking], @now, fn _ -> 0 end) ==
               "DECISIONS open 2 (1 expired) ids=[expired-open,open-one] oldest 6h12m (#3141, gates 0) ATTENTION (answer with `aiur commands`)"
    end

    test "counts deferred and non-blocking open Decisions like `aiur commands --filter open` (#5109)" do
      deferred = %{decision("deferred", "3323", minutes_ago(30)) | decision_status: :deferred, decision_id: "deferred-one"}
      question = %{decision("question", "4002", minutes_ago(20), blocking: false) | decision_id: "question-two"}
      moot = %{decision("moot", "4005", minutes_ago(2000)) | decision_status: :moot}

      assert DecisionEscalation.status_line([question, moot, deferred], @now, fn _ -> 0 end) ==
               "DECISIONS open 2 ids=[deferred-one,question-two] oldest 30m (#3323, gates 0) ATTENTION (answer with `aiur commands`)"
    end

    test "counts the same open set as `aiur commands --filter open` and the dashboard (#5109)" do
      expired = fn d -> %{d | decision_status: :expired} end

      open = %{decision("open", "5001", minutes_ago(60)) | decision_id: "open-one"}
      deferred = %{decision("deferred", "5002", minutes_ago(50)) | decision_status: :deferred, decision_id: "deferred-two"}
      expired_blocking = %{expired.(decision("expired-blocking", "5003", minutes_ago(40))) | decision_id: "expired-three"}

      decisions = [
        open,
        deferred,
        expired_blocking,
        %{expired.(decision("expired-answered", "5004", minutes_ago(30))) | answer: %{}},
        expired.(decision("expired-quiet", "5005", minutes_ago(30), blocking: false)),
        %{decision("moot", "5006", minutes_ago(30)) | decision_status: :moot},
        %{decision("resolved", "5007", minutes_ago(30)) | decision_status: :resolved},
        %{decision("dismissed", "5008", minutes_ago(30)) | decision_status: :dismissed},
        %{decision("decided", "5009", minutes_ago(30)) | decision_status: :decided},
        %{decision("superseded", "5010", minutes_ago(20)) | revision_sequence: 1, decision_id: "superseded-four"},
        delivery_alert("5011")
      ]

      current = Map.new(decisions, &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)
      query = %{limit: 100, cursor: nil, lifecycle: :open, search: nil, ticket: nil}
      {:ok, %{decisions: listed}} = RetainedSnapshot.query(current, index, :writable, query)
      "DECISIONS open " <> rest = DecisionEscalation.status_line(decisions, @now, fn _ -> 0 end)
      {status_count, _} = Integer.parse(rest)

      rows = DecisionPresenter.rows(decisions)
      cards = fn filter -> length(Regex.scan(~r/<article\s+id="decision-/, render_inbox(rows, filter))) end

      assert status_count == 4
      assert length(listed) == status_count
      assert RetainedIndex.canonical_counts(index).open == status_count
      assert cards.(:open) == status_count
      assert cards.(:blocking) == status_count

      assert status_line_ids =
               decisions
               |> DecisionEscalation.status_line(@now, fn _ -> 0 end)
               |> then(&Regex.run(~r/ids=\[([^]]*)\]/, &1, capture: :all_but_first))

      assert status_line_ids == ["deferred-two,expired-three,open-one,superseded-four"]
    end

    test "the dashboard does not take a delivery-alert Decision as the selected open Command (#5109)" do
      [row] = DecisionPresenter.rows([delivery_alert("5012")])
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, selected_decision: row}}

      assert DecisionCommands.change(socket, row.decision_id, %{}) == socket
    end

    test "is not attention under 15 minutes and ignores answered or expired non-blocking Decisions" do
      young = %{decision("young", "4000", minutes_ago(14)) | decision_id: "young-open"}
      answered = %{decision("answered", "3141", minutes_ago(300)) | decision_status: :decided}
      nonblocking = %{decision("nb", "3142", minutes_ago(300), blocking: false) | decision_status: :expired}

      assert DecisionEscalation.status_line([young, answered, nonblocking], @now, fn _ -> 0 end) ==
               "DECISIONS open 1 ids=[young-open] oldest 14m (#4000, gates 0)"

      assert DecisionEscalation.status_line([answered], @now) == "DECISIONS open 0 ids=[]"
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

  # An open, blocking delivery-failure alert: `RetainedIndex.open?/1` never counts it as a Command.
  defp delivery_alert(ticket) do
    %{decision("delivery-alert", ticket, minutes_ago(20)) | legacy_attention: %{slug: "decision-delivery-act-1", topic: "t"}}
  end
end
