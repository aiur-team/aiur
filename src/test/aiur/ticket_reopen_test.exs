defmodule Aiur.TicketReopenTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildQueue.Model.Edge
  alias Aiur.TicketReopen

  # A tracker double over the test process's dictionary: every call runs in the caller.
  defmodule FakeTracker do
    def issue_closure(id, _max_age), do: {:ok, %{open?: issue(id).open?, state_reason: nil}}
    def blocked_by(id), do: {:ok, issue(id).blocked_by}
    def reopen_issue(id), do: update(id, &%{&1 | open?: true})
    def update_issue_state(id, state, []), do: update(id, &%{&1 | labels: Enum.reject(&1.labels, fn l -> l =~ ~r/^agent:(todo|rework|done)$/ end) ++ ["agent:#{state}"]})
    def add_label(id, label), do: update(id, &%{&1 | labels: Enum.uniq(&1.labels ++ [label])})
    def create_comment(id, body), do: update(id, &%{&1 | comments: &1.comments ++ [body]})

    def declare(dependent, prerequisite) do
      :ok = update(dependent, &%{&1 | blocked_by: &1.blocked_by ++ [prerequisite]})
      {:ok, %{}}
    end

    def issue(id), do: Map.fetch!(Process.get(:fake_issues), id)

    defp update(id, fun) do
      Process.put(:fake_issues, Map.update!(Process.get(:fake_issues), id, fun))
      :ok
    end
  end

  defp issue(open?, labels, blocked_by \\ []), do: %{open?: open?, labels: labels, blocked_by: blocked_by, comments: []}

  # Ticket 12 closed done in feature "auth" at queue position 1; its open dependent 13 lost its
  # native edge to an `aiur_unblock`, and the Build Order graph still records 12 -> 13. The queue
  # also holds 12 -> 14 as list order, which is the planner's edge and must never reach GitHub.
  defp queue_model do
    %{
      status: :running,
      sources: %{"tracker_observation" => %{freshness: :current}},
      queues: [
        %{
          queue_id: "q-auth",
          feature: "auth",
          epic: nil,
          items: [%{number: 11, position: 0}, %{number: 12, position: 1}, %{number: 13, position: 2}],
          edges: [
            %Edge{prerequisite: "12", dependent: "13", source: :build_order},
            %Edge{prerequisite: "12", dependent: "14", source: :list},
            %Edge{prerequisite: "11", dependent: "13", source: :native},
            %Edge{prerequisite: "11", dependent: "12", source: :feature}
          ]
        }
      ]
    }
  end

  defp run(opts) do
    defaults = [
      tracker: FakeTracker,
      queue_fun: &queue_model/0,
      feature_fun: fn 12 -> {:ok, %{feature: "auth"}} end,
      declare_fun: fn dependent, prerequisite -> send(self(), {:declared, dependent, prerequisite}) && FakeTracker.declare(dependent, prerequisite) end,
      alert_fun: fn topic, alert -> send(self(), {:alert, topic, alert}) end,
      label_prefix: "agent",
      by: "cli:test"
    ]

    TicketReopen.reopen(Keyword.merge(defaults, opts))
  end

  setup do
    Process.put(:fake_issues, %{
      "11" => issue(false, ["agent:done"]),
      "12" => issue(false, ["agent:done", "feature:auth"], ["11"]),
      "13" => issue(true, ["agent:todo", "agent:queued"], []),
      "14" => issue(true, ["agent:todo", "agent:queued"], [])
    })

    :ok
  end

  test "reopen 12 opens and labels it, keeps it queued in its feature, and blocks its open dependent again" do
    assert {:ok, result} = run(id: 12, reason: "premise changed", state: "todo")

    ticket = FakeTracker.issue("12")
    assert ticket.open?
    assert "agent:todo" in ticket.labels
    refute "agent:done" in ticket.labels
    # The queue marker keeps the planner from dequeuing the reopened item and its edges.
    assert "agent:queued" in ticket.labels
    assert "feature:auth" in ticket.labels
    assert [comment] = ticket.comments
    assert comment =~ "Reason: premise changed"

    assert FakeTracker.issue("13").blocked_by == ["12"]
    # Planner edges stay in the queue: no GitHub edge for the list order 12 -> 14.
    assert FakeTracker.issue("14").blocked_by == []
    assert_received {:declared, "13", "12"}
    refute_received {:declared, "14", _}
    assert result.feature == "auth"
    assert result.queue == %{queue: "q-auth", feature: "auth", epic: nil, position: 1}

    assert Enum.sort_by(result.links, & &1.prerequisite) == [
             %{prerequisite: "11", dependent: "12", outcome: :held_by_queue},
             %{prerequisite: "12", dependent: "13", outcome: :restored},
             %{prerequisite: "12", dependent: "14", outcome: :held_by_queue}
           ]

    assert_received {:alert, "ticket.12.agent.attention.reopened", alert}
    assert alert[:needs_attention] == true
    assert alert[:reason] =~ "premise changed"
    assert alert[:reason] =~ "#12 -> #13 restored"
  end

  test "an edge GitHub still holds is left alone" do
    Process.put(:fake_issues, Map.update!(Process.get(:fake_issues), "13", &%{&1 | blocked_by: ["12"]}))
    assert {:ok, result} = run(id: 12, reason: "x", state: "rework", declare_fun: fn _, _ -> flunk("declared a present edge") end)
    assert %{prerequisite: "12", dependent: "13", outcome: :present} in result.links
    assert "agent:rework" in FakeTracker.issue("12").labels
  end

  test "a ticket never in a Build Order is refused before any write" do
    before = Process.get(:fake_issues)
    empty = Map.put(queue_model(), :queues, [])
    assert {:error, :not_in_build_order} = run(id: 12, reason: "x", queue_fun: fn -> empty end, feature_fun: fn 12 -> :none end)
    assert Process.get(:fake_issues) == before
    refute_received {:alert, _, _}

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert TicketReopen.run(id: 12, reason: "x", tracker: FakeTracker, queue_fun: fn -> empty end, feature_fun: fn 12 -> :none end, error_fun: &IO.puts/1) == 1
           end) =~ "ticket #12 was never in a Build Order; reopen it with gh issue reopen"
  end

  test "an unavailable or stale queue read model is refused before any write" do
    before = Process.get(:fake_issues)
    stale = put_in(queue_model(), [:sources, "tracker_observation", :freshness], :stale)

    for model <- [Aiur.BuildQueue.ReadModel.unavailable(:read_timeout), stale] do
      assert {:error, :queue_unavailable} = run(id: 12, reason: "x", queue_fun: fn -> model end)
    end

    assert Process.get(:fake_issues) == before
    refute_received {:alert, _, _}

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert TicketReopen.run(id: 12, reason: "x", tracker: FakeTracker, queue_fun: fn -> stale end, error_fun: &IO.puts/1) == 1
           end) =~ "build queue unavailable; retry"
  end

  test "reopen of an open ticket is refused before any write" do
    before = Process.get(:fake_issues)
    assert {:error, :already_open} = run(id: 13, reason: "x")
    assert Process.get(:fake_issues) == before
    refute_received {:alert, _, _}

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert TicketReopen.run(id: 13, reason: "x", tracker: FakeTracker, error_fun: &IO.puts/1) == 1
           end) =~ "ticket #13 is already open; reopen only applies to a closed ticket"
  end

  test "a missing or blank reason is refused before any write" do
    before = Process.get(:fake_issues)
    assert {:error, :invalid_reason} = run(id: 12)
    assert {:error, :invalid_reason} = run(id: 12, reason: "  ")
    assert {:error, :invalid_state} = run(id: 12, reason: "x", state: "done")
    assert Process.get(:fake_issues) == before
  end
end
