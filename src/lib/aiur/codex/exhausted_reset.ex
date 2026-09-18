defmodule Aiur.Codex.ExhaustedReset do
  @moduledoc """
  Remembers the numeric reset of the Codex rate-limit window that is used up.

  `account/rateLimits/read` and `account/rateLimits/updated` carry each window
  as `usedPercent` plus `resetsAt`, a Unix epoch in seconds. When a usage-limit
  refusal ends a turn, this epoch is the exact reset. The refusal text has only
  minute precision (#2737: text 01:26:00Z, `resetsAt` 1790040385 =
  01:26:25Z), so a pause prefers this value.

  Each observation replaces what is stored for its limit id. A window at 100
  percent with a `resetsAt` is exhausted. The latest reset is the latest
  exhausted reset that is still in the future. The store lives in the process
  that owns the app-server port, like the account-generation context.
  """

  @windows ["primary", "secondary"]

  @doc "Records the exhausted windows of one rate-limit snapshot (`params.rateLimits`)."
  @spec observe(map(), term()) :: :ok
  def observe(%{port: port}, %{} = rate_limits) when is_port(port) do
    case limit_resets(rate_limits) do
      :no_windows -> :ok
      resets -> put(port, Map.get(rate_limits, "limitId") || "default", resets)
    end
  end

  def observe(_session, _rate_limits), do: :ok

  @doc "Records an `account/rateLimits/read` response, including `rateLimitsByLimitId`."
  @spec observe_snapshot(map(), term()) :: :ok
  def observe_snapshot(session, %{} = response) do
    case Map.get(response, "rateLimitsByLimitId") do
      %{} = buckets when map_size(buckets) > 0 ->
        Enum.each(buckets, fn {limit_id, bucket} -> observe(session, with_limit_id(bucket, limit_id)) end)

      _ ->
        observe(session, Map.get(response, "rateLimits"))
    end
  end

  def observe_snapshot(_session, _response), do: :ok

  @doc "The latest future reset of an exhausted window, or nil."
  @spec latest(map(), DateTime.t()) :: DateTime.t() | nil
  def latest(%{port: port}, %DateTime{} = now) when is_port(port) do
    port
    |> key()
    |> Process.get(%{})
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.max(DateTime, fn -> nil end)
  end

  def latest(_session, _now), do: nil

  @spec clear(map()) :: :ok
  def clear(%{port: port}) when is_port(port) do
    Process.delete(key(port))
    :ok
  end

  def clear(_session), do: :ok

  defp with_limit_id(%{} = bucket, limit_id), do: Map.put_new(bucket, "limitId", limit_id)
  defp with_limit_id(bucket, _limit_id), do: bucket

  # `:no_windows` leaves the stored value alone: a patch without window facts
  # says nothing about whether a window is still used up.
  defp limit_resets(rate_limits) do
    windows = for name <- @windows, %{"usedPercent" => used} = window <- [Map.get(rate_limits, name)], is_number(used), do: window

    if windows == [] do
      :no_windows
    else
      for %{"usedPercent" => used, "resetsAt" => epoch} <- windows,
          used >= 100,
          is_integer(epoch) and epoch > 0,
          {:ok, reset} <- [DateTime.from_unix(epoch)],
          do: reset
    end
  end

  defp put(port, limit_id, []), do: update(port, &Map.delete(&1, limit_id))
  defp put(port, limit_id, resets), do: update(port, &Map.put(&1, limit_id, resets))

  defp update(port, fun) do
    Process.put(key(port), fun.(Process.get(key(port), %{})))
    :ok
  end

  defp key(port), do: {__MODULE__, port}
end
