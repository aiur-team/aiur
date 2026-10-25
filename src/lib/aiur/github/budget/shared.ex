defmodule Aiur.GitHub.Budget.Shared do
  @moduledoc false

  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Budget.{BrokerPort, Settings}
  alias Aiur.Instance.LeaseStore
  @retry_floor_ms 5

  @spec shared_hold(integer(), String.t(), (map() -> term())) :: term()
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

  @spec hold_status(map(), String.t(), keyword()) :: term()
  def hold_status(request, token_key, opts \\ []) do
    status_fun = Keyword.get(opts, :coordination_status_fun, &LeaseStore.budget_coordination_status/0)
    hold_fun = Keyword.get(opts, :github_budget_hold_fun, &LeaseStore.github_budget_hold/2)
    status = status_fun.()

    if status.available? do
      credential_key = Map.get(request, :credential_key) || token_key

      case hold_fun.(credential_key, Budget.request_resource(request)) do
        {:ok, nil} -> :clear
        {:ok, until_at} when is_struct(until_at, DateTime) -> {:held, until_at}
        # LeaseStore marks the connection unavailable and schedules a reconnect
        # before returning this error. Continue to the local broker, whose
        # acquire args now divide the ceiling by the last known live count.
        {:error, _reason} -> :clear
        _other -> :clear
      end
    else
      :clear
    end
  end

  @spec grant_or_hold(String.t(), map(), String.t(), keyword()) :: term()
  def grant_or_hold(id, request, token_key, opts \\ []) do
    if String.match?(id, ~r/\A[a-f0-9]{32}\z/) do
      case admit(id, request, token_key, opts) do
        :admitted ->
          {:ok, %{id: id, token_key: token_key}}

        :disabled ->
          {:ok, %{id: id, token_key: token_key}}

        {:held, reset_at} ->
          release_lease(id, token_key, opts)
          {:hold, %{reason: :shared_budget, resource: Budget.request_resource(request), reset_at: reset_at}}

        # The local broker has already granted this lease using the divided
        # fallback ceiling only if the roster was unavailable before acquire.
        # The caller retries locally with a divided ceiling because the store
        # can fail between its initial status check and this admission.
        {:error, _reason} ->
          release_lease(id, token_key, opts)
          :retry_fallback
      end
    else
      {:error, :github_budget_broker_unavailable}
    end
  end

  defp release_lease(id, token_key, opts) do
    release_fun =
      Keyword.get(opts, :release_fun, fn lease_id, key ->
        BrokerPort.command(["release", "--lease-id", lease_id], key, [])
      end)

    _ = release_fun.(id, token_key)
    :ok
  end

  @spec fallback_limits(tuple(), map()) :: tuple()
  def fallback_limits(limits, coordination),
    do: fallback_limits(limits, coordination, LeaseStore.configured?())

  @spec fallback_limits(tuple(), map(), boolean()) :: tuple()
  def fallback_limits({core, graphql, search} = limits, coordination, configured?) do
    cond do
      not configured? ->
        limits

      coordination.available? ->
        {core, graphql, search}

      true ->
        # Even when the last roster read saw only this daemon, an outage can hide
        # another instance starting at the same time. Reserve half the ceiling
        # until shared admissions are available again.
        count = max(coordination.live_count, 2)
        {fallback_limit(core, count), fallback_limit(graphql, count), fallback_limit(search, count)}
    end
  end

  @spec publish_hold(map(), String.t(), String.t(), non_neg_integer()) :: :ok
  def publish_hold(request, token_key, resource, delay_ms) do
    credential_key = Map.get(request, :credential_key) || token_key
    until_at = DateTime.add(DateTime.utc_now(), max(ceil(delay_ms / 1_000), 1), :second)
    _ = LeaseStore.publish_github_budget_hold(credential_key, resource, until_at)
    :ok
  end

  defp admit(lease_id, request, token_key, opts) do
    if Keyword.get(opts, :fallback_only?, false) do
      :disabled
    else
      admit_with_coordination(lease_id, request, token_key, opts)
    end
  end

  defp admit_with_coordination(lease_id, request, token_key, opts) do
    status_fun = Keyword.get(opts, :coordination_status_fun, &LeaseStore.budget_coordination_status/0)

    if status_fun.().available? do
      admit_shared(lease_id, request, token_key, opts)
    else
      :disabled
    end
  end

  defp admit_shared(lease_id, request, token_key, opts) do
    resource = Budget.request_resource(request)
    limits = Settings.settings(opts)
    limit = resource_limit(resource, limits)
    credential_key = Map.get(request, :credential_key) || token_key
    consumer_key = Settings.consumer_key([])
    # Until GitHub reports query cost, charge one request per admission.
    points = Keyword.get(opts, :request_points, 1)

    admit_fun = Keyword.get(opts, :github_budget_admit_fun, &LeaseStore.admit_github_budget/6)

    case admit_fun.(lease_id, credential_key, resource, consumer_key, limit, points) do
      {:ok, :admitted} -> :admitted
      {:ok, {:held, reset_at}} -> {:held, reset_at}
      :disabled -> :disabled
      {:error, _reason} = error -> error
    end
  end

  defp resource_limit(resource, limits) do
    case resource do
      "graphql" -> limits.daemon_graphql_limit_per_hour
      "search" -> limits.daemon_search_limit_per_hour
      "core" -> limits.daemon_core_limit_per_hour
      _other -> 0
    end
  end

  defp fallback_limit(0, _count), do: 0
  defp fallback_limit(limit, count), do: max(div(limit, count), 1)
end
