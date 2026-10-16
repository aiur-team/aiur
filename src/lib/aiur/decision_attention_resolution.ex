defmodule Aiur.DecisionAttentionResolution do
  @moduledoc false

  alias Aiur.DecisionStore

  @spec resolve?(map(), map()) :: boolean()
  def resolve?(attention, state) do
    stale_condition?(attention, state) or answered_operator_decision?(attention, state) or owner_status(attention, state) == :owner
  end

  @spec owner_status(map(), map()) :: :owner | :none | :unknown | :not_applicable
  def owner_status(%{slug: "stranded-requeued", issue: %{identifier: identifier}}, %{owner_lookup: lookup})
      when is_function(lookup, 1) do
    case lookup.(identifier) do
      true -> :owner
      false -> :none
      _unknown -> :unknown
    end
  end

  def owner_status(_attention, _state), do: :not_applicable

  defp stale_condition?(%{slug: slug, opened_at: %DateTime{} = opened_at}, state) do
    condition_attention?(slug) and
      DateTime.diff(state.now_fun.(), opened_at, :millisecond) >= state.condition_attention_ttl_ms
  end

  defp stale_condition?(_attention, _state), do: false

  defp answered_operator_decision?(%{slug: "operator-decision", issue: %{identifier: identifier}}, state) do
    state.decision_store
    |> DecisionStore.list()
    |> Enum.all?(fn decision ->
      decision.ticket.identifier != identifier or decision.decision_status not in [:open, :deferred]
    end)
  end

  defp answered_operator_decision?(_attention, _state), do: false

  defp condition_attention?(slug) do
    base_branch = Aiur.Config.base_branch()
    branch_red = "#{base_branch}-red"
    branch_ci_red = "#{base_branch}-ci-red"
    detailed_ci_red_prefix = branch_ci_red <> "-"

    slug in [branch_red, branch_ci_red] or
      (String.starts_with?(slug, detailed_ci_red_prefix) and
         byte_size(slug) > byte_size(detailed_ci_red_prefix))
  end
end
