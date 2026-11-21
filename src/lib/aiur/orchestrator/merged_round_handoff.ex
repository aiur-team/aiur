defmodule Aiur.Orchestrator.MergedRoundHandoff do
  @moduledoc false

  # A round whose PR merged leaves no open PR for the review-findings read, yet a
  # worker waiting on the creator's verdict belongs in human-review (#644).
  # `ReworkHandoffGuard` reaches it through `config :aiur, :merged_round_handoff_check`.
  alias Aiur.{Commands, RecentMergeStore}

  @spec allow?(String.t() | integer(), keyword()) :: boolean()
  def allow?(identifier, opts) do
    identifier = to_string(identifier)
    merged?(identifier, opts) and open_creator_command?(identifier, opts)
  end

  defp merged?(identifier, opts) do
    merges = read(Keyword.get(opts, :recent_merges_fun, &RecentMergeStore.list/0))
    Enum.any?(merges, &(Map.get(&1, :ticket_id) == identifier))
  end

  defp open_creator_command?(identifier, opts) do
    decisions = read(Keyword.get(opts, :decisions_fun, &Commands.list_decisions/0))
    Enum.any?(decisions, &creator_command?(&1, identifier))
  end

  # Executor-audience Commands never reach the creator, and a legacy attention only raises visibility.
  defp creator_command?(%{ticket: %{identifier: identifier}, decision_status: status} = decision, identifier) when status in [:open, :deferred] do
    audience = Map.get(decision, :audience)

    is_nil(Map.get(decision, :legacy_attention)) and
      (audience == :creator or (audience != :executor and Map.get(decision, :authority) == :human_required))
  end

  defp creator_command?(_decision, _identifier), do: false

  defp read(fun) do
    fun.()
  catch
    :exit, _reason -> []
  end
end
