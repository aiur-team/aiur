defmodule Aiur.Orchestrator.HoldDeclineTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.Orchestrator.{Dispatcher, HoldDecline, State}

  @hold {:github, :local_hold, %{hold: %{reason: :shared_budget, resource: "core", reset_at: ~U[2026-10-10 13:06:04Z]}}}

  test "a hold-caused decline raises attention only on the third in a row (#4067)" do
    candidate = %Issue{id: "hold-decline-#{System.unique_integer([:positive])}", identifier: "repo#hold", title: "hold", state: "todo"}
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)
    attention = "ticket.#{candidate.id}.agent.attention.dispatch-declined"

    decline = fn state ->
      Dispatcher.dispatch_issue(state, candidate, nil, nil,
        issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
        blocked_by_hydrator: fn _issue -> {:error, @hold} end
      )
    end

    twice = %State{effective_concurrent_agents: 4} |> decline.() |> decline.()
    assert twice.dispatch_declines[candidate.id] == :github_budget_hold
    refute_receive {:alert, %{name: ^attention}}, 300

    thrice = decline.(twice)
    assert thrice.dispatch_declines[candidate.id] == :dependency_hydration_failed
    assert_receive {:alert, %{name: ^attention, needs_attention: true, reason: reason}}, 2_000
    assert reason =~ "dependency_hydration_failed"
    refute_receive {:alert, %{name: ^attention}}, 300
    refute Map.has_key?(thrice.running, candidate.id)
  end

  test "a blocker read that gets through ends the run of holds" do
    candidate = %Issue{id: "hold-decline-cleared-#{System.unique_integer([:positive])}", identifier: "repo#cleared", title: "cleared", state: "todo"}
    blocked = %{candidate | blocked_by: [%{id: "b", identifier: "repo#b", state: "todo"}]}

    decline = fn state, hydrated ->
      Dispatcher.dispatch_issue(state, candidate, nil, nil,
        issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
        blocked_by_hydrator: fn _issue -> hydrated end
      )
    end

    state = %State{effective_concurrent_agents: 4} |> decline.({:error, @hold}) |> decline.({:error, @hold}) |> decline.({:ok, blocked})
    assert state.dispatch_declines[candidate.id] == :dependency

    # Without the reset this would be the third hold and escalate.
    assert decline.(state, {:error, @hold}).dispatch_declines[candidate.id] == :github_budget_hold
  end

  test "a refresh held every poll escalates although the blocker read gets through" do
    candidate = %Issue{id: "hold-decline-refresh-#{System.unique_integer([:positive])}", identifier: "repo#refresh", title: "refresh", state: "todo"}
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)
    attention = "ticket.#{candidate.id}.agent.attention.dispatch-declined"

    decline = fn state ->
      Dispatcher.dispatch_issue(state, candidate, nil, nil, issue_fetcher: fn _ids -> {:error, @hold} end, blocked_by_hydrator: fn issue -> {:ok, issue} end)
    end

    twice = %State{effective_concurrent_agents: 4} |> decline.() |> decline.()
    assert twice.dispatch_declines[candidate.id] == :github_budget_hold
    refute_receive {:alert, %{name: ^attention}}, 300

    assert decline.(twice).dispatch_declines[candidate.id] == :tracker_revalidation_failed
    assert_receive {:alert, %{name: ^attention, needs_attention: true}}, 2_000
  end

  test "a different failure ends the run of holds" do
    candidate = %Issue{id: "hold-decline-mixed-#{System.unique_integer([:positive])}", identifier: "repo#mixed", title: "mixed", state: "todo"}

    assert HoldDecline.classify(candidate, {:error, @hold}, :fallback) == :github_budget_hold
    assert HoldDecline.classify(candidate, {:error, @hold}, :fallback) == :github_budget_hold
    assert HoldDecline.classify(candidate, {:error, {:github, :http, %{status: 404}}}, :fallback) == :fallback
    assert HoldDecline.classify(candidate, {:error, @hold}, :fallback) == :github_budget_hold
  end

  # Regression guard: already true before #4067; it keeps the hold exemption narrow.
  test "a failure that is not a local hold still raises attention on the first decline" do
    candidate = %Issue{id: "hold-decline-other-#{System.unique_integer([:positive])}", identifier: "repo#other", title: "other", state: "todo"}
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)
    attention = "ticket.#{candidate.id}.agent.attention.dispatch-declined"

    declined =
      Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, candidate, nil, nil,
        issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
        blocked_by_hydrator: fn _issue -> {:error, {:github, :http, %{status: 404}}} end
      )

    assert declined.dispatch_declines[candidate.id] == :dependency_hydration_failed
    assert_receive {:alert, %{name: ^attention, needs_attention: true}}, 2_000
  end
end
