defmodule Aiur.Orchestrator.RetryEngine.Lookup do
  @moduledoc "Retry issue lookup, terminal verification and dispatch."

  require Logger

  alias Aiur.CurrentRunMembership
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.MembershipLifecycle
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.RetryEngine.Scheduling
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerHealth
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker

  @spec handle_retry_issue(State.t(), String.t(), integer(), map(), keyword()) :: {:noreply, State.t()}
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata, opts \\ []) do
    state = if metadata[:retry_label?], do: sync_retrying_modifier(state, metadata, issue_id, :remove), else: state

    if retry_capacity_available?(state, metadata) and not state.globally_paused do
      start_retry_poll(state, issue_id, attempt, metadata, opts)
    else
      {:noreply, schedule_capacity_retry(state, issue_id, attempt, metadata)}
    end
  end

  defp start_retry_poll(state, issue_id, attempt, metadata, opts) do
    expected = {Map.get(state.retry_attempts, issue_id), MapSet.member?(state.claimed, issue_id)}

    next =
      TrackerTasks.run(state, {:retry_poll, issue_id}, fn -> fetch_retry_poll(issue_id, opts) end, fn current, result ->
        apply_current_retry_poll(current, expected, issue_id, attempt, metadata, opts, result)
      end)

    {:noreply, next}
  end

  defp fetch_retry_poll(issue_id, opts) do
    candidates = Keyword.get(opts, :fetch_candidate_issues_fun, &Tracker.fetch_candidate_issues/0)
    fetch_by_id = Keyword.get(opts, :fetch_issue_states_by_ids_fun, &Tracker.fetch_issue_states_by_ids/1)

    with :ok <- retry_tracker_preflight(opts),
         {:ok, issues} <- candidates.() do
      fetch_retry_issue(issues, issue_id, fetch_by_id)
    end
  end

  defp retry_tracker_preflight(opts) do
    case Keyword.fetch(opts, :ensure_tracker_preflight_fun) do
      {:ok, ensure} -> normalize_retry_preflight(ensure.(%State{}))
      :error -> TrackerHealth.tracker_preflight()
    end
  end

  defp normalize_retry_preflight({:ok, _state}), do: :ok
  defp normalize_retry_preflight({:error, reason, _state}), do: {:error, reason}

  defp apply_current_retry_poll(current, expected, issue_id, attempt, metadata, opts, result) do
    actual = {Map.get(current.retry_attempts, issue_id), MapSet.member?(current.claimed, issue_id)}

    if actual == expected and not Map.has_key?(current.running, issue_id) do
      apply_retry_poll_result(current, issue_id, attempt, metadata, opts, result)
    else
      current
    end
  end

  defp apply_retry_poll_result(current, issue_id, attempt, metadata, opts, {:ok, issue}) do
    if retry_capacity_available?(current, metadata) and not current.globally_paused do
      {:noreply, next} = handle_retry_issue_lookup(issue, current, issue_id, attempt, metadata, opts)
      next
    else
      schedule_capacity_retry(current, issue_id, attempt, metadata)
    end
  end

  defp apply_retry_poll_result(current, issue_id, attempt, metadata, _opts, {:error, reason}) do
    Logger.warning("Retry poll skipped for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{PollFailure.format_retry_preflight_error(reason)}")
    PollFailure.handle_retry_poll_failure(current, issue_id, attempt, metadata, reason)
  end

  defp sync_retrying_modifier(state, metadata, issue_id, action) do
    identifier = metadata[:identifier] || issue_id

    TrackerTasks.chain(
      state,
      {:runtime_reason_labels, identifier},
      fn -> TicketTransition.write_reason_modifier(identifier, action, "retrying", writer: :retry_engine) end,
      fn current, result ->
        case result do
          :ok ->
            current

          {:error, reason} ->
            Logger.warning("retrying reason label update failed: issue=#{identifier} reason=#{inspect(reason)}")
            current
        end
      end
    )
  end

  defp retry_capacity_available?(%State{} = state, metadata) when is_map(metadata) do
    Slots.available_slots(state) > 0 and
      Slots.worker_slots_available?(state, metadata[:worker_host]) and
      retry_state_capacity_available?(state, metadata[:issue_state])
  end

  defp retry_state_capacity_available?(%State{} = state, issue_state) when is_binary(issue_state) do
    DispatchPolicy.state_slots_available?(%Issue{state: issue_state}, state)
  end

  defp retry_state_capacity_available?(%State{}, _issue_state), do: true

  defp schedule_capacity_retry(state, issue_id, attempt, metadata) do
    Scheduling.schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        error: "no available orchestrator slots",
        delay_type: :capacity_wait
      })
    )
  end

  @doc false
  @spec fetch_retry_issue(
          [term()],
          String.t(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()})
        ) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_retry_issue(candidate_issues, issue_id, fetch_issue_states_by_ids_fun)
      when is_list(candidate_issues) and is_binary(issue_id) and is_function(fetch_issue_states_by_ids_fun, 1) do
    case find_issue_by_id(candidate_issues, issue_id) do
      %Issue{} = issue ->
        {:ok, issue}

      nil ->
        case fetch_issue_states_by_ids_fun.([issue_id]) do
          {:ok, issues} when is_list(issues) -> {:ok, find_issue_by_id(issues, issue_id)}
          {:error, reason} -> {:error, reason}
          result -> {:error, {:invalid_retry_issue_lookup, result}}
        end
    end
  end

  @doc false
  @spec handle_retry_issue_lookup(
          Issue.t() | nil,
          State.t(),
          String.t(),
          integer(),
          map(),
          keyword()
        ) ::
          {:noreply, State.t()}
  def handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata, opts \\ [])

  def handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata, opts) do
    terminal_states = Keyword.get(opts, :terminal_states, DispatchPolicy.terminal_state_set())

    terminal_retry_funs = terminal_retry_funs(opts)

    cond do
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) ->
        handle_terminal_retry_issue(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs
        )

      Orchestrator.retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, opts)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, RetryEngine.release_issue_claim(state, issue_id)}
    end
  end

  def handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata, _opts) do
    if metadata[:terminal_membership_pending?] do
      Logger.warning(
        "Terminal membership is still pending for unavailable retry issue_id=#{issue_id}; " <>
          "retaining claim"
      )

      {:noreply,
       Scheduling.schedule_issue_retry(
         state,
         issue_id,
         attempt,
         Map.merge(metadata, %{
           delay_type: :terminal_verification,
           error: "terminal membership verification could not refetch issue",
           terminal_membership_pending?: true
         })
       )}
    else
      Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
      {:noreply, RetryEngine.release_issue_claim(state, issue_id)}
    end
  end

  defp handle_terminal_retry_issue(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         terminal_retry_funs
       ) do
    Logger.info(
      "Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} " <>
        "state=#{issue.state}; removing associated workspace"
    )

    case MembershipLifecycle.record(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           terminal_retry_funs.observe_membership
         ) do
      :ok ->
        finish_terminal_retry_issue(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs.cleanup_terminal_issue_artifacts,
          terminal_retry_funs.set_terminal_verification_pending
        )

      {:error, :membership_observation_failed} ->
        retain_terminal_retry_claim(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs.mark_reconciled,
          terminal_retry_funs.set_terminal_verification_pending
        )
    end
  end

  defp terminal_retry_funs(opts) do
    %{
      observe_membership: Keyword.get(opts, :observe_membership_fun, &MembershipLifecycle.observe/2),
      cleanup_terminal_issue_artifacts:
        Keyword.get(
          opts,
          :cleanup_terminal_issue_artifacts_fun,
          &Orchestrator.cleanup_terminal_issue_artifacts/2
        ),
      mark_reconciled: Keyword.get(opts, :mark_reconciled_fun, &CurrentRunMembership.mark_reconciled/1),
      set_terminal_verification_pending:
        Keyword.get(
          opts,
          :set_terminal_verification_pending_fun,
          &CurrentRunMembership.set_terminal_verification_pending/2
        )
    }
  end

  defp finish_terminal_retry_issue(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         cleanup_terminal_issue_artifacts_fun,
         set_terminal_verification_pending_fun
       ) do
    case CurrentRunMembership.set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      result when result in [:ok, :skipped] ->
        cleanup_terminal_issue_artifacts_fun.(issue.identifier, metadata[:worker_host])
        {:noreply, RetryEngine.release_issue_claim(state, issue_id)}

      :error ->
        {:noreply, schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata)}
    end
  end

  defp retain_terminal_retry_claim(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    safely_mark_membership_unavailable(
      mark_reconciled_fun,
      set_terminal_verification_pending_fun,
      issue.tracker_identity
    )

    {:noreply, schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata)}
  end

  defp handle_active_retry(state, issue, attempt, metadata, opts) do
    if Orchestrator.retry_candidate_issue?(issue, DispatchPolicy.terminal_state_set()) and
         Slots.dispatch_slots_available?(issue, state) and
         Slots.worker_slots_available?(state, metadata[:worker_host]) do
      dispatch = Keyword.get(opts, :dispatch_fun, retry_dispatch_fun(metadata, opts))

      prior_work? = Keyword.get(opts, :prior_work?, metadata[:prior_work] == true)

      next_state =
        dispatch.(state, issue, attempt, metadata[:worker_host],
          prior_work: prior_work?,
          rework_head_sha: metadata[:rework_head_sha]
        )

      {:noreply, ensure_active_retry_started(next_state, issue, attempt, metadata, opts)}
    else
      Logger.debug("No available slots for retrying #{State.issue_context(issue)}; retrying again")

      capacity_metadata =
        Map.merge(metadata, %{
          identifier: issue.identifier,
          tracker_identity: Issue.tracker_identity(issue),
          priority: issue.priority,
          issue_state: issue.state
        })

      {:noreply, schedule_capacity_retry(state, issue.id, attempt, capacity_metadata)}
    end
  end

  defp retry_dispatch_fun(metadata, opts) do
    fn current, ticket, attempt, host, dispatch_opts ->
      completion = fn current -> ensure_active_retry_started(current, ticket, attempt, metadata, opts) end
      Dispatcher.dispatch_issue(current, ticket, attempt, host, Keyword.put(dispatch_opts, :dispatch_result_fun, completion))
    end
  end

  @doc false
  @spec ensure_active_retry_started(State.t(), Issue.t(), pos_integer() | nil, map(), keyword()) :: State.t()
  def ensure_active_retry_started(state, issue, attempt, metadata, opts) do
    if live_running_entry?(Map.get(state.running, issue.id)) or
         Map.has_key?(state.retry_attempts, issue.id) or TrackerTasks.issue_pending?(state, issue.id) do
      state
    else
      schedule_retry = Keyword.get(opts, :schedule_retry_fun, &Scheduling.schedule_issue_retry/4)

      delay_type =
        if MapSet.member?(state.model_fallback_waiting, issue.id),
          do: :model_limit_wait,
          else: :capacity_wait

      schedule_retry.(state, issue.id, attempt, %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "retry dispatch did not start",
        delay_type: delay_type,
        prior_work: metadata[:prior_work] == true,
        worker_host: metadata[:worker_host],
        workspace_path: metadata[:workspace_path],
        rework_head_sha: metadata[:rework_head_sha]
      })
    end
  end

  defp live_running_entry?(%{pid: pid}) when is_pid(pid), do: true
  defp live_running_entry?(_entry), do: false

  defp schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata) do
    Scheduling.schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "terminal membership persistence failed",
        delay_type: :terminal_verification,
        terminal_membership_pending?: true
      })
    )
  end

  defp safely_mark_membership_unavailable(mark_reconciled_fun, set_terminal_verification_pending_fun, identity) do
    _ = CurrentRunMembership.set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end
end
