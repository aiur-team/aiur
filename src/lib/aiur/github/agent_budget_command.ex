defmodule Aiur.GitHub.AgentBudgetCommand do
  @moduledoc false

  alias Aiur.AgentGitHubGuard.AgentToken
  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Budget.{BrokerPort, Shared}
  alias Aiur.GitHub.EndpointPolicy

  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, term()}
  def execute(args), do: execute(args, [])

  @spec execute([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(args, opts) when is_list(args) do
    with {:ok, token} <- agent_token(),
         {:ok, request, budget_opts} <- request(args, token, opts) do
      dispatch(args, token, request, budget_opts)
    end
  end

  defp dispatch(["acquire" | _], _token, request, opts) do
    if Keyword.get(opts, :priority?), do: Budget.prioritize()
    Budget.acquire(request, opts) |> acquire_response()
  end

  defp dispatch(["release", "--lease-id", id], token, _request, opts) do
    if valid_lease?(id) do
      Budget.release(%{id: id, token_key: Budget.token_key(token)}, opts)
      {:ok, "released\n"}
    else
      {:error, :invalid_request}
    end
  end

  defp dispatch(["reconcile", "--lease-id", id, "--status", "304"], _token, request, opts) do
    if valid_lease?(id) do
      Budget.observe(request, {:ok, %{status: 304}}, opts)
      {:ok, "reconciled\n"}
    else
      {:error, :invalid_request}
    end
  end

  defp dispatch(["renew", "--lease-id", id, "--lease-ttl-ms", ttl], token, _request, opts) do
    if valid_lease?(id) and valid_integer?(ttl, 1_000..3_600_000) do
      broker_call(["renew", "--lease-id", id, "--lease-ttl-ms", ttl], Budget.token_key(token), opts)
    else
      {:error, :invalid_request}
    end
  end

  defp dispatch(["hold", "--scope", scope, "--resource", resource, "--delay-ms", delay], token, _request, opts)
       when scope in ["token", "resource"] and resource in ["core", "graphql", "search"] do
    case Integer.parse(delay) do
      {milliseconds, ""} when milliseconds in 1..3_600_000 ->
        update_hold(scope, resource, delay, milliseconds, token, opts)

      _invalid ->
        {:error, :invalid_request}
    end
  end

  defp dispatch(_args, _token, _request, _opts), do: {:error, :invalid_request}

  defp acquire_response({:ok, %{id: id}}), do: {:ok, "granted #{id}\n"}

  defp acquire_response({:hold, %{resource: resource, reset_at: reset_at, reason: :shared_budget}}),
    do: {:ok, "hold shared #{resource} #{DateTime.to_unix(reset_at, :millisecond)}\n"}

  defp acquire_response({:hold, %{reset_at: reset_at, reason: reason}}) do
    delay = max(DateTime.diff(reset_at, DateTime.utc_now(), :millisecond), 1)
    prefix = if reason == :actor_budget, do: "wait actor", else: "wait"
    {:ok, "#{prefix} #{delay}\n"}
  end

  defp acquire_response({:error, _} = error), do: error
  defp acquire_response(:bypass), do: {:error, :github_budget_broker_unavailable}

  defp update_hold(scope, resource, delay, milliseconds, token, opts) do
    key = Budget.token_key(token)
    request = %{token: token, url: family_url(resource)}
    args = ["hold", "--scope", scope, "--resource", resource, "--delay-ms", delay]

    case broker_call(args, key, opts) do
      {:ok, _output} ->
        Shared.publish_hold(request, key, if(scope == "token", do: "*", else: resource), milliseconds)
        {:ok, "held\n"}

      {:error, _} = error ->
        error

      _unavailable ->
        {:error, :github_budget_broker_unavailable}
    end
  end

  defp request(["acquire" | args], token, opts) do
    values = parse_args(args)
    family = Map.get(values, "--endpoint-family")
    consumer = Map.get(values, "--consumer-label")
    consumer_key = Map.get(values, "--consumer-key")
    family_entry = Enum.find(EndpointPolicy.families(), &(elem(&1, 0) == family))

    with {^family, resource, _billable} <- family_entry,
         true <- is_binary(consumer) and String.starts_with?(consumer, "workspace:"),
         true <- consumer_key == Budget.token_key(consumer),
         true <- Map.get(values, "--resource") == resource do
      request = %{token: token, url: family_url(family), credential_key: Budget.token_key(token)}

      budget_opts =
        Keyword.merge(opts,
          consumer_key: consumer,
          enabled?: true,
          max_inflight: integer(values, "--max-inflight", 4),
          max_inflight_per_endpoint: integer(values, "--max-inflight-per-endpoint", 2),
          requests_per_minute: integer(values, "--requests-per-minute", 300),
          stagger_ms: integer(values, "--stagger-ms", 75),
          lease_timeout_ms: max(div(integer(values, "--lease-ttl-ms", 35_000) - 5000, 2), 1000),
          timeout_ms: 120_000,
          agent_core_limit_per_hour: integer(values, "--core-limit", 0),
          agent_graphql_limit_per_hour: integer(values, "--graphql-limit", 0),
          agent_search_limit_per_hour: integer(values, "--search-limit", 0),
          priority?: Map.has_key?(values, "--priority"),
          broker_extra_args: cache_args(values) ++ cooldown_args(values)
        )

      {:ok, request, budget_opts}
    else
      _invalid -> {:error, :invalid_request}
    end
  rescue
    _error -> {:error, :invalid_request}
  end

  defp request([command | _], token, opts) when command in ["release", "reconcile", "renew", "hold"],
    do: {:ok, %{token: token, url: "https://api.github.com/rate_limit"}, Keyword.put(opts, :enabled?, true)}

  defp request(_args, _token, _opts), do: {:error, :invalid_request}

  defp agent_token do
    case File.read(AgentToken.path()) do
      {:ok, token} ->
        case String.trim(token) do
          value when value != "" -> {:ok, value}
          _empty -> {:error, :credential_unavailable}
        end

      _missing ->
        {:error, :credential_unavailable}
    end
  end

  defp valid_lease?(id), do: Regex.match?(~r/\A[a-f0-9]{32}\z/, id)

  defp valid_integer?(value, range) do
    case Integer.parse(value) do
      {number, ""} -> number in range
      _invalid -> false
    end
  end

  defp integer(values, key, default) do
    case Integer.parse(Map.get(values, key, "")) do
      {number, ""} -> number
      _invalid -> default
    end
  end

  defp cache_args(values) do
    case Map.get(values, "--cache-key") do
      key when is_binary(key) and key != "" ->
        ["--cache-key", key, "--cache-claim-ttl-ms", Integer.to_string(integer(values, "--cache-claim-ttl-ms", 35_000))] ++
          if(Map.has_key?(values, "--cache-ignore-claim"), do: ["--cache-ignore-claim"], else: [])

      _missing ->
        []
    end
  end

  defp cooldown_args(values),
    do: if(Map.has_key?(values, "--ignore-token-cooldown"), do: ["--ignore-token-cooldown"], else: [])

  defp parse_args(args), do: parse_args(args, %{})
  defp parse_args([], values), do: values

  defp parse_args([flag | rest], values) when flag in ["--priority", "--ignore-token-cooldown", "--cache-ignore-claim"],
    do: parse_args(rest, Map.put(values, flag, true))

  defp parse_args([flag, value | rest], values) when is_binary(flag) and is_binary(value),
    do: parse_args(rest, Map.put(values, flag, value))

  defp parse_args(_args, values), do: values

  defp family_url("rate_limit"), do: "https://api.github.com/rate_limit"
  defp family_url("graphql"), do: "https://api.github.com/graphql"
  defp family_url("search"), do: "https://api.github.com/search/issues"
  defp family_url(family), do: "https://api.github.com/repos/aiur/budget/#{family}"

  defp broker_call(args, key, opts), do: BrokerPort.command(args, key, opts)
end
