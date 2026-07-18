defmodule Aiur.CurrentRunProjection.Value do
  @moduledoc false

  @freshness_states [:fresh, :stale, :unknown, :unavailable, :partial]

  @spec get(term(), atom(), term()) :: term()
  def get(value, key, default \\ %{})

  def get(value, key, default) when is_map(value) do
    Map.get(value, key, Map.get(value, Atom.to_string(key), default))
  end

  def get(_value, _key, default), do: default

  @spec health(term()) :: :healthy | :degraded | :unavailable
  def health(status) when status in [:healthy, :available, :writable], do: :healthy
  def health(status) when status in [:degraded, :stale, :partial, :unknown], do: :degraded
  def health({:degraded, _reason}), do: :degraded
  def health({:corrupt, _line, _reason}), do: :degraded
  def health({:unavailable, _reason}), do: :unavailable
  def health(%{status: status}), do: health(status)
  def health(_status), do: :unavailable

  @spec freshness(term()) :: :fresh | :stale | :unknown | :unavailable | :partial
  def freshness(%{status: status}), do: freshness(status)
  def freshness(status) when status in @freshness_states, do: status
  def freshness(_status), do: :unknown

  @spec worse_freshness([term()]) :: :fresh | :stale | :unknown | :unavailable | :partial
  def worse_freshness(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(&freshness/1)
    |> Enum.min_by(&freshness_rank/1, fn -> :unknown end)
  end

  defp freshness_rank(:unavailable), do: 0
  defp freshness_rank(:stale), do: 1
  defp freshness_rank(:unknown), do: 2
  defp freshness_rank(:partial), do: 3
  defp freshness_rank(:fresh), do: 4
end
