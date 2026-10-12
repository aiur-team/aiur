defmodule Aiur.Accounts.UsageReadings do
  @moduledoc "Small read model for per-account provider usage observations."

  @key {__MODULE__, :readings}

  @spec snapshot() :: %{{String.t(), String.t()} => map()}
  def snapshot, do: :persistent_term.get(@key, %{})

  @spec reset() :: :ok
  def reset, do: :persistent_term.erase(@key) && :ok

  @spec snapshot(String.t(), [String.t()]) :: %{{String.t(), String.t()} => map()}
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
    entry =
      case result do
        {:ok, reading} -> %{reading: reading, observed_at: observed_at, freshness: freshness, reason: nil}
        {:error, reason} -> %{reading: nil, observed_at: observed_at, freshness: :unavailable, reason: reason}
      end

    :persistent_term.put(@key, Map.put(snapshot(), {harness, name}, entry))
    :ok
  end
end
