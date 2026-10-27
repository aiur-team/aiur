defmodule Aiur.DecisionStore.CommandFacts do
  @moduledoc false

  alias Aiur.Commands.EventData
  alias Aiur.Commands.Routing.Facts
  alias Aiur.DecisionStore.Persistence

  @spec record(map(), String.t(), atom(), map(), keyword()) :: term()
  def record(state, id, type, data, opts) do
    with true <- type in EventData.fact_types() and type != :request_attributed,
         {:ok, decision} <- Map.fetch(state.current, id),
         {:ok, normalized} <- EventData.normalize(type, data) do
      if Facts.duplicate?(decision, type, normalized) do
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}
      else
        persist(state, decision, type, normalized, Keyword.get(opts, :now, DateTime.utc_now()))
      end
    else
      false -> {:reply, {:error, :unsupported_command_fact}, state}
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist(state, decision, type, data, now) do
    case Persistence.build_and_persist_event(type, decision, data, now, state) do
      {:ok, next, updated} -> {:reply, {:ok, %{status: :accepted, decision: updated}}, next}
      {:error, {:invalid_transition, _reason} = error} -> {:reply, {:error, error}, state}
      {:error, reason} -> {:reply, {:error, {:append_failed, reason}}, Persistence.journal_failure_state(state, reason)}
    end
  end
end
