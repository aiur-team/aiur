defmodule Aiur.GitHub.IssueRelationshipsTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.TicketDetail.Repository
  alias Aiur.GitHub.IssueRelationships
  alias Aiur.TrackerIdentity

  @identity %TrackerIdentity{provider_id: "I42", identifier: "42"}
  @repository {"owner", "repo"}

  test "linked PR query uses the caller's limit" do
    assert {:ok, %{nodes: [], truncated?: false}} =
             IssueRelationships.fetch_linked_pull_requests(@identity, @repository,
               limit: 7,
               request_fun: request_fun(7)
             )
  end

  test "linked PR fetch without a limit fails loudly" do
    assert_raise KeyError, fn ->
      IssueRelationships.fetch_linked_pull_requests(@identity, @repository, request_fun: request_fun(7))
    end
  end

  test "ticket detail supplies its validation bound even when options contain a different limit" do
    assert {:ok, %{nodes: [], truncated?: false}} =
             Repository.fetch_linked_pull_requests(@identity, @repository,
               limit: 7,
               relationship_request_fun: request_fun(20)
             )
  end

  defp request_fun(limit) do
    fn %{method: :post, body: %{"variables" => variables}} ->
      assert variables["limit"] == limit
      assert variables["number"] == 42

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "issue" => %{
                 "id" => "I42",
                 "closedByPullRequestsReferences" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false}
                 }
               }
             }
           }
         }
       }}
    end
  end
end
