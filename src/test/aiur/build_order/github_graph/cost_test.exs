defmodule Aiur.BuildOrder.GitHubGraph.CostTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph
  alias Aiur.BuildOrder.ProviderResult

  # A response's headers report the balance left in the GraphQL points budget
  # but never what the call just spent, which is why a 26x per-poll cost
  # increase stayed invisible until it exhausted the budget (#1766). Pin that
  # the query asks for its own cost and that the figure reaches the caller.
  test "records the GraphQL point cost the response reports for the query" do
    request_fun = fn %{body: %{"query" => query}} ->
      assert query =~ "rateLimit { limit cost remaining resetAt }"

      {:ok,
       %{
         status: 200,
         headers: [{"x-ratelimit-remaining", "99"}],
         body: %{
           "data" => %{
             "rateLimit" => %{"limit" => 5000, "cost" => 26, "remaining" => 4974, "resetAt" => "2026-08-10T19:00:25Z"},
             "repository" => %{"issues" => connection([root(1)], 1, [])}
           }
         }
       }}
    end

    assert {:ok, %ProviderResult{rate_limit: rate_limit}} = GitHubGraph.fetch_catalog(base_opts(request_fun))

    assert rate_limit.cost == 26
    assert rate_limit.limit == 5000
    assert rate_limit.reset_at == "2026-08-10T19:00:25Z"

    # The body's own balance supersedes the header's, so the reported cost and
    # the remaining budget describe the same call.
    assert rate_limit.remaining == 4974
  end

  # A catalog poll spends points per page, so the figure that multiplies by the
  # poll frequency into a per-hour number is what the whole read cost — not
  # whatever the last page happened to charge.
  test "accumulates the reported point cost across a paged read" do
    pages = [
      costed_catalog_response([root(1)], 2, 4, has_next?: true, cursor: "page-2"),
      costed_catalog_response([root(2)], 2, 5, [])
    ]

    assert {:ok, %ProviderResult{pages: 2, rate_limit: rate_limit}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses(pages)))

    assert rate_limit.cost == 9
  end

  test "leaves the header rate-limit observation intact when a response reports no cost" do
    assert {:ok, %ProviderResult{rate_limit: rate_limit}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root(1)], 1)))

    assert rate_limit.remaining == 99
    refute Map.has_key?(rate_limit, :cost)
  end
end
