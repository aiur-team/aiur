defmodule Aiur.GitHub.MergeQueue do
  @moduledoc """
  Classifies whether an observed pull request is silently parked outside the
  merge queue and normalizes the GraphQL fields that drive that decision.

  GitHub's `mergeStateStatus` describes branch-protection and queue state;
  `BLOCKED` does not mean the pull request has merge conflicts. A freshly
  readied pull request can report `BLOCKED` until the merge queue re-evaluates
  it — that is what made the manual recovery on #1691/#1702 look like it had
  failed. Conflict eligibility therefore comes from `mergeable`, while
  `mergeStateStatus` is observed but deliberately ignored.

  A pull request is recoverable (`:unarmed`) when it is ready, approved,
  conflict-free, and holds no auto-merge request or merge-queue entry — the
  state the daemon surfaces as a parked-ready silent-parking alert.
  """

  @type recovery_state :: :unarmed | :armed | :queued | :ineligible | :unknown
  @type observation :: %{
          draft?: boolean(),
          review_decision: String.t() | nil,
          mergeable: String.t(),
          merge_state_status: String.t(),
          auto_merge_request: map() | nil,
          merge_queue_entry: map() | nil
        }

  @required_keys [:draft?, :review_decision, :mergeable, :auto_merge_request, :merge_queue_entry]
  @graphql_fields [
    draft?: "isDraft",
    review_decision: "reviewDecision",
    mergeable: "mergeable",
    merge_state_status: "mergeStateStatus",
    auto_merge_request: "autoMergeRequest",
    merge_queue_entry: "mergeQueueEntry"
  ]

  @spec normalize_graphql_pull_request(map() | term()) ::
          observation() | {:error, :incomplete_observation | :invalid_observation}
  def normalize_graphql_pull_request(%{} = pull_request) do
    if Enum.all?(@graphql_fields, fn {_normalized, graphql} -> Map.has_key?(pull_request, graphql) end) do
      Map.new(@graphql_fields, fn {normalized, graphql} ->
        {normalized, Map.fetch!(pull_request, graphql)}
      end)
    else
      {:error, :incomplete_observation}
    end
  end

  def normalize_graphql_pull_request(_pull_request), do: {:error, :invalid_observation}

  @doc """
  Classifies a normalized observation. Fail-closed: any incomplete, ambiguous,
  or malformed observation yields `:unknown` rather than arming or clearing a
  recovery signal on data the poll cannot vouch for.
  """
  @spec recovery_state(map() | term()) :: recovery_state()
  def recovery_state(%{} = observation) do
    cond do
      is_map(Map.get(observation, :auto_merge_request)) -> :armed
      is_map(Map.get(observation, :merge_queue_entry)) -> :queued
      not trustworthy_observation?(observation) -> :unknown
      true -> eligibility_state(observation)
    end
  end

  def recovery_state(_observation), do: :unknown

  # Only an observation that carries every required field, and whose optional
  # arm/queue fields are absent rather than malformed, can be classified. Any
  # other shape falls through to `:unknown` (fail closed).
  defp trustworthy_observation?(observation) do
    complete_observation?(observation) and not malformed_optional_state?(observation)
  end

  # Reached only for a trustworthy, unarmed, unqueued observation: ready plus
  # approved plus conflict-free is the recoverable `:unarmed` state.
  defp eligibility_state(observation) do
    case Map.get(observation, :draft?) do
      true -> :ineligible
      false -> approval_state(observation)
      _malformed -> :unknown
    end
  end

  defp approval_state(observation) do
    if Map.get(observation, :review_decision) == "APPROVED" do
      mergeable_state(observation)
    else
      :ineligible
    end
  end

  # `mergeStateStatus` is deliberately not consulted here (see the moduledoc):
  # `BLOCKED` on a freshly readied pull request is not a merge conflict.
  defp mergeable_state(observation) do
    case Map.get(observation, :mergeable) do
      "MERGEABLE" -> :unarmed
      "CONFLICTING" -> :ineligible
      _unknown -> :unknown
    end
  end

  defp complete_observation?(observation) do
    Enum.all?(@required_keys, &Map.has_key?(observation, &1))
  end

  defp malformed_optional_state?(observation) do
    not is_nil(Map.get(observation, :auto_merge_request)) or
      not is_nil(Map.get(observation, :merge_queue_entry))
  end
end
