defmodule AiurWeb.Build.HistoryCarry do
  @moduledoc "A failed history refresh keeps the last good history, marked stale at that read's time (#4916)."
  alias Aiur.BuildOrder.ProviderHealth

  @doc "Returns the parts to publish and the last good history read time (ms)."
  @spec carry(map(), map(), MapSet.t() | :all, integer() | nil, integer()) :: {map(), integer() | nil}
  def carry(old, new, keys, read_at, now) do
    cond do
      keys != :all and not MapSet.member?(keys, :history) -> {new, read_at}
      good?(new) -> {new, now}
      good?(old) and failure(new) != nil -> {stale(old, new, read_at), read_at}
      true -> {new, read_at}
    end
  end

  # A store that reports itself unavailable is a real state, not a failed read: only healthy or stale history carries.
  defp good?(%{history: {:ok, %{health: %ProviderHealth{state: s}}}, health: %ProviderHealth{state: s2}}),
    do: s in [:healthy, :stale] and s2 in [:healthy, :stale]

  defp good?(_parts), do: false

  # Only a read that raised, exited or timed out carries; `{:error, %ProviderHealth{}}` is the store's own verdict.
  defp failure(parts) do
    Enum.find_value([parts[:history], parts[:health]], fn
      {:error, reason} when is_atom(reason) -> reason
      _ -> nil
    end)
  end

  defp stale(old, new, read_at) do
    at = if is_integer(read_at), do: DateTime.from_unix!(read_at, :millisecond)
    mark = &%{&1 | state: :stale, failure: failure(new), observed_at: at}
    {:ok, snapshot} = old.history
    Map.merge(new, %{history: {:ok, %{snapshot | health: mark.(snapshot.health)}}, health: mark.(old.health)})
  end
end
