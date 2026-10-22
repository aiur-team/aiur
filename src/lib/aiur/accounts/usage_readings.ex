defmodule Aiur.Accounts.UsageReadings do
  @moduledoc "Small read model for per-account provider usage observations."

  @key {__MODULE__, :readings}

  @spec snapshot() :: %{{String.t(), String.t()} => map()}
  def snapshot, do: :persistent_term.get(@key, %{})

  @spec reset() :: :ok
  def reset, do: :persistent_term.erase(@key) && :ok

  @spec snapshot(String.t(), [String.t()]) :: %{String.t() => map()}
  def snapshot(harness, names) do
    names
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.fetch(snapshot(), {harness, name}) do
        {:ok, reading} -> Map.put(acc, name, reading)
        :error -> acc
      end
    end)
  end

  @spec record(String.t(), term(), DateTime.t()) :: :ok
  def record(name, result, observed_at) do
    record("claude", name, result, observed_at)
  end

  @spec record(String.t(), String.t(), term(), DateTime.t()) :: :ok
  def record(harness, name, result, observed_at), do: record(harness, name, result, observed_at, :fresh)

  @spec record(String.t(), String.t(), term(), DateTime.t(), :fresh | :cached) :: :ok
  def record(harness, name, result, observed_at, freshness) do
    previous = Map.get(snapshot(), {harness, name}, %{})
    entry = entry(result, observed_at, freshness, previous)

    :persistent_term.put(@key, Map.put(snapshot(), {harness, name}, entry))
    :ok
  end

  # Only a fresh read is a new observation, so only it ends a failure streak.
  # A cached read re-serves the last good value, usually because the endpoint
  # just refused (#5747), so it keeps the error that made it cached.
  defp entry({:ok, reading}, observed_at, :fresh, _previous),
    do: %{reading: reading, observed_at: observed_at, freshness: :fresh, reason: nil, consecutive_failures: 0}

  defp entry({:ok, reading}, observed_at, freshness, previous) do
    %{reading: reading, observed_at: observed_at, freshness: freshness, reason: Map.get(previous, :reason), consecutive_failures: Map.get(previous, :consecutive_failures, 0)}
  end

  # A failure carries no reading, but remembers when the account was last
  # actually observed so its age stays visible.
  defp entry({:error, reason}, observed_at, _freshness, previous) do
    %{
      reading: nil,
      observed_at: observed_at,
      freshness: :unavailable,
      reason: reason,
      consecutive_failures: Map.get(previous, :consecutive_failures, 0) + 1,
      last_observed_at: last_observed_at(previous)
    }
  end

  defp last_observed_at(%{reading: reading, observed_at: observed_at}) when not is_nil(reading), do: observed_at
  defp last_observed_at(previous), do: Map.get(previous, :last_observed_at)
end
