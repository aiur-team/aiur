defmodule Aiur.GitHub.Budget.Shared do
  @moduledoc false

  alias Aiur.GitHub.Budget.{Settings, BrokerPort}
  @retry_floor_ms 5

  def shared_hold(deadline_at, metadata, retry_fun) do
    with [resource, reset_at_ms] <- String.split(String.trim(metadata), " ", parts: 2),
         true <- resource in ["core", "graphql", "search"],
         {reset_at_ms, ""} when reset_at_ms > 0 <- Integer.parse(reset_at_ms),
         {:ok, reset_at} <- DateTime.from_unix(reset_at_ms, :millisecond),
         true <- reset_at_ms > System.system_time(:millisecond) do
      delay_ms = reset_at_ms - System.system_time(:millisecond)

      if System.monotonic_time(:millisecond) + delay_ms >= deadline_at do
        {:hold, %{reason: :shared_budget, resource: resource, reset_at: reset_at}}
      else
        Process.sleep(max(delay_ms, @retry_floor_ms))
        retry_fun.(%{reason: :shared_budget, resource: resource, reset_at: reset_at})
      end
    else
      _invalid -> {:error, :github_budget_broker_unavailable}
    end
  end

  def hold_status(request, token_key) do
    status = Aiur.Instance.LeaseStore.budget_coordination_status()

    if status.available? do
      credential_key = Map.get(request, :credential_key) || token_key

      case Aiur.Instance.LeaseStore.github_budget_hold(credential_key, Aiur.GitHub.Budget.request_resource(request)) do
        {:ok, nil} -> :clear
        {:ok, until_at} when is_struct(until_at, DateTime) -> {:held, until_at}
        {:error, reason} -> {:error, reason}
        _other -> :clear
      end
    else
      :clear
    end
  end

  def grant_or_hold(id, request, token_key) do
    if String.match?(id, ~r/\A[a-f0-9]{32}\z/) do
      case admit(id, request, token_key) do
        :admitted ->
          {:ok, %{id: id, token_key: token_key}}

        :disabled ->
          {:ok, %{id: id, token_key: token_key}}

        {:held, reset_at} ->
          _ = BrokerPort.command(["release", "--lease-id", id], token_key, [])
          {:hold, %{reason: :shared_budget, resource: Aiur.GitHub.Budget.request_resource(request), reset_at: reset_at}}

        {:error, _reason} ->
          _ = BrokerPort.command(["release", "--lease-id", id], token_key, [])
          {:error, :github_budget_broker_unavailable}
      end
    else
      {:error, :github_budget_broker_unavailable}
    end
  end

  def fallback_limits({core, graphql, search}, coordination) do
    if coordination.available? do
      {core, graphql, search}
    else
      count = max(coordination.live_count, 1)
      {fallback_limit(core, count), fallback_limit(graphql, count), fallback_limit(search, count)}
    end
  end

  def publish_hold(request, token_key, resource, delay_ms) do
    credential_key = Map.get(request, :credential_key) || token_key
    until_at = DateTime.add(DateTime.utc_now(), max(ceil(delay_ms / 1_000), 1), :second)
    _ = Aiur.Instance.LeaseStore.publish_github_budget_hold(credential_key, resource, until_at)
    :ok
  end

  defp admit(lease_id, request, token_key) do
    if Aiur.Instance.LeaseStore.budget_coordination_status().available? do
      resource = Aiur.GitHub.Budget.request_resource(request)
      limits = Settings.settings([])

      limit =
        case resource do
          "graphql" -> limits.daemon_graphql_limit_per_hour
          "search" -> limits.daemon_search_limit_per_hour
          "core" -> limits.daemon_core_limit_per_hour
          _ -> 0
        end

      credential_key = Map.get(request, :credential_key) || token_key
      consumer_key = Settings.consumer_key([])

      points = request_points(request, resource)

      case Aiur.Instance.LeaseStore.admit_github_budget(lease_id, credential_key, resource, consumer_key, limit, points) do
        {:ok, :admitted} -> :admitted
        {:ok, {:held, reset_at}} -> {:held, reset_at}
        :disabled -> :disabled
        {:error, _reason} = error -> error
      end
    else
      :disabled
    end
  end

  defp fallback_limit(0, _count), do: 0
  defp fallback_limit(limit, count), do: max(div(limit, count), 1)

  defp request_points(%{method: method}, resource) when method in ["GET", "HEAD"] and resource != "graphql", do: 1
  defp request_points(_request, "graphql"), do: 1
  defp request_points(_request, _resource), do: 1
end
