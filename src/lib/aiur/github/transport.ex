defmodule Aiur.GitHub.Transport do
  @moduledoc """
  Shared GitHub REST and GraphQL transport helpers.
  """

  alias Aiur.GitHub
  alias Aiur.GitHub.Errors

  @base_url "https://api.github.com"
  @graphql_url "#{@base_url}/graphql"

  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @spec graphql_url() :: String.t()
  def graphql_url, do: @graphql_url

  @spec parse_repo() :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def parse_repo do
    case GitHub.Config.repo() do
      nil ->
        {:error, :missing_github_repo}

      repo_string ->
        case String.split(repo_string, "/") do
          [owner, repo] -> {:ok, {owner, repo}}
          _ -> {:error, {:invalid_github_repo, repo_string}}
        end
    end
  end

  @spec require_token() :: {:ok, String.t()} | {:error, :missing_github_token}
  def require_token do
    case GitHub.Config.token() do
      nil -> {:error, :missing_github_token}
      token -> {:ok, token}
    end
  end

  @spec require_token(keyword()) :: {:ok, String.t()} | {:error, :missing_github_token}
  def require_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        if Keyword.has_key?(opts, :request_fun) do
          {:ok, "test-gh-token"}
        else
          require_token()
        end
    end
  end

  @spec default_request_fun(map()) :: {:ok, map()} | {:error, term()}
  def default_request_fun(%{method: :get, url: url, token: token} = req) do
    headers =
      case Map.get(req, :etag) do
        nil -> github_headers(token, req)
        etag -> [{"If-None-Match", etag} | github_headers(token, req)]
      end

    Req.get(url, request_options(headers))
  end

  def default_request_fun(%{method: :post, url: url, token: token, body: body} = req) do
    Req.post(url,
      headers: github_headers(token, req),
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  def default_request_fun(%{method: :patch, url: url, token: token, body: body} = req) do
    Req.patch(url,
      headers: github_headers(token, req),
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  def default_request_fun(%{method: :delete, url: url, token: token} = req) do
    Req.delete(url, headers: github_headers(token, req), connect_options: [timeout: 30_000])
  end

  defp request_options(headers) do
    options = Application.get_env(:aiur, :github_transport_test_options, [])
    options = if is_list(options) and Keyword.keyword?(options), do: options, else: []
    Keyword.merge(options, headers: headers, connect_options: [timeout: 30_000])
  end

  @spec github_headers(String.t(), map()) :: [{String.t(), String.t()}]
  def github_headers(token, %{api_version: version}) when is_binary(version) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", version}
    ]
  end

  def github_headers(token, _req) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  @spec github_graphql(function(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def github_graphql(request_fun, token, query, variables) do
    body = %{"query" => query, "variables" => variables}

    case request_fun.(%{method: :post, url: @graphql_url, token: token, body: body}) do
      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, %{status: 200, body: response}} when is_map(response) ->
        {:ok, response}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec fetch_json_list(function(), String.t(), String.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_json_list(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec fetch_json_map(function(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_json_map(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec parse_next_page_url(list() | map()) :: String.t() | nil
  def parse_next_page_url(headers) do
    case header(headers, "link") do
      value when is_binary(value) ->
        Regex.run(~r/<([^>]+)>;\s*rel="next"/, value)
        |> case do
          [_, next_url] -> next_url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec maybe_put_query(map(), String.t(), term()) :: map()
  def maybe_put_query(query, _key, nil), do: query
  def maybe_put_query(query, key, value), do: Map.put(query, key, value)

  @spec header(list() | map(), String.t()) :: term() | nil
  def header(headers, name) when is_list(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name_down do
          List.wrap(value) |> List.first()
        end

      _ ->
        nil
    end)
  end

  def header(headers, name) when is_map(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name_down do
        List.wrap(value) |> List.first()
      end
    end)
  end

  @spec poll_interval(list() | map()) :: pos_integer()
  def poll_interval(headers) do
    case header(headers, "x-poll-interval") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> 60
        end

      _ ->
        60
    end
  end
end
