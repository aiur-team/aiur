defmodule Aiur.GitHub.DispatchAuthorization.TimelineLimitsTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  # --- a timeline page bigger than the response cap (#1454 recurrence) ---
  #
  # Measured on aiur-team/khala#257 (2026-09-26): `per_page=100` page 1 was
  # 575,125 bytes, past the 524,288-byte cap, so the transport cleared the body
  # and the fetch reported `:timeline_truncated`. Because that is a hard limit hit
  # on EVERY fetch rather than a cache, the ticket could never be dispatched
  # again: not by relabelling from a trusted user, not after a daemon restart.
  # The operator had to close it and re-file. The same issue at `per_page=50` was
  # 262,218 bytes and at `per_page=20` was 93,723 bytes.
  #
  # `paged_timeline_request_fun/1` stands in for the real transport: it slices by
  # the `per_page` in the URL, emits `Link: rel="next"` while pages remain, and
  # answers any page whose encoded size exceeds the request's
  # `max_response_bytes` with the 200-plus-cleared-body that
  # `Transport.bounded_response_collector/1` produces.
  test "a timeline too big for per_page=100 still resolves its label applier" do
    events = fat_timeline(120, 6_000)

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: paged_timeline_request_fun(events)
      )

    # The whole page-1 body at per_page=100 is past the cap, which is what denied
    # khala#257 forever.
    assert encoded_size(Enum.take(events, 100)) > 524_288
    assert encoded_size(Enum.take(events, 50)) < 524_288

    assert authorized.dispatch_authorized?
    assert authorized.dispatch_authorization == :authorized
  end

  # Fixes tickets that are ALREADY oversized, without changing the healthy path:
  # truncation at the default page size is a statement about the page, so the
  # timeline is refetched in smaller pages before the failure is believed.
  test "truncation at the default page size is retried at a smaller page size" do
    events = fat_timeline(60, 14_000)

    {:ok, sizes} = Agent.start_link(fn -> [] end)

    request_fun = paged_timeline_request_fun(events)

    authorized =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: fn %{url: url} = request ->
          Agent.update(sizes, &[query_value(url, "per_page") | &1])
          request_fun.(request)
        end
      )

    # Truncated at the 50-event default, recovered at 20.
    assert encoded_size(Enum.take(events, 50)) > 524_288
    assert encoded_size(Enum.take(events, 20)) < 524_288

    assert authorized.dispatch_authorized?
    requested = sizes |> Agent.get(&Enum.reverse(&1)) |> Enum.uniq()
    assert requested == ["50", "20"]
  end

  # The security invariant is untouched: when the evidence cannot be obtained at
  # ANY page size it is still fail-closed. What changes is that the refusal says
  # so — a transport limit is a different alert from an ambiguous provenance
  # verdict, and `cause=transport_limit` is in the log line (#2797).
  test "a timeline unreadable at every page size defers as a transport limit, not a denial" do
    :ok = AgentPubSub.subscribe_agent("42")

    events = fat_timeline(40, 40_000)
    assert encoded_size(Enum.take(events, 20)) > 524_288

    deferred =
      DispatchAuthorization.authorize(issue(), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: paged_timeline_request_fun(events)
      )

    refute deferred.dispatch_authorized?
    assert deferred.dispatch_authorization == :deferred

    assert_receive {:alert,
                    %{
                      name: "github.dispatch_authorization.timeline_unreadable",
                      needs_attention: true
                    }},
                   500

    refute_receive {:alert, %{name: "github.dispatch_authorization.ambiguous"}}, 200
  end

  # Regression guard for the fetch behavior restored from main: a page-size
  # retry must never reuse a validator issued for a different URL.
  test "per-page ETags stay scoped to the page size after a truncation retry" do
    parent = self()
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    request_fun = fn %{url: url} = request ->
      per_page = url |> query_value("per_page") |> String.to_integer()
      send(parent, {:page_request, per_page, request[:etag]})

      cond do
        per_page == 50 ->
          {:ok, %{status: 200, body: "", private: %{aiur_response_too_large: true}}}

        request[:etag] == ~s("page-20-v1") ->
          {:ok, %{status: 304, headers: []}}

        true ->
          {:ok, %{status: 200, body: events, headers: [{"etag", ~s("page-20-v1")}]}}
      end
    end

    assert authorize_with_events(issue(), events, ["trusted"], request_fun: request_fun).dispatch_authorized?
    assert_receive {:page_request, 50, nil}, 1000
    assert_receive {:page_request, 20, nil}, 1000

    next_issue = issue(updated_at: ~U[2026-01-02 00:00:00Z])
    assert authorize_with_events(next_issue, events, ["trusted"], request_fun: request_fun).dispatch_authorized?
    assert_receive {:page_request, 50, nil}, 1000
    assert_receive {:page_request, 20, ~s("page-20-v1")}, 1000
  end

  test "prunes embedded source payloads before holding a timeline" do
    source_body = String.duplicate("x", 300_000)
    event = labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
    event = Map.put(event, "source", %{"issue" => %{"body" => source_body}})

    assert authorize_with_events(issue(), [event], ["trusted"]).dispatch_authorized?

    assert [{"42", %{events: [held_event]}}] = :ets.lookup(:aiur_github_dispatch_authorization_timelines, "42")
    refute Map.has_key?(held_event, "source")
    assert held_event["event"] == "labeled"
    assert held_event["actor"]["login"] == "trusted"
  end
end
