defmodule Aiur.GitHub.DispatchAuthorizationTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "allows an allowlisted issue creator without a timeline request" do
    issue = issue(creator_login: "trusted")

    authorized =
      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        request_fun: fn _request -> flunk("trusted creator must not query the timeline") end
      )

    assert authorized.dispatch_authorized?
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

  defp authorize_with_events(issue, events, allowed_users) do
    DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
      allowed_users: allowed_users,
      token: "test-token",
      request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
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
