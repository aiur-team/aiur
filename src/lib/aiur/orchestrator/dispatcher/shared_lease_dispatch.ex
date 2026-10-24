defmodule Aiur.Orchestrator.Dispatcher.SharedLeaseDispatch do
  @moduledoc false

  require Logger

  alias Aiur.Alerts
  alias Aiur.CodingAgent
  alias Aiur.Handoff
  alias Aiur.Instance.DispatchClaim
  alias Aiur.Instance.LeaseStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.Dispatcher.Candidates
  alias Aiur.Orchestrator.OptimisticDispatch
  alias Aiur.Orchestrator.State

  @spec dispatch(State.t(), Issue.t(), term(), term(), keyword(), function()) :: State.t()
  def dispatch(state, issue, attempt, worker_host, opts, dispatch_to_worker) do
    case prepare_for_dispatch(state, issue, opts) do
      {:ready, prepared_state, selected_issue} ->
        ready_dispatch(state, issue, prepared_state, selected_issue, attempt, worker_host, opts, dispatch_to_worker)

      {:hold, held_state} ->
        held_state

      {:declined, declined_state} ->
        declined_state
    end
  end

  defp ready_dispatch(state, issue, prepared_state, selected_issue, attempt, worker_host, opts, dispatch_to_worker) do
    dispatch = fn ->
      dispatch_after_workspace_wait_or_thrash_check(
        prepared_state,
        selected_issue,
        attempt,
        worker_host,
        opts,
        dispatch_to_worker
      )
    end

    if is_binary(issue.pr_head_ref),
      do: dispatch.(),
      else: dispatch_with_shared_lease(state, issue, selected_issue, dispatch, opts)
  end

  defp dispatch_with_shared_lease(state, issue, selected_issue, dispatch, opts) do
    claim_fun = Keyword.get(opts, :lease_claim_fun, &LeaseStore.claim/1)

    case DispatchClaim.call(selected_issue, dispatch, claim_fun: claim_fun) do
      {:ok, :disabled, next_state} ->
        next_state

      {:ok, :acquired, next_state} ->
        release_if_unstarted(next_state, selected_issue, opts)

      {:error, :shared_lease_held} ->
        Candidates.emit_dispatch_attempt_decline(state, issue, :shared_lease_held, false)

      {:error, {:shared_lease_unavailable, reason}} ->
        Logger.warning("Shared ticket lease unavailable for #{State.issue_context(issue)}: #{inspect(reason)}; holding dispatch")

        Candidates.emit_dispatch_attempt_decline(state, issue, :shared_lease_unavailable, true)
    end
  end

  defp release_if_unstarted(state, issue, opts) do
    if MapSet.member?(state.claimed, issue.id) do
      state
    else
      release_fun = Keyword.get(opts, :lease_release_fun, &LeaseStore.release/1)
      _ = release_fun.(issue)
      state
    end
  end

  defp prepare_for_dispatch(state, issue, opts) do
    with false <- Handoff.dispatch_held?(),
         {:ok, prepared} <- OptimisticDispatch.prepare_for_dispatch(issue, opts),
         {:ok, selected_issue} <- CodingAgent.select_for_dispatch(prepared) do
      state = %{
        state
        | model_fallback_waiting: MapSet.delete(state.model_fallback_waiting, selected_issue.id)
      }

      {:ready, state, selected_issue}
    else
      true ->
        {:hold, state}

      {:error, reason} ->
        {:declined, Candidates.emit_dispatch_attempt_decline(state, issue, reason, false)}

      {:all_limited, candidates} ->
        if MapSet.member?(state.model_fallback_waiting, issue.id) do
          {:hold, state}
        else
          Alerts.emit_system("ticket.#{issue.identifier}.agent.model_fallback_waiting",
            issue: issue.identifier,
            reason: "All configured fallback backends are usage-limited: #{Enum.join(candidates, ", ")}. Waiting for a reset before retrying.",
            needs_attention: true,
            severity: "warning"
          )

          {:hold, %{state | model_fallback_waiting: MapSet.put(state.model_fallback_waiting, issue.id)}}
        end
    end
  end

  defp dispatch_after_workspace_wait_or_thrash_check(
         state,
         issue,
         attempt,
         worker_host,
         opts,
         dispatch_to_worker
       ) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership

    case Map.pop(workspace_ownership.ready, issue.id) do
      {nil, _ready} ->
        case Budgets.check_thrash_budget(state, issue.id, System.monotonic_time(:millisecond)) do
          {:trip, tripped_state} ->
            BudgetTrip.trip_thrash_breaker(tripped_state, issue)

          {:ok, budgeted_state} ->
            dispatch_to_worker.(budgeted_state, issue, attempt, worker_host, opts)
        end

      {envelope, ready} ->
        workspace_ownership = %{workspace_ownership | ready: ready}
        state = put_in(state.dispatch_recovery.workspace_ownership, workspace_ownership)
        envelope_attempt = Map.get(envelope, :retry_attempt, attempt) || attempt
        envelope_host = Map.get(envelope, :worker_host, worker_host) || worker_host

        envelope_opts =
          Keyword.put(opts, :prior_work, Map.get(envelope, :prior_work, Keyword.get(opts, :prior_work, false)))

        dispatch_to_worker.(state, issue, envelope_attempt, envelope_host, envelope_opts)
    end
  end
end
