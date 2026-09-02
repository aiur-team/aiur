defmodule Aiur.BuildOrder.ReconciliationTest do
  @moduledoc """
  The rare GraphQL reconciliation that re-converges the event-sourced Build
  Order store after a dropped delivery (#2313).

  The projection tests stub `reconciliation_fun` to prove the projection
  *triggers* the reconciliation on boot and on degradation. These tests drive
  the real `Aiur.BuildOrder.GitHubGraph.Reconciliation.run/1`: it re-reads
  `build_order_catalog`, clears the repo's `:sub_issue` edges, and deposits the
  fetched membership back into `Aiur.GitHub.ResourceStore` — the exact
  re-convergence the dropped-delivery path owes, asserted rather than assumed.
  """

  use Aiur.TestSupport

  alias Aiur.BuildOrder.GitHubGraph.Reconciliation
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Workflow

  @repo "owner/repo"
  @repository {"owner", "repo"}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur",
      tracker_bot_account: "its-applekid"
    )

    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      if is_nil(Process.whereis(ResourceStore)) do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
    end)

    :ok
  end

  test "reconciliation deposits roots, members and edges into the store" do
    root = root_node(100, [member_node(101), member_node(102)])

    assert {:ok, :reconciled, %{roots: 1}} =
             Reconciliation.run(repository: @repository, request_fun: catalog_fun([root]))

    # The root becomes a REST-shaped `:issue` body plus its label set.
    assert {:ok, %{data: issue}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 100))
    assert issue["number"] == 100
    assert issue["title"] == "Build Order 100"
    assert issue["state"] == "OPEN"
    assert issue["labels"] == []

    assert {:ok, %{data: labels}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 100))
    assert Enum.map(labels, & &1["name"]) == ["build-order"]

    # Members become issues too, and each root→member pair a present edge.
    assert {:ok, %{data: member}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 101))
    assert member["state"] == "CLOSED"
    assert member["state_reason"] == "completed"

    assert {:ok, %{data: edge}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:101"))
    assert edge["present"] == true
    assert edge["parent_issue_number"] == 100
    assert edge["sub_issue_number"] == 101
  end

  # The dropped-delivery path this reconciliation exists for: an edge whose
  # `*_removed` delivery was dropped lingers as `present: true` in the store.
  # The query is set truth, so the reconciliation clears the repo's edges and
  # re-deposits the fetched membership, which is what deletes the stale edge.
  test "reconciliation clears a stale membership edge whose removal was dropped" do
    ResourceStore.put_resource(
      ResourceStore.key_for_repo(:sub_issue, @repo, "100:103"),
      %{
        "present" => true,
        "parent_issue_number" => 100,
        "sub_issue_number" => 103,
        "parent_issue_repo" => @repo,
        "sub_issue_repo" => @repo
      },
      source: :webhook,
      version: "2026-06-24T12:00:00Z"
    )

    root = root_node(100, [member_node(101)])
    assert {:ok, :reconciled, _} = Reconciliation.run(repository: @repository, request_fun: catalog_fun([root]))

    # The stale edge is gone; the fetched edge remains.
    assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:103"))
    assert {:ok, %{data: %{"present" => true}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:101"))
  end

  test "a failed reconciliation returns an error and leaves the store alone" do
    request_fun = fn _request ->
      {:ok, %{status: 200, body: %{"errors" => [%{"message" => "redacted"}]}, headers: []}}
    end

    assert {:error, _reason} = Reconciliation.run(repository: @repository, request_fun: request_fun)
  end

  # -- fixtures -------------------------------------------------------------

  defp catalog_fun(nodes) do
    fn _request ->
      {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "99"}], body: catalog_body(nodes)}}
    end
  end

  defp catalog_body(nodes) do
    %{"data" => %{"repository" => %{"issues" => connection(nodes, length(nodes))}}}
  end

  defp connection(nodes, total) do
    %{
      "nodes" => nodes,
      "totalCount" => total,
      "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
    }
  end

  # A catalog root exactly as the query returns it: identity scalars, the
  # root `labels` connection and the `subIssues` member connection.
  defp root_node(number, members) do
    %{
      "id" => "DI_root_#{number}",
      "databaseId" => number,
      "number" => number,
      "title" => "Build Order #{number}",
      "url" => "https://github.com/owner/repo/issues/#{number}",
      "state" => "OPEN",
      "stateReason" => nil,
      "createdAt" => "2026-06-24T10:00:00Z",
      "updatedAt" => "2026-06-24T11:00:00Z",
      "repository" => repo_node(),
      "parent" => nil,
      "labels" => connection([%{"name" => "build-order"}], 1),
      "subIssues" => connection(members, length(members))
    }
  end

  defp member_node(number) do
    %{
      "id" => "DI_member_#{number}",
      "databaseId" => number,
      "number" => number,
      "title" => "Member #{number}",
      "url" => "https://github.com/owner/repo/issues/#{number}",
      "state" => "CLOSED",
      "stateReason" => "completed",
      "createdAt" => "2026-06-24T10:00:00Z",
      "updatedAt" => "2026-06-24T11:00:00Z",
      "repository" => repo_node(),
      "parent" => %{
        "id" => "DI_root_100",
        "databaseId" => 100,
        "number" => 100,
        "url" => "https://github.com/owner/repo/issues/100",
        "repository" => repo_node()
      }
    }
  end

  defp repo_node, do: %{"name" => "repo", "owner" => %{"login" => "owner"}}
end
