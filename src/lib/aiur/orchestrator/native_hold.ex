defmodule Aiur.Orchestrator.NativeHold do
  @moduledoc false

  @spec integrate(map(), map()) :: map()
  def integrate(entry, %{event: :native_question_held, native_ref: ref, decision_id: id, since: since}) do
    holds = Map.put(Map.get(entry, :native_holds, %{}), ref, %{decision_id: id, since: since})
    entry |> Map.put(:native_holds, holds) |> Map.put(:native_hold, holds[ref])
  end

  def integrate(entry, %{event: :native_question_resolved, native_ref: ref}) do
    holds = Map.delete(Map.get(entry, :native_holds, %{}), ref)
    entry |> Map.put(:native_holds, holds) |> Map.put(:native_hold, holds |> Map.values() |> List.first())
  end

  def integrate(entry, _update), do: entry
end
