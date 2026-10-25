defmodule Aiur.Orchestrator.OptimisticEvents do
  @moduledoc "Routes optimistic integration reports and blocker push observations to the durable ledger."
  alias Aiur.Orchestrator.{OptimisticLedger, PushRouting, State}

  @spec integrated(State.t(), String.t(), map()) :: State.t()
  def integrated(state, identifier, event) do
    report(state, identifier, event, Map.get(event, :payload) || event)
  end

  defp report(state, identifier, event, payload) when is_map(payload) do
    blocker = value(payload, :blocker)
    sha = value(payload, :sha)
    conflict = value(payload, :conflict)
    non_ff = value(payload, :non_ff)

    if event[:source] == :agent and Map.get(event, "issue") == identifier and
         (is_binary(blocker) or is_integer(blocker)) and valid_sha?(sha) and
         is_boolean(conflict) and is_boolean(non_ff) do
      OptimisticLedger.record_integration(identifier, to_string(blocker), String.downcase(sha), conflict, non_ff)
    end

    state
  end

  defp report(state, _identifier, _event, _payload), do: state

  @spec merged(State.t(), String.t(), map()) :: State.t()
  def merged(state, blocker, event) do
    with pr when is_map(pr) <- value(event, :pr),
         timestamp when is_binary(timestamp) <- value(pr, :merged_at),
         {:ok, merged_at, _offset} <- DateTime.from_iso8601(timestamp) do
      OptimisticLedger.record_blocker_merge(blocker, DateTime.to_unix(merged_at, :millisecond))
    end

    state
  end

  @spec pushed(State.t(), String.t(), map()) :: State.t()
  def pushed(state, blocker, event) do
    with %{sha: sha} <- PushRouting.validated_unblock_metadata(blocker, event),
         {:ok, rows} <- OptimisticLedger.by_blocker(blocker) do
      Enum.each(rows, &OptimisticLedger.record_push(&1["ticket"], blocker, sha))
    end

    state
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/i, sha)
end
