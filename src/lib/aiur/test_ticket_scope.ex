defmodule Aiur.TestTicketScope do
  @moduledoc """
  Limits issue discovery for the development `aiurdev --test` harness.

  The launcher validates the pinned ticket file before exporting the internal
  scope. An absent scope leaves ordinary runs unchanged; a malformed one must
  fail closed before startup cleanup can touch a workspace.

  The inverse also holds: a daemon without the scope never reads or writes the
  pinned sandbox tickets of the repository they belong to, so a live fleet does
  not race a concurrent `--test3` run for them (#4741). The pinned ids are read
  at compile time, so a changed `.aiur-test-tickets.json` takes effect only
  after a rebuild.
  """

  @env "AIUR_DEV_TEST_TICKET_IDS"

  # Read at compile time: the live daemon's cwd is not necessarily a checkout.
  @pinned_file Path.expand("../../../.aiur-test-tickets.json", __DIR__)
  @external_resource @pinned_file
  {pinned_repo, pinned_ids} =
    with {:ok, raw} <- File.read(@pinned_file),
         {:ok, %{"expected_remote" => remote, "tickets" => tickets}} when is_list(tickets) <- Jason.decode(raw),
         [_, repo] <- Regex.run(~r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z}, remote) do
      {String.downcase(repo), tickets |> Enum.filter(&is_integer/1) |> Enum.map(&Integer.to_string/1)}
    else
      _ -> {nil, []}
    end

  @pinned_repo pinned_repo
  @pinned_ids pinned_ids

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
      {:except, pinned} -> Enum.reject(issues, &MapSet.member?(pinned, identifier(&1)))
      allowed -> Enum.filter(issues, &MapSet.member?(allowed, identifier(&1)))
    end
  end

  @spec allowed_identifier?(String.t() | nil) :: boolean()
  def allowed_identifier?(identifier) when is_binary(identifier) do
    case allowed_ids!() do
      :all -> true
      {:except, pinned} -> not MapSet.member?(pinned, identifier)
      allowed -> MapSet.member?(allowed, identifier)
    end
  end

  def allowed_identifier?(_identifier), do: not is_struct(allowed_ids!(), MapSet)

  @spec with_write_scope(map(), (-> term())) :: term()
  def with_write_scope(request, fun), do: with(:ok <- allow_write?(request), do: fun.())

  @doc "Whether an outgoing GitHub state mutation is inside the active test scope."
  @spec allow_write?(map()) :: :ok | {:error, {:outside_test_ticket_scope, String.t()}}
  def allow_write?(%{method: method, url: url} = request)
      when method in [:post, :patch, :put, :delete] and is_binary(url) do
    case System.get_env(@env) do
      nil ->
        allow_unscoped_write(resource_number(url))

      ids when is_binary(ids) and ids != "" ->
        allow_scoped_write(request, resource_number(url))

      _invalid_scope ->
        {:error, {:outside_test_ticket_scope, "unknown"}}
    end
  end

  def allow_write?(%{method: method}) when method in [:post, :patch, :put, :delete],
    do: {:error, {:outside_test_ticket_scope, "unknown"}}

  def allow_write?(_request), do: :ok

  defp allow_scoped_write(request, resource) do
    cond do
      allowed_post_request?(request) ->
        :ok

      dependency_mutation?(request) ->
        deny_write(resource_identifier(resource))

      match?({:ok, :issue, _number}, resource) and allowed_identifier?(resource_identifier(resource)) ->
        :ok

      true ->
        deny_write(resource_identifier(resource))
    end
  end

  defp allow_unscoped_write({:ok, :issue, number}),
    do: if(allowed_identifier?(number), do: :ok, else: deny_write(number))

  defp allow_unscoped_write(_resource), do: :ok

  defp deny_write(identifier), do: {:error, {:outside_test_ticket_scope, identifier}}

  defp installation_token_request?(url) do
    Regex.match?(~r{\Ahttps://api\.github\.com/app/installations/[1-9][0-9]*/access_tokens\z}, url)
  end

  defp allowed_post_request?(%{method: :post, url: url} = request) do
    installation_token_request?(url) or scoped_graphql_read?(request) or repository_label_create?(request)
  end

  defp allowed_post_request?(_request), do: false

  defp repository_label_create?(%{url: url, body: body}) do
    with %URI{} = uri <- URI.parse(url),
         true <- uri.scheme == "https" and uri.host == "api.github.com" and is_nil(uri.userinfo),
         true <- uri.port in [nil, 443] and uri.path == "/repos/#{configured_repository_path()}/labels",
         true <- is_map(body) and Map.get(body, "name") == "#{Config.label_prefix()}:queued" do
      true
    else
      _ -> false
    end
  end

  defp repository_label_create?(_request), do: false

  defp configured_repository_path do
    case configured_repository() do
      {:ok, {owner, repository}} -> "#{owner}/#{repository}"
      :error -> ""
    end
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

  # Only the repository the pinned file names: another repo's #2897 is unrelated.
  defp live_exclusions do
    with [_ | _] <- @pinned_ids,
         repo when is_binary(repo) <- Config.repo(),
         true <- String.downcase(repo) == @pinned_repo do
      {:except, MapSet.new(@pinned_ids)}
    else
      _ -> :all
    end
  end

  defp allowed_ids! do
    case System.get_env(@env) do
      nil ->
        live_exclusions()

      ids when is_binary(ids) ->
        if Regex.match?(~r/\A[1-9][0-9]*(?:,[1-9][0-9]*)*\z/, ids) do
          ids |> String.split(",") |> MapSet.new()
        else
          raise ArgumentError, "invalid #{@env}; expected comma-separated positive ticket IDs"
        end
    end
  end
end
