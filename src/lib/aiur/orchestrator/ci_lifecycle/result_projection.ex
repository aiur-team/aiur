defmodule Aiur.Orchestrator.CiLifecycle.ResultProjection do
  @moduledoc """
  Projects the last CI result onto running entries and reconciles base-repair invalidations.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.DraftAlertLifecycle
  alias Aiur.Orchestrator.ReadyForReviewTransitions
  alias Aiur.Orchestrator.State

  # Read-only projection of the poll result for OCC-5's fleet-state row (PR
  # number / CI decision), cached by ticket identifier independently of
  # whatever tracker transition (or no-op) the result below triggers — a
  # lifecycle-level cache rather than a field on the running entry so idle rows
  # (no live process, e.g. after the agent's turn ends while still cycling
  # through ci-wait) keep showing the last-known CI/PR state too. Only
  # replaces the cached value when the projection actually changed, so a
  # Redundant head polls preserve running/claimed state and lifecycle markers.
  @doc false
  @spec stash_last_ci_result(State.t(), Issue.t(), term()) :: term()
  def stash_last_ci_result(%State{} = state, %Issue{} = issue, result) do
    case CiLifecycle.ci_target_for_issue(issue) do
      nil ->
        state

      target ->
        poll_cache = Map.get(state.ci_lifecycle, :poll_cache, %{})
        projection = result |> ci_result_projection(Map.get(poll_cache, target)) |> Map.put(:tracker_state, Transition.effective_ci_state(issue))

        if Map.get(poll_cache, target) == projection do
          state
        else
          ci_lifecycle = Map.put(state.ci_lifecycle, :poll_cache, Map.put(poll_cache, target, projection))
          %{state | ci_lifecycle: ci_lifecycle}
        end
    end
  end

  @doc false
  @spec publish_ready_for_review_transition(State.t(), Issue.t(), term()) :: term()
  def publish_ready_for_review_transition(%State{} = state, %Issue{} = issue, result) do
    observation =
      ReadyForReviewTransitions.observation(
        CiLifecycle.ci_target_for_issue(issue),
        Map.get(result, :pr_number),
        Map.get(result, :head_sha),
        Map.get(result, :draft?)
      )

    case observation do
      nil -> state
      observation -> ReadyForReviewTransitions.observe(state, [observation])
    end
  end

  defp ci_result_projection(result, previous) do
    %{
      decision: Map.get(result, :decision),
      pr_number: Map.get(result, :pr_number),
      head_sha: Map.get(result, :head_sha),
      draft?: projection_value(result, previous, :draft?, false) == true,
      review_decision: projection_value(result, previous, :review_decision, nil),
      merge_queue_entry: projection_value(result, previous, :merge_queue_entry, get_in(previous, [:merge_queue, :merge_queue_entry])),
      auto_merge_request: projection_value(result, previous, :auto_merge_request, get_in(previous, [:merge_queue, :auto_merge_request])),
      merge_queue: projection_value(result, previous, :merge_queue, nil),
      recovery: if(result[:decision] == :pending and result[:head_sha] == get_in(previous, [:head_sha]), do: projection_value(result, previous, :recovery, nil), else: result[:recovery]),
      failures: Map.get(result, :failures, [])
    }
    |> DraftAlertLifecycle.keep_pending_reason(result)
  end

  defp projection_value(result, previous, key, default) do
    cond do
      Map.has_key?(result, key) -> Map.get(result, key)
      Map.get(result, :pending_reason) == :open_pr_no_longer_visible -> default
      is_map(previous) -> Map.get(previous, key, default)
      true -> default
    end
  end

  @doc false
  @spec reconcile_base_repair_invalidation(State.t(), Issue.t(), term()) :: term()
  def reconcile_base_repair_invalidation(
        %State{} = state,
        %Issue{} = issue,
        %{
          base_repair_invalidation: %{head_sha: head_sha, repaired_at: repaired_at} = invalidation
        }
      )
      when is_binary(head_sha) and is_integer(repaired_at) do
    update_base_repair_invalidation(state, issue, invalidation)
  end

  def reconcile_base_repair_invalidation(%State{} = state, %Issue{} = issue, result) do
    target = CiLifecycle.ci_target_for_issue(issue)
    invalidations = Map.get(state.ci_lifecycle, :base_repair_invalidations, %{})

    case Map.get(invalidations, target) do
      %{repair_state: :repairing} ->
        reconcile_repairing_invalidation(state, issue, result)

      %{"repair_state" => "repairing"} ->
        reconcile_repairing_invalidation(state, issue, result)

      %{head_sha: invalidated_head} when is_binary(invalidated_head) ->
        reconcile_repaired_invalidation(state, issue, result, invalidated_head)

      _ ->
        state
    end
  end

  defp reconcile_repairing_invalidation(state, issue, %{base_repair_revalidated: true}),
    do: update_base_repair_invalidation(state, issue, nil)

  defp reconcile_repairing_invalidation(state, _issue, _result), do: state

  defp reconcile_repaired_invalidation(state, issue, result, invalidated_head) do
    if base_repair_finished?(result, invalidated_head),
      do: update_base_repair_invalidation(state, issue, nil),
      else: state
  end

  defp base_repair_finished?(%{base_repair_revalidated: true}, _invalidated_head), do: true

  defp base_repair_finished?(%{head_sha: observed_head}, invalidated_head)
       when is_binary(observed_head),
       do: observed_head != invalidated_head

  defp base_repair_finished?(_result, _invalidated_head), do: false

  defp update_base_repair_invalidation(%State{} = state, %Issue{} = issue, invalidation) do
    case CiLifecycle.ci_target_for_issue(issue) do
      target when is_binary(target) ->
        invalidations = Map.get(state.ci_lifecycle, :base_repair_invalidations, %{})

        next_invalidations =
          if is_map(invalidation),
            do: Map.put(invalidations, target, invalidation),
            else: Map.delete(invalidations, target)

        if next_invalidations == invalidations do
          state
        else
          ci_lifecycle = Map.put(state.ci_lifecycle, :base_repair_invalidations, next_invalidations)
          CiLifecycle.persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})
        end

      _ ->
        state
    end
  end
end
