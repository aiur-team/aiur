defmodule Aiur.GitHub.DispatchAuthorization.PageValidatorsTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.GitHub.DispatchAuthorization

  setup do
    cache_snapshot = DispatchAuthorization.cache_snapshot_for_test()
    DispatchAuthorization.clear_cache()

    on_exit(fn -> DispatchAuthorization.restore_cache_for_test(cache_snapshot) end)

    :ok
  end

  # A page-1 `304` only vouches for page 1, and new `labeled` events land on the
  # last page of an oldest-first timeline. Each page therefore carries its own
  # validator: a busy ticket's unchanged timeline costs no billable page, and a
  # change on the last page is still read. Refetching every page of every
  # multi-page timeline unconditionally made dispatch authorization the largest
  # REST spender on its-everdred/open-games (~900 issues, 58 multi-page timelines).
  test "a multi-page timeline revalidates page by page and still sees a new last-page label" do
    page_1 = "https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=50"
    page_2 = "https://api.github.com/repositories/7/issues/42/timeline?per_page=50&page=2"
    link = [{"link", ~s(<#{page_2}>; rel="next")}]
    full_page = for id <- 1..50, do: labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
    trusted = [labeled_event(60, "agent:todo", "trusted", "2026-01-02T00:00:00Z")]
    outsider = trusted ++ [labeled_event(61, "agent:todo", "outsider", "2026-01-03T00:00:00Z")]
    last_page = start_supervised!({Agent, fn -> {~s("p2-v1"), trusted} end}, id: :last_page)
    calls = start_supervised!({Agent, fn -> [] end}, id: :calls)

    request_fun = fn %{url: url} = request ->
      etag = Map.get(request, :etag)
      {current_etag, current_events} = Agent.get(last_page, & &1)

      response =
        case {url, etag} do
          {^page_1, nil} -> {:ok, %{status: 200, headers: [{"etag", ~s("p1")} | link], body: full_page}}
          {^page_1, ~s("p1")} -> {:ok, %{status: 304, headers: [{"etag", ~s("p1")} | link]}}
          {^page_2, ^current_etag} -> {:ok, %{status: 304, headers: [{"etag", current_etag}]}}
          {^page_2, _stale} -> {:ok, %{status: 200, headers: [{"etag", current_etag}], body: current_events}}
        end

      {:ok, %{status: status}} = response
      Agent.update(calls, &[{url, etag, status} | &1])
      response
    end

    authorize = fn updated_at ->
      DispatchAuthorization.authorize(issue(updated_at: updated_at), "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      ).dispatch_authorized?
    end

    drain = fn -> Agent.get_and_update(calls, &{Enum.reverse(&1), []}) end

    assert authorize.(~U[2026-01-01 00:00:00Z])
    assert [{^page_1, nil, 200}, {^page_2, nil, 200}] = drain.()

    # The issue moved but its timeline did not: both pages answer `304`, so the
    # refetch spends no billable request.
    assert authorize.(~U[2026-01-02 00:00:00Z])
    assert [{^page_1, ~s("p1"), 304}, {^page_2, ~s("p2-v1"), 304}] = drain.()

    # An outsider relabels: page 1 still `304`s, the last page does not, and the
    # newer label revokes.
    Agent.update(last_page, fn _held -> {~s("p2-v2"), outsider} end)
    refute authorize.(~U[2026-01-03 00:00:00Z])
    assert [{^page_1, ~s("p1"), 304}, {^page_2, ~s("p2-v1"), 200}] = drain.()
  end

  # A full last page keeps its body, and so its validator, when a new event
  # opens the page after it. Its `304` would hide that page, so a full last page
  # is always read unconditionally.
  test "a full last page is reread unconditionally and the page it grew is followed" do
    page_1 = "https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=50"
    page_2 = "https://api.github.com/repositories/7/issues/42/timeline?per_page=50&page=2"
    full_page = for id <- 1..50, do: labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
    grown = start_supervised!({Agent, fn -> false end})

    request_fun = fn %{url: url} = request ->
      refute Map.has_key?(request, :etag), "a full last page must not be revalidated"

      case {url, Agent.get(grown, & &1)} do
        {^page_1, false} -> {:ok, %{status: 200, headers: [{"etag", ~s("p1")}], body: full_page}}
        {^page_1, true} -> {:ok, %{status: 200, headers: [{"etag", ~s("p1")}, {"link", ~s(<#{page_2}>; rel="next")}], body: full_page}}
        {^page_2, true} -> {:ok, %{status: 200, headers: [], body: [labeled_event(51, "agent:todo", "outsider", "2026-01-02T00:00:00Z")]}}
      end
    end

    assert DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-01 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?

    Agent.update(grown, fn _ -> true end)

    refute DispatchAuthorization.authorize(issue(updated_at: ~U[2026-01-02 00:00:00Z]), "owner", "repo", "agent",
             allowed_users: ["trusted"],
             token: "test-token",
             request_fun: request_fun
           ).dispatch_authorized?
  end
end
