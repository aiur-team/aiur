defmodule Aiur.Orchestrator.Dispatcher.SharedLeaseDispatch do
  @moduledoc false

  require Logger

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.{CapacityGate, UsageFloorGate}
  alias Aiur.Handoff
  alias Aiur.Instance
  alias Aiur.Instance.DispatchClaim
  alias Aiur.Instance.Identity
  alias Aiur.Instance.LeaseStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.Dispatcher.Candidates
  alias Aiur.Orchestrator.HostedModeCheck
  alias Aiur.Orchestrator.OptimisticDispatch
  alias Aiur.Orchestrator.State
  alias Aiur.Ownership.Fence
  alias Aiur.Signal
  alias Aiur.Toolchain

  @spec dispatch(State.t(), Issue.t(), term(), term(), keyword(), function()) :: State.t()
  def dispatch(state, issue, attempt, worker_host, opts, dispatch_to_worker) do
    case prepare_for_dispatch(state, issue, opts) do
      {:ready, prepared_state, selected_issue} ->
        ready_dispatch(
          state,
          issue,
          prepared_state,
          selected_issue,
          attempt,
          worker_host,
          opts,
          dispatch_to_worker
        )

      {:hold, held_state} ->
        held_state

      {:declined, declined_state} ->
        declined_state
    end
  end

  defp ready_dispatch(
         state,
         issue,
         prepared_state,
         selected_issue,
         attempt,
         worker_host,
         opts,
         dispatch_to_worker
       ) do
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

    case ownership_eligibility(selected_issue, opts) do
      :eligible ->
        # Capacity asks first and has no side effects (Executor decision on #7639): a
        # denied ticket makes no ownership reads or writes. MPG-402's
        # GatewayDemand.admit/2 replaces this default seam when it lands.
        admit = Keyword.get(opts, :capacity_admit_fun, fn _ -> :admit end)

        with :admit <- admit.(selected_issue),
             owned when owned == :disabled or elem(owned, 0) == :ok <-
               Aiur.Ownership.ensure_owned(selected_issue, opts) do
          register_fence(selected_issue, owned)
          dispatch_with_shared_lease(state, issue, selected_issue, dispatch, opts)
        else
          {:deny, reason} ->
            Candidates.emit_dispatch_attempt_decline(state, issue, {:capacity_denied, reason}, false)

          {:declined, :not_owner, _} ->
            Candidates.emit_dispatch_attempt_decline(state, issue, :ownership_not_owner, false)

          {:declined, :ambiguous, _} ->
            Candidates.emit_dispatch_attempt_decline(state, issue, :ownership_ambiguous, false)

          {:declined, :unknown, why} ->
            Logger.warning("Ownership unknown (#{inspect(why)}) for #{State.issue_context(issue)}; holding dispatch")
            Candidates.emit_dispatch_attempt_decline(state, issue, :ownership_unknown, true)
        end

      {:ineligible, _reason} ->
        Candidates.emit_dispatch_attempt_decline(state, issue, :instance_not_owner, false)

      {:unavailable, reason} ->
        Logger.warning("Instance ownership unavailable (#{reason}) for #{State.issue_context(issue)}; holding dispatch")

        Candidates.emit_dispatch_attempt_decline(
          state,
          issue,
          :instance_ownership_unavailable,
          true
        )
    end
  end

  defp register_fence(issue, {:ok, record}), do: Fence.register(issue, record)
  defp register_fence(_issue, :disabled), do: :ok

  defp ownership_eligibility(issue, opts) do
    live_instances_fun = Keyword.get(opts, :ownership_live_instances_fun, &LeaseStore.list_live/0)

    case live_instances_fun.() do
      {:ok, live_instances} when is_list(live_instances) ->
        instance_id = Keyword.get_lazy(opts, :ownership_instance_id, &Identity.current/0)

        issue
        |> Instance.eligible?(instance_id, live_instances)
        |> recheck_peer_owner(issue, instance_id, live_instances, opts)

      {:error, :store_not_configured} ->
        if not ownership_on?(opts) and Instance.ownership_configured?(),
          do: {:unavailable, :store_not_configured},
          else: :eligible

      _ ->
        roster_unreadable(opts)
    end
  rescue
    _ -> roster_unreadable(opts)
  end

  # A peer's owns-rule must not beat a durable claim this gateway holds.
  defp recheck_peer_owner({:ineligible, :peer_owns_ticket} = peer, issue, id, live, opts) do
    if ownership_on?(opts),
      do: Instance.eligible?(issue, id, live, Aiur.Ownership.owner(issue, opts)),
      else: peer
  end

  defp recheck_peer_owner(other, _issue, _id, _live, _opts), do: other

  # Under durable ownership the roster is advisory: the GitHub claim decides.
  defp roster_unreadable(opts), do: if(ownership_on?(opts), do: :eligible, else: {:unavailable, :live_roster_unknown})

  defp ownership_on?(opts), do: Keyword.get_lazy(opts, :ownership_enabled, &Aiur.Ownership.enabled?/0)

  defp dispatch_with_shared_lease(state, issue, selected_issue, dispatch, opts) do
    claim_fun = Keyword.get(opts, :lease_claim_fun, &LeaseStore.claim/1)

    case DispatchClaim.call(selected_issue, dispatch,
           claim_fun: claim_fun,
           degrade_on_store_error: ownership_on?(opts)
         ) do
      {:ok, status, next_state} when status in [:disabled, :degraded] ->
        next_state

      {:ok, :acquired, next_state} ->
        release_if_unstarted(next_state, selected_issue, opts)

      {:error, :shared_lease_held} ->
        Fence.unregister(selected_issue.identifier)
        Candidates.emit_dispatch_attempt_decline(state, issue, :shared_lease_held, false)

      {:error, {:shared_lease_unavailable, reason}} ->
        Fence.unregister(selected_issue.identifier)
        Logger.warning("Shared ticket lease unavailable for #{State.issue_context(issue)}: #{inspect(reason)}; holding dispatch")

        Candidates.emit_dispatch_attempt_decline(state, issue, :shared_lease_unavailable, true)
    end
  end

  defp release_if_unstarted(state, issue, opts) do
    if MapSet.member?(state.claimed, issue.id) do
      state
    else
      Fence.unregister(issue.identifier)
      release_fun = Keyword.get(opts, :lease_release_fun, &LeaseStore.release/1)
      _ = release_fun.(issue)
      state
    end
  end

  # A hold at the usage floor is not an exhausted provider, and the operator
  # who set the floor needs the difference in the alert text (#7504).
  defp all_limited_reason(candidates) do
    case UsageFloorGate.hold_reason(candidates) do
      nil ->
        "All configured fallback backends are usage-limited: #{Enum.join(candidates, ", ")}. Waiting for a reset before retrying."

      floor_reason ->
        "Dispatch held: #{floor_reason}. It clears when a rate window resets; no running agent is affected."
    end
  end

  defp prepare_for_dispatch(state, issue, opts) do
    with false <- Handoff.dispatch_held?(),
         {:ok, prepared} <- OptimisticDispatch.prepare_for_dispatch(issue, opts),
         :ok <- HostedModeCheck.validate_configured_dispatch(prepared, opts),
         {:ok, selected_issue} <-
           Toolchain.select_for_dispatch(force_backend(prepared, Keyword.get(opts, :forced_backend))) do
      # Hold at selection, before the next claim reads the reserve (#7890).
      CapacityGate.hold(selected_issue)

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
          Signal.alert("ticket.#{issue.identifier}.agent.model_fallback_waiting",
            issue: issue.identifier,
            reason: all_limited_reason(candidates),
            needs_attention: true,
            severity: "warning"
          )

          {:hold, %{state | model_fallback_waiting: MapSet.put(state.model_fallback_waiting, issue.id)}}
        end
    end
  end

  defp force_backend(issue, nil), do: issue

  defp force_backend(issue, backend) when is_binary(backend) do
    labels =
      Enum.reject(issue.labels, fn label ->
        spec = label |> to_string() |> String.downcase() |> String.replace_prefix("model:", "")

        spec in CodingAgent.known_backends() or
          Enum.any?(CodingAgent.known_backends(), &String.starts_with?(spec, &1 <> "-"))
      end)

    %{issue | labels: labels ++ ["model:#{backend}"]}
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
          Keyword.put(
            opts,
            :prior_work,
            Map.get(envelope, :prior_work, Keyword.get(opts, :prior_work, false))
          )
          |> Keyword.put(
            :forced_backend,
            Map.get(envelope, :forced_backend, Keyword.get(opts, :forced_backend))
          )
          |> Keyword.put(
            :stalled_alert_outstanding,
            Map.get(
              envelope,
              :stalled_alert_outstanding,
              Keyword.get(opts, :stalled_alert_outstanding, false)
            )
          )
          |> Keyword.put(
            :workspace_path,
            Map.get(envelope, :workspace_path, Keyword.get(opts, :workspace_path))
          )
          |> Keyword.put(
            :redispatch_safety,
            Map.get(envelope, :redispatch_safety, Keyword.get(opts, :redispatch_safety))
          )

        dispatch_to_worker.(state, issue, envelope_attempt, envelope_host, envelope_opts)
    end
  end
end
