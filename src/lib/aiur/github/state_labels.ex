defmodule Aiur.GitHub.StateLabels do
  @moduledoc false

  alias Aiur.GitHub.StatePolicy

  @known_states ~w(todo in-progress rework ci-wait human-review error done cancelled canceled merging)

  @spec foreign_candidate_state_label?([String.t()], String.t(), MapSet.t()) :: boolean()
  def foreign_candidate_state_label?(labels, prefix, active_states) do
    states = MapSet.union(active_states, MapSet.new(@known_states))
    foreign_state_label?(labels, prefix, MapSet.to_list(states))
  end

  @spec filter_candidate_repair_labels([Aiur.Issue.t()], String.t(), MapSet.t()) :: [Aiur.Issue.t()]
  def filter_candidate_repair_labels(issues, prefix, active_states) do
    Enum.reject(issues, fn issue ->
      foreign_candidate_state_label?(issue.labels, prefix, active_states) or
        not (issue.state_labels == [] or match?([_, _ | _], issue.state_labels) or
               issue.state in ~w(ci-wait human-review error))
    end)
  end

  @spec foreign_state_label?([String.t()], String.t(), [String.t()]) :: boolean()
  def foreign_state_label?(labels, prefix, states) do
    state_slugs = MapSet.new(states, &StatePolicy.normalize_state/1)
    normalized_prefix = prefix |> String.trim() |> String.downcase()

    Enum.any?(labels, fn label ->
      case label |> String.trim() |> String.downcase() |> String.split(":", parts: 2) do
        [other_prefix, state] ->
          other_prefix != normalized_prefix and
            MapSet.member?(state_slugs, StatePolicy.normalize_state(state))

        _other ->
          false
      end
    end)
  end
end
