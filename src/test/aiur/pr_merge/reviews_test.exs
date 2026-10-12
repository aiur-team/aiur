defmodule Aiur.PrMerge.ReviewsTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.{Checks, Reviews}
  @head String.duplicate("a", 40)

  defp review(id, user, state, commit \\ @head) do
    %{"id" => id, "user" => %{"id" => user}, "state" => state, "commit_id" => commit, "submitted_at" => "2026-10-01T00:00:00Z"}
  end

  defp observe(reviews) do
    api = fn "get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=1", nil -> {:ok, reviews} end
    Reviews.read(api, "owner/repo", 1, @head)
  end

  test "approval must belong to the observed head" do
    assert observe([review(1, 10, "APPROVED", String.duplicate("b", 40))]) == {:ok, %{approved: false, changes_requested: false}}
    assert observe([review(1, 10, "APPROVED")]) == {:ok, %{approved: true, changes_requested: false}}
  end

  test "a comment does not clear requested changes from an earlier head" do
    assert observe([review(1, 10, "CHANGES_REQUESTED", "old-head"), review(2, 10, "COMMENTED"), review(3, 20, "APPROVED")]) ==
             {:ok, %{approved: true, changes_requested: true}}
  end

  test "latest decisive review replaces an earlier decision for that reviewer" do
    assert observe([review(3, 10, "APPROVED"), review(1, 10, "CHANGES_REQUESTED"), review(2, 10, "COMMENTED")]) ==
             {:ok, %{approved: true, changes_requested: false}}

    assert observe([review(1, 10, "APPROVED"), review(2, 10, "CHANGES_REQUESTED")]) == {:ok, %{approved: false, changes_requested: true}}
    assert observe([review(1, 10, "CHANGES_REQUESTED"), review(2, 10, "DISMISSED")]) == {:ok, %{approved: false, changes_requested: false}}
  end

  test "decision order follows submission time, using review ID only to break ties" do
    earlier = Map.put(review(2, 10, "CHANGES_REQUESTED"), "submitted_at", "2026-10-01T00:00:00Z")
    later = Map.put(review(1, 10, "APPROVED"), "submitted_at", "2026-10-01T02:01:00+02:00")
    assert observe([later, earlier]) == {:ok, %{approved: true, changes_requested: false}}
  end

  test "review pagination includes decisive reviews on later pages" do
    first = for id <- 1..100, do: review(id, id, "COMMENTED")

    api = fn
      "get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=1", nil -> {:ok, first}
      "get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=2", nil -> {:ok, [review(101, 1, "CHANGES_REQUESTED")]}
    end

    assert Reviews.read(api, "owner/repo", 1, @head) == {:ok, %{approved: false, changes_requested: true}}
  end

  test "missing reviewer identity and review transport failures refuse observation" do
    assert observe([Map.delete(review(1, 10, "APPROVED"), "user")]) == {:error, "invalid GitHub review observation"}
    assert Reviews.read(fn _, _, _ -> {:error, "GitHub request failed"} end, "owner/repo", 1, @head) == {:error, "GitHub request failed"}
  end

  test "checks observation uses head-pinned reviews instead of aggregate review decision" do
    api = fn
      "post", "graphql", _ ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "reviewDecision" => "APPROVED",
                 "commits" => %{"nodes" => [%{"commit" => %{"oid" => @head, "statusCheckRollup" => nil}}]},
                 "closingIssuesReferences" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
               }
             }
           }
         }}

      "get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=1", nil ->
        {:ok, [review(1, 10, "APPROVED", "old-head")]}
    end

    assert Checks.read(api, "owner/repo", 1, @head) == {:ok, %{approved: false, changes_requested: false, checks: [], tickets: []}}
  end
end
