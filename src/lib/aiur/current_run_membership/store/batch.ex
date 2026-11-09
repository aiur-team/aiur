defmodule Aiur.CurrentRunMembership.Store.Batch do
  @moduledoc false

  alias Aiur.CurrentRunMembership.{Event, Projection}
  alias Aiur.CurrentRunMembership.Store.Runtime

  @spec observe(list(), DateTime.t(), atom(), map()) :: {:reply, term(), map()}
  def observe(_observations, _at, _source, %{writable?: false} = state),
    do: {:reply, {:error, {:membership_unavailable, state.health}}, state}

  def observe(observations, at, source, state) do
    case prepare(observations, at, source, state) do
      {:ok, [], _projection} ->
        {:reply, {:ok, %{status: :unchanged, generation: state.projection.generation}}, state}

      {:ok, events, projection} ->
        Runtime.persist_batch(events, projection, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp prepare(observations, at, source, state) do
    Enum.reduce_while(observations, {:ok, [], state.projection}, fn {identity, lifecycle}, {:ok, events, projection} ->
      case Event.new(state.run_id, identity, lifecycle, at, source: source) do
        {:ok, event} -> {:cont, apply_event(event, events, projection)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> ordered_events()
  end

  defp apply_event(event, events, projection) do
    case Projection.apply(projection, event) do
      {:accepted, next} -> {:ok, [event | events], next}
      {:ignored, _reason, next} -> {:ok, events, next}
    end
  end

  defp ordered_events({:ok, events, projection}), do: {:ok, Enum.reverse(events), projection}
  defp ordered_events(error), do: error
end
