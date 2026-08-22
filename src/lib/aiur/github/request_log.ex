defmodule Aiur.GitHub.RequestLog do
  @moduledoc """
  Durable per-request record of every GitHub request the daemon makes.

  `Aiur.GitHub.Quota` keeps a rolling-hour, in-memory attribution that answers
  *how much* each caller spent; nothing on disk answered *which* requests were
  made. The broker's `admissions` table only ever saw calls routed through the
  agent `gh` guard wrapper, stored neither method, path, status nor cost, and
  pruned to a rolling hour — so when the burn window closed, the evidence was
  already gone (#2255). This module appends one TSV row per daemon request at
  the `Quota` chokepoint, so "which requests consumed budget in window W" is
  answerable from logs alone, after the window has closed.

  ## Record shape

  Tab-separated, one row per request:

  `ts, pid, consumer, caller, method, host, path, status, resource, direction,
  cost, cost_source, token_key`

  * `consumer` — the ticket the request belongs to, derived exactly as `Quota`
    does (from a `/issues/N` / `/pulls/N` URL or a GraphQL variable), or
    `"unattributed"` when none can be named.
  * `caller` — the call site (`GraphQLCost.derive/1`): the GraphQL operation
    name or the REST route shape, so aggregates stay answerable at a glance.
  * `cost` / `cost_source` — the points/requests the response reported the call
    cost, following `Quota`'s rules (GraphQL points from `rateLimit { cost }`,
    one point marked `assumed` when the query did not ask, zero for `304`).
  * `token_key` — the one-way SHA-256 fingerprint of the credential (`Budget.token_key/1`).
    **Never the token.** This is what answers "which pool did this bill" — the
    daemon's App installation token and the agent PAT bill different budgets,
    and only the fingerprint distinguishes them without a live `/proc` sweep.

  ## Retention

  The current file rotates to `.1` then `.2` at 1 MiB, so roughly three file
  generations survive — hours, not one hour. The broker's `admissions` table
  still prunes to its rolling hour (that retention is what its per-actor hourly
  ceiling is counted against); the request log is the multi-hour evidence the
  ticket's acceptance criterion #4 demands.
  """

  alias Aiur.GitHub.{Budget, GraphQLCost}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.RepoBase

  @max_bytes 1_048_576
  @generations 2
  @columns ~w(ts pid consumer caller method host path status resource direction cost cost_source token_key)

  @spec append(map(), {:ok, map()} | {:error, term()}, DateTime.t(), keyword()) :: :ok
  def append(request, result, now, opts \\ []) do
    case log_path(opts) do
      path when is_binary(path) and path != "" -> append_to(path, record(request, result, now))
      _unconfigured -> :ok
    end
  end

  @doc "The resolved log path for a run, or `nil` when logging is disabled/unconfigured."
  @spec log_path(keyword()) :: String.t() | nil
  def log_path(opts \\ []) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> path
      # `nil` means the caller explicitly disabled the request log (tests,
      # no repository configured); it must not silently fall back to the
      # default path.
      _explicitly_disabled -> nil
    end
  end

  @doc false
  @spec default_path() :: String.t() | nil
  def default_path do
    if Application.get_env(:aiur, :env) == :test do
      # The test env resolves `GitHub.Config.repo()` from this checkout's git
      # remote or a mocked workflow repo; never write a request log there. Tests
      # that want one pass `path:` explicitly.
      nil
    else
      resolve_default_path()
    end
  end

  defp resolve_default_path do
    case GitHubConfig.repo() do
      repo when is_binary(repo) and repo != "" ->
        repo
        |> RepoBase.repo_path()
        |> Path.join("github-quota")
        |> Path.join("daemon-requests.tsv")

      _unconfigured ->
        nil
    end
  rescue
    _unavailable -> nil
  end

  defp record(request, result, now) do
    resource = request_resource(request)
    {cost, cost_source} = request_cost(resource, result)

    %{
      "ts" => Integer.to_string(DateTime.to_unix(now)),
      "pid" => Integer.to_string(os_pid()),
      "consumer" => request_consumer(request),
      "caller" => GraphQLCost.derive(request),
      "method" => request_method(request),
      "host" => request_host(request),
      "path" => request_path(request),
      "status" => response_status(result),
      "resource" => resource,
      "direction" => request_direction(request),
      "cost" => Integer.to_string(cost),
      "cost_source" => Atom.to_string(cost_source),
      "token_key" => token_key(request)
    }
  end

  defp append_to(path, fields) do
    :ok = File.mkdir_p(Path.dirname(path))
    rotate_if_large(path)
    File.write(path, Enum.map_join(@columns, "\t", &Map.fetch!(fields, &1)) <> "\n", [:append])
    :ok
  rescue
    _unavailable -> :ok
  end

  # Rotate the current file to `.1` … `.N` once it passes the size cap, the
  # same shape the agent `gh` wrapper uses for `agent-requests.tsv`, so a
  # burst of requests can never grow the active file without bound and the
  # previous generations are what provide the multi-hour retention.
  defp rotate_if_large(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes -> rotate(path, @generations)
      _other -> :ok
    end
  end

  defp rotate(_path, 0), do: :ok

  defp rotate(path, generation) do
    next = "#{path}.#{generation}"

    if generation == 1 do
      _ = File.rm(next)
      :ok = File.rename(path, next)
    else
      previous = "#{path}.#{generation - 1}"
      if File.exists?(previous), do: File.rename(previous, next)
      rotate(path, generation - 1)
    end

    :ok
  rescue
    _unavailable -> :ok
  end

  defp os_pid, do: :os.getpid() |> List.to_integer()

  # Every derivation below mirrors `Aiur.GitHub.Quota`, which remains the
  # canonical source of attribution semantics; the two must agree or the
  # durable log and the in-memory ranking would tell different stories.

  defp request_resource(%{anonymous: true}), do: "core:anonymous"

  defp request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  defp request_resource(_request), do: "core"

  defp request_direction(%{method: :post, url: url, body: %{"query" => query}}) when is_binary(url) and is_binary(query) do
    if URI.parse(url).path == "/graphql" and Regex.match?(~r/^\s*mutation\b/i, query), do: "write", else: "read"
  end

  defp request_direction(%{method: method}) when method in [:get, :head], do: "read"
  defp request_direction(_request), do: "write"

  defp request_consumer(%{consumer: consumer}) when is_binary(consumer) and consumer != "", do: consumer

  defp request_consumer(request) do
    ticket_number_from_url(request) || ticket_number_from_variables(request) || "unattributed"
  end

  defp ticket_number_from_url(%{url: url}) when is_binary(url) do
    case Regex.run(~r{/(?:issues|pulls)/(\d+)(?:/|$)}, URI.parse(url).path || "") do
      [_, number] -> "ticket:#{number}"
      _no_ticket -> nil
    end
  end

  defp ticket_number_from_url(_request), do: nil

  defp ticket_number_from_variables(%{body: %{"variables" => variables}}) when is_map(variables) do
    case find_ticket_number(variables) do
      nil -> nil
      number -> "ticket:#{number}"
    end
  end

  defp ticket_number_from_variables(_request), do: nil

  defp find_ticket_number(map) when is_map(map) do
    direct =
      Enum.find_value(~w(number issue_number pull_number), fn key ->
        valid_ticket_number(Map.get(map, key) || Map.get(map, String.to_atom(key)))
      end)

    direct || Enum.find_value(Map.values(map), &find_ticket_number/1)
  end

  defp find_ticket_number(list) when is_list(list), do: Enum.find_value(list, &find_ticket_number/1)
  defp find_ticket_number(_value), do: nil

  defp valid_ticket_number(number) when is_integer(number) and number > 0, do: number

  defp valid_ticket_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> nil
    end
  end

  defp valid_ticket_number(_number), do: nil

  defp request_cost(_resource, {:ok, %{status: 304}}), do: {0, :reported}

  defp request_cost("graphql", {:ok, %{status: _status} = response}) do
    case GraphQLCost.reported(response) do
      %{cost: cost} when is_integer(cost) and cost >= 0 -> {cost, :reported}
      _unreported -> {1, :assumed}
    end
  end

  defp request_cost(_resource, {:ok, %{status: _status}}), do: {1, :reported}
  defp request_cost(_resource, _error), do: {1, :assumed}

  defp request_method(%{method: method}) when is_atom(method), do: Atom.to_string(method)
  defp request_method(%{method: method}) when is_binary(method), do: method
  defp request_method(_request), do: "unknown"

  defp request_host(%{url: url}) when is_binary(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> host
      _none -> ""
    end
  end

  defp request_host(_request), do: ""

  defp request_path(%{url: url}) when is_binary(url), do: URI.parse(url).path || ""
  defp request_path(_request), do: ""

  defp response_status({:ok, %{status: status}}) when is_integer(status), do: Integer.to_string(status)
  defp response_status(_result), do: "error"

  defp token_key(%{token: token}) when is_binary(token) and token != "", do: Budget.token_key(token) || ""
  defp token_key(_request), do: ""
end
