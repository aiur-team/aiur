defmodule Aiur.BuildOrder.Features.Reads do
  @moduledoc false

  @spec read(term(), map()) :: term()
  def read(_query, %{health: %{state: state} = health}) when state not in [:healthy, :stale], do: {:error, health}

  def read(:snapshot, state) do
    projection = Map.take(state.projection, [:features, :owners])
    also = Map.new(state.projection.also, fn {number, slugs} -> {number, Enum.sort(slugs)} end)
    {:ok, Map.merge(projection, %{also: also, generation: state.health.generation, health: state.health})}
  end

  def read({:owner, number}, state) do
    case Map.fetch(state.projection.owners, number) do
      {:ok, owner} -> {:ok, Map.put(owner, :added?, added?(number, state.projection.features[owner.feature]))}
      :error -> :none
    end
  end

  def read(:memberships, state) do
    {:ok, state.projection.owners |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {n, owner} -> owner |> Map.put(:number, n) |> Map.put(:slug, owner.feature) end)}
  end

  def read({:journal, slug}, state), do: {:ok, Enum.filter(state.projection.events, &(&1.feature == slug))}

  @spec changed([map()], map()) :: map()
  def changed(events, state) do
    pairs = events |> Enum.filter(&Map.has_key?(&1, :number)) |> Enum.map(&{&1.feature, &1.number}) |> Enum.uniq() |> Enum.sort()

    %{
      generation: state.health.generation,
      changed: pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      slugs: events |> Enum.map(& &1.feature) |> Enum.uniq() |> Enum.sort(),
      pairs: pairs
    }
  end

  defp added?(_number, %{baseline: :none}), do: false
  defp added?(number, %{baseline: %{members: members}}), do: not MapSet.member?(members, number)
end
