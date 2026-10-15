defmodule Aiur.GitHub.DispatchAuthorization.AlertsTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "persistent deferral alerts and resolves independently for each ticket" do
    :ok = AgentPubSub.subscribe_agent("42")
    issue_b = issue(id: "43", identifier: "43")
    :ok = AgentPubSub.subscribe_agent("43")
    unavailable = fn _request -> {:error, :timeout} end

    for _ <- 1..4 do
      refute authorize_with_events(issue(), [], ["trusted"], request_fun: unavailable).dispatch_authorized?
      refute authorize_with_events(issue_b, [], ["trusted"], request_fun: unavailable).dispatch_authorized?
      refute_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred"}}, 20
      refute_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred"}}, 20
    end

    authorize_with_events(issue(), [], ["trusted"], request_fun: unavailable)
    authorize_with_events(issue_b, [], ["trusted"], request_fun: unavailable)

    assert_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred", needs_attention: true, source_ticket_id: "42"}},
                   1000

    assert_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred", needs_attention: true, source_ticket_id: "43"}},
                   1000

    assert active_deferral_topics() ==
             MapSet.new([
               "ticket.42.agent.attention.dispatch_authorization.deferred",
               "ticket.43.agent.attention.dispatch_authorization.deferred"
             ])

    # A fetched timeline with missing label evidence is an ambiguous denial for
    # this active ticket; that definitive result closes only its own alert.
    active = issue(state: "in-progress")
    denied = authorize_with_events(active, [], ["trusted"])
    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied

    assert_receive {:alert, %{name: "ticket.42.agent.attention.dispatch_authorization.deferred.resolved", needs_attention: false}},
                   1000

    refute_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred.resolved"}}, 50
    assert active_deferral_topics() == MapSet.new(["ticket.43.agent.attention.dispatch_authorization.deferred"])

    # Ticket 43 is independently cleared by verified label evidence.
    authorized =
      authorize_with_events(issue_b, [labeled_event(11, "agent:todo", "trusted", "2026-01-02T00:00:00Z")], ["trusted"])

    assert authorized.dispatch_authorized?

    assert_receive {:alert, %{name: "ticket.43.agent.attention.dispatch_authorization.deferred.resolved", needs_attention: false}},
                   1000

    assert active_deferral_topics() == MapSet.new()
  end
end
