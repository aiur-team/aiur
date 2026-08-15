defmodule Aiur.GitHub.DispatchAuthorizationTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
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
  end

  test "an Aiur state transition carries nothing forward when no trusted actor ever triaged" do
    events = [
      labeled_event(10, "agent:todo", "aiur-bot", "2026-01-01T00:00:00Z"),
      labeled_event(11, "agent:in-progress", "aiur-bot", "2026-01-02T00:00:00Z")
    ]

    denied =
      authorize_with_events(issue(state: "in-progress"), events, ["trusted"], bot_account: "aiur-bot")

    refute denied.dispatch_authorized?
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

  test "caches an unchanged issue's latest label event" do
    counter = start_supervised!({Agent, fn -> 0 end})
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    request_fun = fn %{url: url} ->
      assert url =~ "/issues/42/timeline"
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 200, body: events}}
    end

    issue = issue()

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 1
  end

  test "does not reuse a cached decision after an issue update" do
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn _request ->
      request_number = Agent.get_and_update(counter, fn number -> {number, number + 1} end)

      events =
        if request_number == 0 do
          [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]
        else
          [labeled_event(11, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]
        end

      {:ok, %{status: 200, body: events}}
    end

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    refute DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 2
  end

  test "retries an ambiguous timeline fetch on the next poll" do
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn _request ->
      case Agent.get_and_update(counter, fn number -> {number, number + 1} end) do
        0 -> {:ok, %{status: 429, body: %{"message" => "rate limited"}}}
        1 -> {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
      end
    end

    :ok = AgentPubSub.subscribe_agent("42")
    issue = issue()

    refute DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert_receive {:alert, %{name: "github.dispatch_authorization.ambiguous", needs_attention: true}}, 500

    assert DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    assert Agent.get(counter, & &1) == 2
  end

  test "fails closed when the timeline contains no matching trigger-label event" do
    denied = authorize_with_events(issue(), [labeled_event(10, "agent:rework", "trusted", "2026-01-01T00:00:00Z")], ["trusted"])

    refute denied.dispatch_authorized?
  end

  test "fails closed when the timeline request errors" do
    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:error, :timeout} end
      )

    refute denied.dispatch_authorized?
  end

  test "fails closed when the timeline response is malformed" do
    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> :malformed_response end
      )

    refute denied.dispatch_authorized?
  end

  test "reports a truncated 200 timeline body as :timeline_truncated, not an HTTP status error" do
    :ok = AgentPubSub.subscribe_agent("42")

    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request ->
          # What Transport.bounded_response_collector/1 produces when a page
          # exceeds @max_timeline_response_bytes: a 200 whose body is cleared.
          {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}
        end
      )

    refute denied.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      reason: reason,
                      needs_attention: true
                    }},
                   500

    assert reason =~ ":timeline_truncated"
    refute reason =~ "{:github, :http, %{status: 200}}"
  end

  test "authorizes from a full per_page=100 timeline page without truncation" do
    events =
      for id <- 1..100 do
        labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
      end

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
      )

    assert authorized.dispatch_authorized?
  end

  test "requests a timeline page cap that holds per_page=100 events" do
    # Measured real timelines run ~2.5-3.5 KiB per event; a full 100-event page
    # needs ~350 KiB, so the response cap must comfortably exceed 64 KiB.
    request_fun = fn request ->
      assert request.max_response_bytes >= 100 * 3_500
      {:ok, %{status: 200, body: [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]}}
    end

    assert DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?
  end

  test "fails closed when timeline pagination exceeds the provenance budget" do
    request_fun = fn %{url: url} ->
      next = "<#{url}&page=next>; rel=\"next\""
      {:ok, %{status: 200, headers: [{"link", next}], body: []}}
    end

    denied =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    refute denied.dispatch_authorized?
  end

  test "accepts numeric timeline event ids encoded as strings" do
    authorized = authorize_with_events(issue(), [labeled_event("10", "agent:todo", "trusted", "2026-01-01T00:00:00Z")], ["trusted"])

    assert authorized.dispatch_authorized?
  end

  test "fails closed when the latest matching label event has no actor" do
    :ok = AgentPubSub.subscribe_agent("42")

    denied =
      authorize_with_events(
        issue(),
        [
          %{
            "id" => 10,
            "event" => "labeled",
            "label" => %{"name" => "agent:todo"},
            "created_at" => "2026-01-01T00:00:00Z"
          }
        ],
        ["trusted"]
      )

    refute denied.dispatch_authorized?

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      needs_attention: true,
                      severity: "warning"
                    }},
                   500
  end

  test "fails closed when a matching timeline event is malformed" do
    denied =
      authorize_with_events(
        issue(),
        [
          %{
            "id" => 10,
            "event" => "labeled",
            "label" => %{"name" => "agent:todo"},
            "actor" => %{"login" => "trusted"}
          }
        ],
        ["trusted"]
      )

    refute denied.dispatch_authorized?
  end

  test "fails closed before timeline lookup when the issue has no trigger label" do
    denied =
      DispatchAuthorization.authorize(%{issue() | state: nil}, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn _ -> flunk("unlabeled issue must not query the timeline") end
      )

    refute denied.dispatch_authorized?
  end

  defp authorize_with_events(issue, events, allowed_users, extra_opts \\ []) do
    DispatchAuthorization.authorize(
      issue,
      "owner",
      "repo",
      "agent",
      Keyword.merge(
        [
          allowed_users: allowed_users,
          token: "test-token",
          request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
        ],
        extra_opts
      )
    )
  end

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "42",
          identifier: "42",
          title: "Issue",
          state: "todo",
          creator_login: "outsider",
          dispatch_revision: "\"issue-42-v1\"",
          updated_at: ~U[2026-01-01 00:00:00Z]
        ],
        attrs
      )
    )
  end

  defp labeled_event(id, label, actor, created_at) do
    %{
      "id" => id,
      "event" => "labeled",
      "label" => %{"name" => label},
      "actor" => %{"login" => actor},
      "created_at" => created_at
    }
  end
end
