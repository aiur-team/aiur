defmodule Aiur.RunTelemetry.GitHubFactsTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.GitHubFacts
  @fixture Path.expand("../../support/fixtures/github_facts/terminal.json", __DIR__)
  defp response, do: @fixture |> File.read!() |> Jason.decode!()
  defp normalize(body), do: GitHubFacts.normalize(body, allowed_fun: &(&1 == "owner"))
  defp update_pr(body, fun), do: update_in(body, ["data", "repository", "pullRequests", "nodes"], fn [pr] -> [fun.(pr)] end)

  test "ready event, all review states, size and epic survive without bodies or identities" do
    assert {:ok, facts} = normalize(response())
    assert facts.pr_ready_at == "2026-10-02T10:00:00Z"
    assert facts.pr_created_at == "2026-10-01T10:00:00Z"
    assert facts.first_review_at == "2026-10-03T10:00:00Z"
    assert facts.first_review_state == "COMMENTED"
    assert facts.first_approval_at == "2026-10-03T12:00:00Z"
    assert facts.review_count == 3
    assert facts.changes_requested_count == 1
    assert facts.approval_count == 1
    assert facts.commented_count == 1
    assert facts.reviewers_distinct == 3
    assert facts.reviewer_classes == ["bot", "other", "trusted"]
    assert facts.epic == 3774
    assert {facts.additions, facts.deletions, facts.changed_files, facts.commit_count} == {53, 7, 4, 2}
    assert facts.merge_commit_sha == "abc123"
    encoded = Jason.encode!(facts)
    for private <- ["body", "login", "owner", "private review"], do: refute(encoded =~ private)
  end

  test "opened ready uses creation; draft that never became ready has no ready time" do
    ready = response() |> update_pr(&put_in(&1, ["timelineItems", "nodes"], []))
    assert {:ok, facts} = normalize(ready)
    assert facts.pr_ready_at == facts.pr_created_at
    assert {:ok, facts} = normalize(update_pr(ready, &Map.put(&1, "isDraft", true)))
    assert facts.pr_ready_at == nil
  end

  test "opened ready then converted to draft retains initial readiness" do
    body =
      update_pr(response(), fn pr ->
        update_in(pr, ["timelineItems", "nodes"], fn events ->
          [%{"__typename" => "ConvertToDraftEvent", "createdAt" => "2026-10-01T11:00:00Z"} | events]
        end)
      end)

    assert {:ok, facts} = normalize(body)
    assert facts.pr_ready_at == facts.pr_created_at
  end

  test "fallback requires closing issue membership, and a ticket without a PR retains epic" do
    original = response()
    [pr] = get_in(original, ["data", "repository", "pullRequests", "nodes"])
    empty = put_in(original, ["data", "repository", "pullRequests", "nodes"], [])
    assert {:ok, %{pr_number: nil, epic: 3774}} = normalize(empty)
    linked = put_in(empty, ["data", "repository", "issue", "timelineItems", "nodes"], [%{"source" => pr}])
    assert {:ok, %{pr_number: 4010}} = normalize(linked)

    unrelated =
      update_in(linked, ["data", "repository", "issue", "timelineItems", "nodes"], fn [%{"source" => pull}] ->
        [%{"source" => put_in(pull, ["closingIssuesReferences", "nodes"], [%{"number" => 3797, "id" => "other-repository-issue"}])}]
      end)

    assert {:ok, %{pr_number: nil}} = normalize(unrelated)
  end

  test "overflow cannot report complete facts or claim a ticket has no PR" do
    for key <- ["reviews", "timelineItems"] do
      body = update_pr(response(), &put_in(&1, [key, "pageInfo", "hasNextPage"], true))
      assert {:error, :incomplete_github_facts} = normalize(body)
    end

    for path <- [["pullRequests"], ["issue", "timelineItems"]] do
      body = put_in(response(), ["data", "repository"] ++ path ++ ["pageInfo", "hasNextPage"], true)
      assert {:error, :incomplete_github_facts} = normalize(body)
    end
  end

  test "partial GraphQL errors never masquerade as complete facts" do
    assert {:error, :graphql_partial} = normalize(Map.put(response(), "errors", [%{"message" => "permission denied"}]))
  end

  test "pending reviews are excluded and repeated reviewer identities count once" do
    body =
      update_pr(response(), fn pr ->
        update_in(pr, ["reviews", "nodes"], fn reviews ->
          pending = %{"state" => "PENDING", "submittedAt" => nil, "author" => %{"login" => "unsubmitted"}}
          [pending, Map.put(List.first(reviews), "author", %{"login" => "OWNER"}) | Enum.reverse(reviews)]
        end)
      end)

    assert {:ok, facts} = normalize(body)
    assert facts.review_count == 4
    assert facts.reviewers_distinct == 3
    assert facts.first_review_at == "2026-10-03T10:00:00Z"
  end

  test "bare backfill tickets use the retained canonical branch" do
    parent = self()

    request = fn req ->
      send(parent, {:branch_query, req.body["variables"]["branch"]})
      {:ok, %{status: 200, body: response()}}
    end

    assert {:ok, %{pr_number: 4010}} =
             GitHubFacts.fetch("3797", repo: "aiur-team/aiur", request_fun: request, branch_lookup: fn 3797 -> %{ref: "refs/heads/aiur/3797-exp-x1-4-capture", sha: "abc"} end)

    assert_receive {:branch_query, "aiur/3797-exp-x1-4-capture"}, 500
  end

  test "one governed query uses actual branch, omits bodies and preserves transport holds" do
    test_pid = self()
    body = response()

    request = fn req ->
      send(test_pid, {:request, req})
      {:ok, %{status: 200, body: body}}
    end

    ticket = %{identifier: "3797", branch_name: "aiur/3797-existing-title"}
    assert {:ok, %{pr_number: 4010}} = GitHubFacts.fetch(ticket, repo: "aiur-team/aiur", request_fun: request, allowed_fun: fn _ -> false end)
    assert_receive {:request, req}, 500
    assert req.caller == "analytics_facts"
    assert req.body["variables"]["branch"] == ticket.branch_name
    assert req.body["variables"]["number"] == 3797
    refute req.body["query"] =~ "body"
    refute_receive {:request, _}, 10
    hold = {:aiur, :locally_held, %{retry_after_ms: 5_000}}
    assert {:error, ^hold} = GitHubFacts.fetch(3797, repo: "aiur-team/aiur", request_fun: fn _ -> {:error, hold} end)
  end
end
