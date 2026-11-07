defmodule Aiur.DecisionStore.Siblings do
  @moduledoc false
  # A rejected Command voids the other open questions in its `group:` on the
  # same ticket. Only `:open`/`:deferred` siblings are mooted, so a decided
  # (and possibly delivered) sibling keeps its answer.

  require Logger

  alias Aiur.Commands.Tags
  alias Aiur.Decision
  alias Aiur.DecisionStore.Persistence

  # #7779 records a host rejection as an answer flagged `rejected`; Map.get
  # keeps this independent of that field until it lands.
  @spec moot_if_rejected(map(), Decision.t(), map()) :: map()
  def moot_if_rejected(state, decision, answer) do
    if Map.get(answer, :rejected) == true, do: moot_after_rejection(state, decision), else: state
  end

  @spec moot_after_rejection(map(), Decision.t()) :: map()
  def moot_after_rejection(state, %Decision{} = rejected) do
    case Tags.group(rejected.tags) do
      nil -> state
      group -> state.current |> Map.values() |> Enum.filter(&sibling?(&1, rejected, group)) |> Enum.reduce(state, &moot(&2, &1, rejected))
    end
  end

  defp sibling?(candidate, rejected, group) do
    candidate.decision_id != rejected.decision_id and candidate.decision_status in [:open, :deferred] and
      candidate.ticket.identifier == rejected.ticket.identifier and group in candidate.tags
  end

  defp moot(state, sibling, rejected) do
    data = %{
      reason_class: "sibling_rejected",
      detail: "Sibling Command #{rejected.decision_id} was rejected.",
      actor: %{kind: :system, id: "sibling-rejected:#{rejected.decision_id}"}
    }

    case Persistence.build_and_persist_event(:decision_mooted, sibling, data, DateTime.utc_now(), state) do
      {:ok, next_state, _updated} ->
        next_state

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=sibling_moot_failed decision_id=#{sibling.decision_id} reason=#{inspect(reason)}")
        Persistence.journal_failure_state(state, reason)
    end
  end
end
