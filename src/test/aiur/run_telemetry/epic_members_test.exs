defmodule Aiur.RunTelemetry.EpicMembersTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Experiments.Auto.FeatureState
  alias Aiur.RunTelemetry.{EpicMembers, FeatureEpics}

  test "membership deliberately accepts a capped page while labelled discovery requires completeness" do
    rows = for n <- 1..100, do: %{"number" => n, "state" => "open", "state_reason" => nil}
    request = fn _req -> {:ok, %{status: 200, body: rows, headers: [{"link", "<https://api.github.com/next>; rel=\"next\""}]}} end
    assert {:ok, observation} = EpicMembers.read("owner/repo", 42, request_fun: request)
    assert Enum.map(observation["members"], & &1["number"]) == Enum.to_list(1..100)
    assert observation["member_limit"] == true
    assert {:error, :pagination_unexpected} = FeatureEpics.discover("owner/repo", "experiment:feature", request_fun: request)
  end

  test "foreign members are excluded before merge lookup and incomplete linked evidence fails closed" do
    foreign = %{
      "number" => 1,
      "state" => "closed",
      "state_reason" => "completed",
      "repository_url" => "https://api.github.com/repos/other/repo",
      "html_url" => "https://github.com/other/repo/issues/1"
    }

    request = fn req ->
      assert req.method == :get
      {:ok, %{status: 200, body: [foreign], headers: []}}
    end

    assert {:ok, observation} = EpicMembers.read("owner/repo", 42, request_fun: request)
    assert observation["members"] == []
    assert observation["merges"] == []
    assert observation["cross_repo_excluded"] == [foreign["html_url"]]

    request = fn req ->
      body =
        if req.method == :get,
          do: [Map.delete(foreign, "repository_url")],
          else: %{"data" => %{"repository" => %{"issue" => %{"closedByPullRequestsReferences" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}}}}}

      {:ok, %{status: 200, body: body, headers: []}}
    end

    assert {:error, :incomplete_member_merge} = EpicMembers.read("owner/repo", 42, request_fun: request, recent_merges: [])
  end

  test "completed without code has no merge and is identified as excluded" do
    member = %{"number" => 2, "state" => "closed", "state_reason" => "completed"}

    request = fn req ->
      body = if req.method == :get, do: [member], else: %{"data" => %{"repository" => %{"issue" => %{"closedByPullRequestsReferences" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
      {:ok, %{status: 200, body: body, headers: []}}
    end

    assert {:ok, observation} = EpicMembers.read("owner/repo", 42, request_fun: request, recent_merges: [])
    assert observation["merges"] == []
    {state, [:arm]} = FeatureState.transition(nil, Map.put(observation, "labelled", true), %Config{}, ~U[2026-10-10 00:00:00Z])
    assert state["excluded_completed"] == [2]
  end
end
