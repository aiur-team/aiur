defmodule Aiur.GitHub.DispatchAuthorization.FailClosedTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "fails closed when the timeline contains no matching trigger-label event" do
    denied = authorize_with_events(issue(), [labeled_event(10, "agent:rework", "trusted", "2026-01-01T00:00:00Z")], ["trusted"])

    refute denied.dispatch_authorized?
    assert denied.dispatch_authorization == :deferred
  end

  test "missing or malformed current-label evidence still revokes active and rework tickets" do
    for state <- ["in-progress", "rework"] do
      current_label = "agent:#{state}"

      malformed_event = %{
        "event" => "labeled",
        "label" => %{"name" => current_label},
        "actor" => %{"login" => "outsider"}
      }

      for events <- [[], [malformed_event]] do
        denied = authorize_with_events(issue(state: state), events, ["trusted"])

        refute denied.dispatch_authorized?
        assert denied.dispatch_authorization == :denied
      end
    end
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

  # A truncated timeline body is an inability to fetch/parse, not a provenance
  # verdict: it *defers* (fail-closed, never revoked) instead of emitting an
  # ambiguous attention alert, and the underlying cause is the truncation, not
  # a self-contradictory `{:github, :http, %{status: 200}}` (#1454, #2409).
  test "a truncated 200 timeline body defers with :timeline_truncated, not an HTTP status error" do
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
    assert denied.dispatch_authorization == :deferred

    refute_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.ambiguous",
                      needs_attention: true
                    }},
                   500
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
    assert denied.dispatch_authorization == :deferred
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
end
