defmodule Aiur.DecisionStore.Siblings do
  @moduledoc false
  # A rejected Command voids the other open questions in its `group:` on the
  # same ticket. Only `:open`/`:deferred` siblings are mooted, so a decided
  # (and possibly delivered) sibling keeps its answer.
  #
  # A ticket also holds at most one open question for its creator: a new
  # creator Command moots the ticket's older open creator Commands, so the
  # creator answers the question the worker is asking now, not one it has
  # already replaced.

  require Logger

  alias Aiur.Commands.Tags
  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionStore.Persistence

  # A host rejection is recorded as an answer flagged `rejected`.
  @spec moot_if_rejected(map(), Decision.t(), DecisionAnswer.t()) :: map()
  def moot_if_rejected(state, decision, %DecisionAnswer{rejected: true}), do: moot_after_rejection(state, decision)
  def moot_if_rejected(state, _decision, _answer), do: state

  @spec moot_after_rejection(map(), Decision.t()) :: map()
  def moot_after_rejection(state, %Decision{} = rejected) do
    case Tags.group(rejected.tags) do
      nil -> state
      group -> state.current |> Map.values() |> Enum.filter(&sibling?(&1, rejected, group)) |> Enum.reduce(state, &moot(&2, &1, rejected))
    end
  end

  @spec supersede_creator_questions(map(), Decision.t()) :: map()
  def supersede_creator_questions(state, %Decision{} = newer) do
    if creator_question?(newer) do
      state.current |> Map.values() |> Enum.filter(&replaced_by?(&1, newer)) |> Enum.reduce(state, &supersede(&2, &1, newer))
    else
      state
    end
  end

  # Native questions each need their own reply and legacy attentions follow
  # their slug's lifecycle, so neither is folded into the latest question.
  defp creator_question?(%Decision{ticket: %{identifier: "executor"}}), do: false
  defp creator_question?(%Decision{kind: "native_question"}), do: false
  defp creator_question?(%Decision{legacy_attention: %{}}), do: false
  defp creator_question?(%Decision{audience: :executor}), do: false
  defp creator_question?(%Decision{audience: audience, authority: authority}), do: audience == :creator or authority == :human_required

  # Commands sharing a `group:` tag are asked together on purpose.
  defp replaced_by?(candidate, newer) do
    candidate.decision_id != newer.decision_id and candidate.decision_status in [:open, :deferred] and is_nil(candidate.answer) and
      candidate.ticket.identifier == newer.ticket.identifier and creator_question?(candidate) and not same_group?(candidate, newer)
  end

  defp same_group?(candidate, newer) do
    group = Tags.group(newer.tags)
    group != nil and group in candidate.tags
  end

  defp supersede(state, older, newer) do
    data = %{
      reason_class: "superseded",
      detail: "Replaced by #{newer.decision_id}.",
      actor: %{kind: :system, id: "superseded-by:#{newer.decision_id}"}
    }

    persist_moot(state, older, data)
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

    persist_moot(state, sibling, data)
  end

  defp persist_moot(state, decision, data) do
    case Persistence.build_and_persist_event(:decision_mooted, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, _updated} ->
        next_state

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=sibling_moot_failed decision_id=#{decision.decision_id} reason=#{inspect(reason)}")
        Persistence.journal_failure_state(state, reason)
    end
  end
end
