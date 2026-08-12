defmodule Aiur.GitHub.Transport do
  @moduledoc """
  Shared GitHub REST and GraphQL transport helpers.
  """

  alias Aiur.GitHub
  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Errors
  alias Aiur.GitHub.GraphQLErrors
  alias Aiur.GitHub.Quota

  require Logger

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

    quota_request(req, fn -> Req.get(url, request_options(headers, req)) end)
  end

  def default_request_fun(%{method: :post, url: url, token: token, body: body} = req) do
    options =
      token
      |> github_headers(req)
      |> request_options(req)
      |> Keyword.put(:json, body)

    quota_request(req, fn -> Req.post(url, options) end)
  end

  def default_request_fun(%{method: :patch, url: url, token: token, body: body} = req) do
    quota_request(req, fn ->
      options = github_headers(token, req) |> request_options(req) |> Keyword.put(:json, body)
      Req.patch(url, options)
    end)
  end

  def default_request_fun(%{method: :delete, url: url, token: token} = req) do
    quota_request(req, fn -> Req.delete(url, request_options(github_headers(token, req), req)) end)
  end

  defp quota_request(request, request_fun) do
    quota = Application.get_env(:aiur, :github_quota_server, Quota)

    case quota_preflight(quota, request) do
      :ok ->
        budget_request(quota, request, request_fun)

      {:hold, hold} ->
        {:ok, held_response(hold)}
    end
  end

  defp budget_request(quota, request, request_fun) do
    case Budget.acquire(request, timeout_ms: Map.get(request, :timeout_ms, 30_000)) do
      {:ok, lease} ->
        try do
          result = request_fun.()
          :ok = Budget.observe(request, result, timeout_ms: Map.get(request, :timeout_ms, 30_000))
          quota_observe(quota, request, result)
          result
        after
          Budget.release(lease)
        end

      {:hold, hold} ->
        {:ok, held_response(hold)}

      :bypass ->
        result = request_fun.()
        quota_observe(quota, request, result)
        result
    end
  end

  defp quota_preflight(quota, request), do: Quota.preflight(quota, request)
  defp quota_observe(quota, request, result), do: Quota.observe(quota, request, result)

  defp held_response(hold) do
    reset_unix = DateTime.to_unix(hold.reset_at)
    remaining = Map.get(hold, :remaining, 0)
    limit = Map.get(hold, :limit, 1)

    %{
      status: 429,
      headers: [
        {"x-ratelimit-resource", hold.resource},
        {"x-ratelimit-limit", Integer.to_string(limit)},
        {"x-ratelimit-remaining", Integer.to_string(remaining)},
        {"x-ratelimit-reset", Integer.to_string(reset_unix)}
      ],
      body: %{"message" => "GitHub #{hold.resource} quota is exhausted locally; retry after #{DateTime.to_iso8601(hold.reset_at)}"}
    }
  end

  defp request_options(headers, req) do
    options = Application.get_env(:aiur, :github_transport_test_options, [])
    options = if is_list(options) and Keyword.keyword?(options), do: options, else: []
    timeout_ms = Map.get(req, :timeout_ms, 30_000)

    options
    # The shared budget lease covers one network attempt. Req retries safe
    # transient responses, including 429, by default; allowing that retry here
    # would make one admission hide several GitHub calls and could swallow the
    # response that establishes the fleet-wide cooldown.
    |> Keyword.merge(headers: headers, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms, retry: false)
    |> maybe_bound_response(req)
  end

  defp maybe_bound_response(options, %{max_response_bytes: limit})
       when is_integer(limit) and limit > 0 do
    Keyword.put(options, :into, bounded_response_collector(limit))
  end

  defp maybe_bound_response(options, _req), do: options

  defp bounded_response_collector(limit) do
    fn {:data, data}, {request, response} ->
      body = [response.body, data] |> IO.iodata_to_binary()

      if byte_size(body) <= limit do
        {:cont, {request, %{response | body: body}}}
      else
        response =
          response
          |> Map.put(:body, "")
          |> Req.Response.put_private(:aiur_response_too_large, true)

        {:halt, {request, response}}
      end
    end
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

  @spec github_graphql(function(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def github_graphql(request_fun, token, query, variables, opts \\ []) do
    case github_graphql_response(request_fun, token, query, variables, opts) do
      {:ok, body, response} ->
        log_rate_budget_pressure(response)
        {:ok, body}

      {:error, :invalid_graphql_response, _response} ->
        {:error, :invalid_graphql_response}

      {:error, _reason, %{status: 200, body: %{"errors" => errors}}} when is_list(errors) ->
        {:error, {:github_graphql_errors, errors}}

      {:error, {:github, _classification, _detail}, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason, _response} ->
        {:error, reason}
    end
  end

  @spec github_graphql_response(function(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term(), map() | nil}
  def github_graphql_response(request_fun, token, query, variables, opts \\ []) do
    body = %{"query" => query, "variables" => variables}

    request =
      %{method: :post, url: @graphql_url, token: token, body: body}
      |> maybe_put_max_response_bytes(opts)

    validate_graphql_response(request_fun.(request))
  end

  defp maybe_put_max_response_bytes(request, opts) do
    case Keyword.get(opts, :max_response_bytes) do
      limit when is_integer(limit) and limit > 0 -> Map.put(request, :max_response_bytes, limit)
      _limit -> request
    end
  end

  defp validate_graphql_response({:ok, response}), do: validate_graphql_http_response(response)
  defp validate_graphql_response({:error, reason}), do: {:error, Errors.classify_error({:error, reason}), nil}
  defp validate_graphql_response(_response), do: {:error, :invalid_graphql_response, nil}

  defp validate_graphql_http_response(%{private: %{aiur_response_too_large: true}} = response),
    do: {:error, :github_graphql_response_too_large, response}

  defp validate_graphql_http_response(%{status: 200} = response), do: validate_graphql_success(response)

  defp validate_graphql_http_response(%{status: status} = response)
       when is_integer(status) and status in 100..599 do
    {:error, Errors.github_graph_status_error(response), response}
  end

  defp validate_graphql_http_response(%{} = response), do: {:error, :invalid_graphql_response, response}
  defp validate_graphql_http_response(_response), do: {:error, :invalid_graphql_response, nil}

  defp validate_graphql_success(%{body: %{"errors" => errors}} = response) do
    if valid_graphql_errors?(errors),
      do: {:error, Errors.graphql_error(response), response},
      else: {:error, :invalid_graphql_response, response}
  end

  defp validate_graphql_success(%{body: body} = response) when is_map(body), do: {:ok, body, response}
  defp validate_graphql_success(response), do: {:error, :invalid_graphql_response, response}

  defp valid_graphql_errors?(errors) when is_list(errors) and errors != [], do: Enum.all?(errors, &is_map/1)
  defp valid_graphql_errors?(_errors), do: false

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

  @doc """
  Fetches a JSON list conditionally and preserves the response ETag.

  A `304 Not Modified` is a successful, budget-free response. Callers keep
  their last materialized value and use the returned ETag on the next request.
  """
  @spec fetch_json_list_conditional(function(), String.t(), String.t(), String.t() | nil) ::
          {:ok, [term()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_json_list_conditional(request_fun, token, url, etag \\ nil) do
    request = %{method: :get, url: url, token: token}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        log_rate_budget_pressure(response)
        {:ok, body, header(Map.get(response, :headers, []), "etag") || etag}

      {:ok, %{status: 304} = response} ->
        log_rate_budget_pressure(response)
        {:not_modified, header(Map.get(response, :headers, []), "etag") || etag}

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

  @spec header(term(), String.t()) :: term() | nil
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

  def header(_headers, _name), do: nil

  defp log_rate_budget_pressure(response) do
    remaining = GraphQLErrors.rate_limit_remaining(response)
    limit = header(Map.get(response, :headers, []), "x-ratelimit-limit") |> parse_nonnegative_integer()

    if is_integer(remaining) and is_integer(limit) and limit > 0 and remaining * 10 <= limit do
      resource = header(Map.get(response, :headers, []), "x-ratelimit-resource") || "unknown"
      reset_at = GraphQLErrors.rate_limit_reset(response) || "unknown"

      Logger.warning("github_rate_budget_pressure resource=#{resource} remaining=#{remaining} limit=#{limit} reset_at=#{reset_at}")
    end
  end

  defp parse_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_nonnegative_integer(_value), do: nil

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
