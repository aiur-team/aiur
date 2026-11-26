defmodule Aiur.GitHub.DispatchAuthorizationTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.GitHub.Issues

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "queued + todo is not contradictory" do
    issue =
      Issues.normalize_issue(
        %{"number" => 42, "title" => "Queued", "state" => "open", "labels" => [%{"name" => "agent:todo"}, %{"name" => "agent:queued"}]},
        "owner",
        "repo",
        "agent"
      )

    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
    authorized = authorize_with_events(issue, events, ["trusted"])
    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end

  # Regression: an allowlisted creator used to short-circuit authorization with
  # no label check at all. Agents file issues with the same credential, so that
  # let an agent create a ticket, label it, and dispatch it with no human in the
  # loop — and it also dispatched trusted-creator issues whose trigger label was
  # applied by an outsider. Creation is not authorization; the verified label
  # applier is.
  test "an allowlisted creator still requires a trusted trigger-label applier" do
    events = [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")]

    denied = authorize_with_events(issue(creator_login: "trusted"), events, ["trusted"])

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  # Allowed-contributor intake (#2957) grants a wake, never dispatch authority.
  # These are guards: dispatch already ignores the creator, and they pin that
  # an allow-listed author can neither self-dispatch nor be dispatched by an
  # outsider's relabel — while a trusted applier dispatches their issue
  # exactly like an operator-filed one.
  describe "allowed-contributor issues (#2957)" do
    test "an allowed contributor labelling their own issue does not dispatch it" do
      events = [labeled_event(10, "agent:todo", "contributor", "2026-01-01T00:00:00Z")]
      denied = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      refute denied.dispatch_authorized?
      assert denied.dispatch_authorization == :denied
    end

    test "a non-allowed user labelling an allowed contributor's issue does not dispatch it" do
      events = [labeled_event(10, "agent:todo", "mallory", "2026-01-01T00:00:00Z")]
      denied = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      refute denied.dispatch_authorized?
    end

    test "a trusted applier dispatches an allowed contributor's issue like an operator-filed one" do
      events = [labeled_event(10, "agent:todo", "operator", "2026-01-01T00:00:00Z")]
      authorized = authorize_with_events(issue(creator_login: "contributor"), events, ["operator"])

      assert authorized.dispatch_authorized?
      assert authorized.dispatch_authorization == :authorized
    end
  end

  # The bot login has to be in `allowed_users` for the fleet to work at all, so
  # this is exactly what the creator short-circuit left unchecked: a ticket
  # filed with the bot credential dispatched on creator alone, whoever applied —
  # or did not apply — the trigger label.
  test "an agent-filed ticket does not dispatch on an outsider's label" do
    events = [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")]

    denied = authorize_with_events(issue(creator_login: "aiur-bot"), events, ["aiur-bot"])

    refute denied.dispatch_authorized?
  end

  # The trigger label is the issue's CURRENT state label, and Aiur moves that
  # label itself on every transition. Without the carry-forward, the first
  # `todo → in-progress` transition makes the verified applier the bot, the
  # issue reads unauthorized, and `Orchestrator.Reconciler` kills the running
  # agent. The old creator short-circuit hid this for operator-filed tickets.
  test "an Aiur state transition does not revoke a human-triaged ticket" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-bot", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end

  test "an Aiur state transition carries nothing forward when no trusted actor ever triaged" do
    events = [
      labeled_event(10, "agent:todo", "aiur-bot", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-bot", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :denied
  end

  # Carry-forward is deliberately limited to Aiur's own identity. "Latest
  # applier wins" is what stops a hostile relabel riding a stale approval, so
  # any non-Aiur actor still replaces the decision.
  test "an outsider relabel still revokes even after a trusted triage" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "outsider", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    refute denied.dispatch_authorized?
  end

  # SPLIT IDENTITY — the state label above is written with the *daemon's*
  # credential, so under GitHub App auth the timeline actor is the App bot, not
  # the account agents publish under. Every carry-forward test above uses one
  # login for both roles, which is the blind spot that let the original
  # conflation hide: with a single identity, matching the wrong one still
  # matches. Here the two logins differ, so only a union answers correctly.
  # Getting this wrong denies authorization on each ticket's first transition
  # and `Orchestrator.Reconciler` kills the running agent.
  test "SPLIT IDENTITY: a daemon App-bot state transition does not revoke a human-triaged ticket" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-daemon[bot]", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    assert authorized.dispatch_authorized?
  end

  # The other half of the union: an agent moving a label with its own
  # credential appears as the bot account, and that must carry forward too.
  test "SPLIT IDENTITY: an agent-applied state label also carries the triage decision forward" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "its-applekid", "2026-01-02T00:00:00Z")
    ]

    authorized =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    assert authorized.dispatch_authorized?
  end

  # Widening to a union must not widen who counts as Aiur. A third party is
  # still a third party, and "latest applier wins" still revokes.
  test "SPLIT IDENTITY: an outsider relabel still revokes under a split identity" do
    events = [
      labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "its-everdred", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"],
        bot_account: "its-applekid",
        daemon_account: "aiur-daemon[bot]"
      )

    refute denied.dispatch_authorized?
  end

  test "an agent-filed ticket with no trigger-label event at all is denied" do
    denied = authorize_with_events(issue(creator_login: "aiur-bot"), [], ["aiur-bot"])

    refute denied.dispatch_authorized?
  end

  test "an allowlisted creator is dispatched once the trigger label is verifiably theirs" do
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    authorized = authorize_with_events(issue(creator_login: "trusted"), events, ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "contradictory workflow state labels deny even a trusted creator and raise attention" do
    :ok = AgentPubSub.subscribe_agent("42")

    issue = issue(creator_login: "trusted", state: nil, state_labels: ["error", "todo"])

    denied =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        request_fun: fn _request -> flunk("a contradiction must fail before timeline authorization") end
      )

    refute denied.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      reason: reason,
                      needs_attention: true
                    }},
                   2_000

    assert reason =~ "contradictory_state_labels"
    assert reason =~ "error"
    assert reason =~ "todo"
  end

  test "allows an outsider when the most recent trigger-label applier is trusted" do
    events = [
      labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:todo", "trusted", "2026-01-02T00:00:00Z")
    ]

    authorized = authorize_with_events(issue(), events, ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "denies an unlisted creator and unlisted trigger-label applier" do
    denied =
      authorize_with_events(
        issue(),
        [labeled_event(10, "agent:todo", "outsider", "2026-01-01T00:00:00Z")],
        ["trusted"]
      )

    refute denied.dispatch_authorized?
  end

  test "uses event id to break same-timestamp timeline ties" do
    events = [
      labeled_event(11, "agent:todo", "trusted", "2026-01-01T00:00:00Z"),
      labeled_event(12, "agent:todo", "outsider", "2026-01-01T00:00:00Z")
    ]

    refute authorize_with_events(issue(), events, ["trusted"]).dispatch_authorized?
  end

  test "follows timeline pages before deciding label provenance" do
    first_page = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
    second_page = [labeled_event(11, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]

    request_fun = fn %{url: url} ->
      if String.contains?(url, "page=2") do
        {:ok, %{status: 200, headers: [], body: second_page}}
      else
        next = ~s(<https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=100&page=2>; rel="next")
        {:ok, %{status: 200, headers: [{"link", next}], body: first_page}}
      end
    end

    refute DispatchAuthorization.authorize(issue(), "owner", "repo", "agent", allowed_users: ["trusted"], token: "test-token", request_fun: request_fun).dispatch_authorized?
  end
end
