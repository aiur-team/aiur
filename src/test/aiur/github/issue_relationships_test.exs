defmodule Aiur.GitHub.IssueRelationshipsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.IssueRelationships
  alias Aiur.TrackerIdentity

  test "requests the reported GraphQL cost" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:query, request.body["query"]})

      {:ok,
       %{
         status: 200,
         headers: [],
         body: %{
           "data" => %{
             "repository" => %{
               "issue" => %{
                 "id" => "I_42",
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

    identity = %TrackerIdentity{provider_id: "I_42", identifier: "42"}

    assert {:ok, %{nodes: [], truncated?: false}} =
             IssueRelationships.fetch_linked_pull_requests(identity, {"owner", "repo"}, relationship_request_fun: request_fun)

    assert_receive {:query, query}
    assert query =~ "query AiurLinkedPullRequests"
    assert query =~ "rateLimit { cost }"
  end
end
