defmodule Aiur.Orchestrator.HoldDeclineTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.Orchestrator.{Dispatcher, State}

  @hold {:github, :local_hold, %{hold: %{reason: :shared_budget, resource: "core", reset_at: ~U[2026-10-10 13:06:04Z]}}}

  test "a hold-caused decline raises attention only on the third within the window (#4067)" do
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
