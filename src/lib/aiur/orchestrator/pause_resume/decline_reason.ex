defmodule Aiur.Orchestrator.PauseResume.DeclineReason do
  @moduledoc """
  Names why a resume or reset was declined.
  """

  alias Aiur.Commands
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OptimisticSlots
  alias Aiur.Orchestrator.QueueSetSlots
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  require Logger

  @doc false
  # Translates a dispatch-policy decline into the operator-facing resume
  # refusal. It must be total over `DispatchPolicy.dispatch_decline_reasons/0`:
  # a missing clause here crashed `aiur resume` with a FunctionClauseError for
  # a ticket held by an open blocking Decision (#2699). The test suite
  # enumerates that list and fails on any reason that reaches the fallback
  # clause; the fallback keeps unforeseen reasons a named refusal, not a crash.
  @spec resume_decline_reason(atom(), Issue.t(), State.t(), keyword()) :: term()
  def resume_decline_reason(reason, issue, state, opts \\ [])

  def resume_decline_reason(:invalid_issue, _issue, _state, _opts), do: :invalid_tracker_issue
  def resume_decline_reason(:contradictory_state_labels, _issue, _state, _opts), do: :contradictory_tracker_state_labels
  def resume_decline_reason(:not_routable, _issue, _state, _opts), do: :not_routable_to_worker
  def resume_decline_reason(:unauthorized, _issue, _state, _opts), do: :dispatch_not_authorized
  def resume_decline_reason(:paused, _issue, _state, _opts), do: :pause_override_still_present
  def resume_decline_reason(:parked, _issue, _state, _opts), do: :ticket_parked
  def resume_decline_reason(:executor_owned, _issue, _state, _opts), do: :ticket_executor_owned

  def resume_decline_reason(reason, issue, _state, _opts)
      when reason in [:inactive_state, :no_agent_work_state, :terminal_state],
      do: {:tracker_state_not_resumable, DispatchPolicy.normalize_issue_state(issue.state)}

  def resume_decline_reason(:dependency, _issue, _state, _opts), do: :waiting_for_dependencies
  def resume_decline_reason(:build_queue_hold, _issue, _state, _opts), do: :build_queue_hold

  # An open blocking Decision holds dispatch until it is answered; an operator
  # resume does not override it, exactly as it does not override a dependency.
  # Name the Decision so the operator knows what to answer.
  def resume_decline_reason(:blocked_on_decision, issue, state, opts),
    do: {:blocked_on_decision, blocking_decision_detail(issue, state, opts)}

  def resume_decline_reason(:already_running, _issue, _state, _opts), do: :already_claimed
  def resume_decline_reason(:auto_resume_pending, _issue, _state, _opts), do: :auto_resume_pending
  def resume_decline_reason(:retry_backoff, _issue, _state, _opts), do: :dispatch_retry_scheduled
  def resume_decline_reason(:model_fallback_waiting, _issue, _state, _opts), do: :all_model_backends_limited
  def resume_decline_reason(:workspace_ownership_waiting, _issue, _state, _opts), do: :workspace_ownership_waiting
  def resume_decline_reason(:claimed_without_runtime, _issue, _state, _opts), do: :already_claimed

  def resume_decline_reason(:state_capacity, issue, _state, _opts), do: {:state_concurrency_limit_reached, DispatchPolicy.normalize_issue_state(issue.state)}

  def resume_decline_reason(:queue_set_order, issue, state, _opts), do: QueueSetSlots.waiting(issue.id, state)
  def resume_decline_reason(:optimistic_share, _issue, state, _opts), do: {:optimistic_share, OptimisticSlots.status(state)}
  def resume_decline_reason(:worker_capacity, _issue, _state, _opts), do: :no_worker_capacity

  def resume_decline_reason(:fleet_capacity, issue, state, _opts),
    do: {:max_concurrent_agents_reached, Slots.fleet_capacity_detail(state, %{issue: issue})}

  def resume_decline_reason(reason, issue, _state, _opts) do
    Logger.warning("Resume declined with an untranslated dispatch reason: issue_id=#{inspect(Map.get(issue || %{}, :id))} reason=#{inspect(reason)}")

    {:unmapped_dispatch_decline, reason}
  end

  # The dispatch gate fails closed when the Decision store could not be read
  # (`blocked_ticket_ids: :unavailable`), so there may be no Decision to name.
  defp blocking_decision_detail(_issue, %State{blocked_ticket_ids: :unavailable}, _opts),
    do: %{decision_ids: [], store: :unavailable}

  defp blocking_decision_detail(issue, _state, opts) do
    lookup = Keyword.get(opts, :decision_lookup, &Commands.open_blocking_decision_ids/1)

    ticket_ids =
      [Map.get(issue, :id), Map.get(issue, :identifier)]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case lookup.(ticket_ids) do
      {:ok, ids} when is_list(ids) -> %{decision_ids: ids, store: :available}
      _unavailable -> %{decision_ids: [], store: :unavailable}
    end
  end
end
