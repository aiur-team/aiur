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
  # native edge to an `aiur_unblock`, and the queue still records 12 -> 13.
  defp queue_model do
    %{
      queues: [
        %{
          queue_id: "q-auth",
          feature: "auth",
          epic: nil,
          items: [%{number: 11, position: 0}, %{number: 12, position: 1}, %{number: 13, position: 2}],
          edges: [
            %Edge{prerequisite: "12", dependent: "13", source: :feature},
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
      declare_fun: &FakeTracker.declare/2,
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
      "13" => issue(true, ["agent:todo", "agent:queued"], [])
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
    assert result.feature == "auth"
    assert result.queue == %{queue: "q-auth", feature: "auth", epic: nil, position: 1}

    assert Enum.sort_by(result.links, & &1.prerequisite) == [
             %{prerequisite: "11", dependent: "12", outcome: :other_closed},
             %{prerequisite: "12", dependent: "13", outcome: :restored}
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

  test "a ticket outside every queue gets no queue marker" do
    assert {:ok, %{queue: nil, links: []}} = run(id: 12, reason: "x", queue_fun: fn -> %{queues: []} end)
    refute "agent:queued" in FakeTracker.issue("12").labels
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
