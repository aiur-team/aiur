defmodule Aiur.GitHub.PullRequestBodyEdit do
  # REST has no body-edit timestamp (its `updated_at` moves on any activity), so this reads GraphQL `lastEditedAt` (#4944).
  @moduledoc false

  alias Aiur.GitHub.Transport

  @query """
  query AiurPullRequestBodyEdit($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) { lastEditedAt }
    }
  }
  """

  @doc "When the PR body was last edited; `nil` when it never was."
  @spec last_edited_at(integer(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def last_edited_at(number, opts \\ []) when is_integer(number) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    with {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, body} <- Transport.github_graphql(request_fun, token, @query, %{"owner" => owner, "name" => name, "number" => number}, caller: "rework_body_edit") do
      case body do
        %{"data" => %{"repository" => %{"pullRequest" => %{"lastEditedAt" => at}}}} when is_binary(at) or is_nil(at) -> {:ok, at}
        _other -> {:error, :pull_request_body_edit_unreadable}
      end
    end
  end
end
