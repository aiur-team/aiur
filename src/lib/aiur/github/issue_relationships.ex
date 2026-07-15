defmodule Aiur.GitHub.IssueRelationships do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail.DestinationNormalizer
  alias Aiur.GitHub.Transport
  alias Aiur.TrackerIdentity

  @max_response_bytes 32_768

  @linked_pull_requests_query """
  query AiurLinkedPullRequests($owner: String!, $repository: String!, $number: Int!, $limit: Int!) {
    repository(owner: $owner, name: $repository) {
      issue(number: $number) {
        id
        closedByPullRequestsReferences(first: $limit) {
          nodes {
            number
            url
            state
            isDraft
            updatedAt
          }
          pageInfo {
            hasNextPage
          }
        }
      }
    }
  }
  """

  @spec fetch_linked_pull_requests(TrackerIdentity.t(), TrackerIdentity.repository(), keyword()) ::
          {:ok, %{nodes: [map()], truncated?: boolean()}} | {:error, term()}
  def fetch_linked_pull_requests(identity, repository, opts \\ [])

  def fetch_linked_pull_requests(
        %TrackerIdentity{provider_id: provider_id, identifier: identifier},
        {owner, repository},
        opts
      )
      when is_binary(provider_id) and is_binary(identifier) and is_binary(owner) and
             is_binary(repository) do
    with {number, ""} <- Integer.parse(identifier),
         true <- number > 0,
         {:ok, token} <- relationship_token(opts),
         request_fun <- relationship_request_fun(opts),
         {:ok, response} <-
           Transport.github_graphql(
             request_fun,
             token,
             @linked_pull_requests_query,
             %{
               "owner" => owner,
               "repository" => repository,
               "number" => number,
               "limit" => DestinationNormalizer.max_pull_requests()
             },
             max_response_bytes: @max_response_bytes
           ) do
      normalize_response(response, provider_id)
    else
      false -> {:error, :invalid_github_issue_relationships_response}
      :error -> {:error, :invalid_github_issue_relationships_response}
      {:error, _reason} = error -> error
    end
  end

  def fetch_linked_pull_requests(_identity, _repository, _opts),
    do: {:error, :invalid_github_issue_relationships_response}

  defp relationship_token(opts) do
    if Keyword.has_key?(opts, :relationship_request_fun) do
      opts
      |> Keyword.put(:request_fun, Keyword.fetch!(opts, :relationship_request_fun))
      |> Transport.require_token()
    else
      Transport.require_token(opts)
    end
  end

  defp relationship_request_fun(opts) do
    Keyword.get_lazy(opts, :relationship_request_fun, fn ->
      Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    end)
  end

  defp normalize_response(
         %{
           "data" => %{
             "repository" => %{
               "issue" => %{
                 "id" => provider_id,
                 "closedByPullRequestsReferences" => %{
                   "nodes" => nodes,
                   "pageInfo" => %{"hasNextPage" => truncated?}
                 }
               }
             }
           }
         },
         provider_id
       )
       when is_list(nodes) and is_boolean(truncated?) do
    {:ok,
     %{
       nodes: Enum.map(nodes, &normalize_node/1),
       truncated?: truncated?
     }}
  end

  defp normalize_response(%{"data" => %{"repository" => %{"issue" => %{"id" => _other}}}}, _provider_id),
    do: {:error, :provider_identity_mismatch}

  defp normalize_response(%{"data" => %{"repository" => %{"issue" => nil}}}, _provider_id),
    do: {:error, :github_issue_relationships_not_found}

  defp normalize_response(_response, _provider_id),
    do: {:error, :invalid_github_issue_relationships_response}

  defp normalize_node(%{} = node) do
    %{
      number: Map.get(node, "number"),
      url: Map.get(node, "url"),
      state: Map.get(node, "state"),
      draft?: Map.get(node, "isDraft"),
      updated_at: Map.get(node, "updatedAt")
    }
  end

  defp normalize_node(_node), do: :invalid
end
