defmodule Aiur.TestTicketScope do
  @moduledoc """
  Limits issue discovery for the development `aiurdev --test` harness.

  The launcher validates the pinned ticket file before exporting the internal
  scope. An absent scope leaves ordinary runs unchanged; a malformed one must
  fail closed before startup cleanup can touch a workspace.
  """

  @env "AIUR_DEV_TEST_TICKET_IDS"

  alias Aiur.GitHub.Config

  @spec validate!() :: :ok
  def validate! do
    _ids = allowed_ids!()
    :ok
  end

  @spec filter_result(term()) :: term()
  def filter_result({:ok, issues}) when is_list(issues), do: {:ok, filter_issues(issues)}
  def filter_result({:ok, issues, cache}) when is_list(issues), do: {:ok, filter_issues(issues), cache}
  def filter_result(other), do: other

  @spec filter_issues(list()) :: list()
  def filter_issues(issues) when is_list(issues) do
    case allowed_ids!() do
      :all -> issues
      allowed -> Enum.filter(issues, &MapSet.member?(allowed, identifier(&1)))
    end
  end

  @spec allowed_identifier?(String.t() | nil) :: boolean()
  def allowed_identifier?(identifier) when is_binary(identifier) do
    case allowed_ids!() do
      :all -> true
      allowed -> MapSet.member?(allowed, identifier)
    end
  end

  def allowed_identifier?(_identifier), do: allowed_ids!() == :all

  @spec with_write_scope(map(), (-> term())) :: term()
  def with_write_scope(request, fun), do: with(:ok <- allow_write?(request), do: fun.())

  @doc "Whether an outgoing GitHub state mutation is inside the active test scope."
  @spec allow_write?(map()) :: :ok | {:error, {:outside_test_ticket_scope, String.t()}}
  def allow_write?(%{method: method, url: url} = request)
      when method in [:post, :patch, :put, :delete] and is_binary(url) do
    case System.get_env(@env) do
      nil ->
        :ok

      ids when is_binary(ids) and ids != "" ->
        allow_scoped_write(request, resource_number(url))

      _invalid_scope ->
        {:error, {:outside_test_ticket_scope, "unknown"}}
    end
  end

  def allow_write?(%{method: method}) when method in [:post, :patch, :put, :delete],
    do: {:error, {:outside_test_ticket_scope, "unknown"}}

  def allow_write?(_request), do: :ok

  defp allow_scoped_write(%{method: method, url: url} = request, resource) do
    cond do
      method == :post and installation_token_request?(url) ->
        :ok

      method == :post and scoped_graphql_read?(request) ->
        :ok

      dependency_mutation?(request) ->
        deny_write(resource_identifier(resource))

      match?({:ok, :issue, _number}, resource) and allowed_identifier?(resource_identifier(resource)) ->
        :ok

      true ->
        deny_write(resource_identifier(resource))
    end
  end

  defp deny_write(identifier), do: {:error, {:outside_test_ticket_scope, identifier}}

  defp installation_token_request?(url) do
    Regex.match?(~r{\Ahttps://api\.github\.com/app/installations/[1-9][0-9]*/access_tokens\z}, url)
  end

  # GitHub sends GraphQL reads and mutations as POSTs. Reads do not change
  # tracker state; mutations are denied because their node IDs do not
  # reliably identify a pinned issue or PR.
  defp scoped_graphql_read?(%{url: url, body: %{"query" => document}}) when is_binary(document) do
    with %URI{} = uri <- URI.parse(url),
         true <- uri.scheme == "https" and uri.host == "api.github.com" and is_nil(uri.userinfo),
         true <- uri.port in [nil, 443] and uri.path == "/graphql",
         true <- declared_read_operation?(document) do
      true
    else
      _ -> false
    end
  end

  defp scoped_graphql_read?(_request), do: false

  defp dependency_mutation?(%{method: method, url: url}) when method in [:post, :delete] and is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> Regex.match?(~r{/issues/[1-9][0-9]*/dependencies/blocked_by(?:/.*)?\z}, path)
      _ -> false
    end
  end

  defp dependency_mutation?(_request), do: false

  defp declared_read_operation?(document) do
    leading_trivia_removed = Regex.replace(~r/\A(?:\s|\#[^\n]*(?:\n|\z))*/, document, "")

    (Regex.match?(~r/\Aquery\b/, leading_trivia_removed) or String.starts_with?(leading_trivia_removed, "{")) and
      not Regex.match?(~r/\bmutation\b/, document)
  end

  defp resource_identifier({:ok, :issue, number}), do: number
  defp resource_identifier(_resource), do: "unknown"

  defp resource_number(url) do
    with %URI{} = uri <- URI.parse(url),
         true <- uri.scheme == "https" and uri.host == "api.github.com" and is_nil(uri.userinfo),
         true <- uri.port in [nil, 443],
         path when is_binary(path) <- uri.path,
         [owner, repository, number] <-
           Regex.run(~r{\A/repos/([^/]+)/([^/]+)/issues/([1-9][0-9]*)(?:/.*)?\z}, path, capture: :all_but_first),
         {:ok, {expected_owner, expected_repository}} <- configured_repository(),
         true <- same_repository?(owner, repository, expected_owner, expected_repository) do
      {:ok, :issue, number}
    else
      _ -> :invalid
    end
  end

  defp configured_repository do
    case Config.repo() do
      repo when is_binary(repo) ->
        case String.split(repo, "/") do
          [owner, repository] when owner != "" and repository != "" -> {:ok, {owner, repository}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp same_repository?(owner, repository, expected_owner, expected_repository) do
    String.downcase(owner) == String.downcase(expected_owner) and
      String.downcase(repository) == String.downcase(expected_repository)
  end

  defp identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp identifier(%{identifier: identifier}) when is_integer(identifier), do: Integer.to_string(identifier)
  defp identifier(_issue), do: nil

  defp allowed_ids! do
    case System.get_env(@env) do
      nil ->
        :all

      ids when is_binary(ids) ->
        if Regex.match?(~r/\A[1-9][0-9]*(?:,[1-9][0-9]*)*\z/, ids) do
          ids |> String.split(",") |> MapSet.new()
        else
          raise ArgumentError, "invalid #{@env}; expected comma-separated positive ticket IDs"
        end
    end
  end
end
