defmodule Aiur.Orchestrator.RetryEngine do
  @moduledoc """
  Retry scheduling and budget semantics for agent dispatch failures.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.{Alerts, Config, CurrentRunMembership, Issue, Tracker, TrackerIdentity}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    MembershipLifecycle,
    Reconciler,
    Slots,
    State,
    StatusReport,
    TokenAccounting
  }

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @max_retry_poll_failures 3

  @spec handle_retry_message(State.t(), String.t(), reference()) :: {:noreply, State.t()}
  def handle_retry_message(%State{} = state, issue_id, retry_token) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, next_state} ->
          handle_retry_issue(next_state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    StatusReport.notify_dashboard(state)
    result
  end

  @spec handle_agent_down(State.t(), reference(), term()) :: {:noreply, State.t()}
  def handle_agent_down(%State{running: running} = state, ref, reason) do
    case State.find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        running_entry = Map.fetch!(running, issue_id)
        state = TokenAccounting.record_session_completion_totals(state, running_entry)
        session_id = State.running_entry_session_id(running_entry)

        state =
          case {reason, State.completed_running_entry?(running_entry)} do
            {:normal, true} ->
              Logger.info("Completed agent task exited normally for issue_id=#{issue_id} session_id=#{session_id}; parking replaceable entry")

              park_completed_entry(state, issue_id, running_entry)

            {:normal, false} ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              {_running_entry, state} = State.pop_running_entry(state, issue_id)

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                tracker_identity: Issue.tracker_identity(Map.get(running_entry, :issue)),
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            {_reason, false} ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              {_running_entry, state} = State.pop_running_entry(state, issue_id)
              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                tracker_identity: Issue.tracker_identity(Map.get(running_entry, :issue)),
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            {_reason, true} ->
              Logger.warning("Completed agent task exited abnormally for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; preserving completed boundary")

              park_completed_entry(state, issue_id, running_entry)
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        StatusReport.notify_dashboard(state)
        {:noreply, state}
    end
  end

  defp park_completed_entry(state, issue_id, running_entry) do
    parked_entry =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completion_totals_recorded, true)

    %{
      state
      | running: Map.put(state.running, issue_id, parked_entry),
        completed: MapSet.put(state.completed, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  @doc false
  @spec preserve_running_issue_on_external_error(State.t(), Issue.t()) :: State.t()
  def preserve_running_issue_on_external_error(%State{} = state, %Issue{} = issue) do
    previous_state =
      case Map.get(state.running, issue.id) do
        %{issue: %Issue{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        %{issue: %{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        _ -> ""
      end

    if previous_state == "error" do
      Logger.debug("Issue remains in error state while agent is still active: #{State.issue_context(issue)}")
    else
      Logger.warning("Issue reported error state while agent is still active; preserving runner pending local completion: #{State.issue_context(issue)} state=#{issue.state}")
    end

    Reconciler.refresh_running_issue_state(state, issue)
  end

  @spec complete_issue(State.t(), String.t()) :: State.t()
  def complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  def schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    tracker_identity = pick_retry_tracker_identity(previous_retry, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_poll_failures = pick_retry_poll_failures(previous_retry, metadata)

    if failure_retry?(metadata) and next_attempt > Config.max_retry_attempts() do
      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""
      failed_attempts = max(next_attempt - 1, Map.get(previous_retry, :attempt, 0))

      Logger.warning("Giving up on issue_id=#{issue_id} issue_identifier=#{identifier} after #{failed_attempts} failed attempt(s); max_retry_attempts=#{Config.max_retry_attempts()}#{error_suffix}")

      Alerts.emit_system("ticket.#{identifier}.agent.retry_exhausted",
        issue: identifier,
        reason: "Agent retry attempts were exhausted; the ticket needs Executor review.",
        needs_attention: true,
        severity: "warning"
      )

      move_exhausted_issue_to_error_state(issue_id, identifier)

      # Release the claim so a later label-driven re-dispatch (Executor moves the
      # ticket from `error` back to an active state) is picked up without a full
      # daemon restart (#699). The crash path pops `running` but deliberately
      # holds the claim across retries; on give-up that hold must end, otherwise
      # the issue lingers in `claimed` and `dispatch_candidate?/4` refuses it for
      # the daemon's lifetime. Mirrors the retry-poll exhaustion path, which
      # already releases the claim.
      #
      # The `move_exhausted_issue_to_error_state/2` above is best-effort: if that
      # tracker write fails the issue keeps its active-state label, so releasing
      # the claim leaves it eligible for an immediate re-dispatch with a fresh
      # retry budget. That re-dispatch thrash is the class the per-issue
      # `check_thrash_budget/3` breaker exists to bound (it trips with a
      # needs_attention `thrash_circuit_open` alert), and a recovered tracker
      # write parks the ticket in `error` on the next give-up — keeping the
      # ticket recoverable without a restart rather than stranding it in
      # `claimed`, which is the behaviour #699 is fixing.
      released = release_issue_claim(state, issue_id)
      %{released | retry_attempts: Map.delete(released.retry_attempts, issue_id)}
    else
      delay_ms = retry_delay(next_attempt, metadata)
      retry_token = make_ref()
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms

      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      log_scheduled_retry(
        issue_id,
        identifier,
        delay_ms,
        next_attempt,
        retry_poll_failures,
        metadata,
        error_suffix
      )

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue_id, %{
              attempt: next_attempt,
              timer_ref: timer_ref,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              identifier: identifier,
              error: error,
              retry_poll_failures: retry_poll_failures,
              worker_host: worker_host,
              workspace_path: workspace_path,
              tracker_identity: tracker_identity,
              terminal_membership_pending?: metadata[:terminal_membership_pending?] == true
            })
      }
    end
  end

  @spec failure_retry?(map()) :: boolean()
  def failure_retry?(metadata) when is_map(metadata) do
    Map.get(metadata, :delay_type) not in [:continuation, :capacity_wait, :precondition, :terminal_verification]
  end

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, integer(), map(), State.t()} | :missing
  def pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
      when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          retry_poll_failures: Map.get(retry_entry, :retry_poll_failures),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          tracker_identity: Map.get(retry_entry, :tracker_identity),
          terminal_membership_pending?: Map.get(retry_entry, :terminal_membership_pending?, false)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  @spec handle_retry_issue(State.t(), String.t(), integer(), map()) :: {:noreply, State.t()}
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Orchestrator.ensure_tracker_preflight(state) do
      {:ok, state} ->
        handle_retry_tracker_poll(state, issue_id, attempt, metadata)

      {:error, reason, state} ->
        formatted = format_retry_preflight_error(reason)

        Logger.warning("Retry poll skipped for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{formatted}")

        {:noreply, handle_retry_poll_failure(state, issue_id, attempt, metadata, formatted)}
    end
  end

  defp handle_retry_tracker_poll(state, issue_id, attempt, metadata) do
    with {:ok, issues} <- Tracker.fetch_candidate_issues(),
         {:ok, issue} <- fetch_retry_issue(issues, issue_id, &Tracker.fetch_issue_states_by_ids/1) do
      handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    else
      {:error, reason} ->
        {:noreply, handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)}
    end
  end

  @spec release_issue_claim(State.t(), String.t()) :: State.t()
  def release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
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

  @spec retry_delay(integer(), map()) :: non_neg_integer()
  def retry_delay(attempt, %{delay_type: :continuation})
      when is_integer(attempt) and attempt == 1 do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{delay_type: :capacity_wait}) do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{
        delay_type: :precondition,
        retry_poll_failures: retry_poll_failures
      }) do
    retry_poll_failures
    |> normalize_retry_poll_failures()
    |> max(1)
    |> failure_retry_delay()
  end

  def retry_delay(attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    failure_retry_delay(attempt)
  end

  @spec failure_retry_delay(integer()) :: non_neg_integer()
  def failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  @spec normalize_retry_attempt(integer() | term()) :: non_neg_integer()
  def normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_retry_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: pos_integer() | nil
  def next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  # On genuine retry exhaustion, surface the ticket in an Executor-visible
  # state instead of silently leaving it in `rework` with no live agent (#699).
  # `error` ("agent hit an error") is a valid state in neither the active nor
  # the terminal set, so it does not get auto-redispatched. Best-effort: a
  # failed tracker write must not crash the orchestrator.
  defp move_exhausted_issue_to_error_state(issue_id, identifier) when is_binary(identifier) do
    Logger.warning("Moving exhausted issue to error state: issue_id=#{issue_id} issue_identifier=#{identifier} reason=retry_exhausted caller=Aiur.Orchestrator.move_exhausted_issue_to_error_state")

    case Tracker.update_issue_state(identifier, "error") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed moving exhausted issue identifier=#{identifier} to error state: #{inspect(reason)}")

        :ok
    end
  end

  defp move_exhausted_issue_to_error_state(_issue_id, _identifier), do: :ok

  defp log_scheduled_retry(
         issue_id,
         identifier,
         delay_ms,
         attempt,
         retry_poll_failures,
         metadata,
         error_suffix
       ) do
    case Map.get(metadata, :delay_type) do
      :continuation ->
        Logger.warning("Scheduling continuation retry issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")

      :capacity_wait ->
        Logger.warning("Retrying capacity precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt})#{error_suffix}")

      :precondition ->
        Logger.warning(
          "Retrying retry-poll precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt}, retry_poll_failure #{retry_poll_failures}/#{@max_retry_poll_failures})#{error_suffix}"
        )

      _ ->
        Logger.warning("Retrying agent failure issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")
    end
  end

  @doc false
  @spec format_retry_preflight_error(term()) :: String.t()
  def format_retry_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason),
    do: GitHubClient.format_auth_preflight_error(reason)

  def format_retry_preflight_error(reason), do: inspect(reason)

  defp handle_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    identifier = metadata[:identifier] || issue_id
    retry_poll_failures = normalize_retry_poll_failures(metadata[:retry_poll_failures]) + 1

    Logger.warning(
      "Retry poll failed for issue_id=#{issue_id} issue_identifier=#{identifier} retry_poll_failure=#{retry_poll_failures}/#{@max_retry_poll_failures} agent_attempt=#{attempt} tracker_error=#{inspect(reason)}"
    )

    if retry_poll_failures >= @max_retry_poll_failures and not metadata[:terminal_membership_pending?] do
      emit_retry_poll_exhausted_alert(issue_id, identifier, attempt, reason, metadata)
      release_issue_claim(state, issue_id)
    else
      schedule_issue_retry(
        state,
        issue_id,
        attempt,
        Map.merge(metadata, %{
          delay_type: :precondition,
          error: "retry poll failed: #{inspect(reason)}",
          retry_poll_failures: retry_poll_failures,
          terminal_membership_pending?: metadata[:terminal_membership_pending?] == true
        })
      )
    end
  end

  defp emit_retry_poll_exhausted_alert(issue_id, identifier, attempt, reason, metadata) do
    message =
      "Retry polling could not confirm issue state for #{identifier} after #{@max_retry_poll_failures} tracker failure(s); released claim so the ticket can be picked up after tracker recovery. Last tracker error: #{inspect(reason)}. Last agent retry attempt remains #{attempt}."

    Logger.error(
      "Retry poll exhausted for issue_id=#{issue_id} issue_identifier=#{identifier} agent_attempt=#{attempt} max_retry_poll_failures=#{@max_retry_poll_failures} tracker_error=#{inspect(reason)}; releasing claim"
    )

    Alerts.emit_custom(
      "orchestrator.retry_poll.exhausted",
      message,
      issue: identifier,
      worker_host: metadata[:worker_host],
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
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
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  def handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata, _opts) do
    if metadata[:terminal_membership_pending?] do
      Logger.warning(
        "Terminal membership is still pending for unavailable retry issue_id=#{issue_id}; " <>
          "retaining claim"
      )

      {:noreply,
       schedule_issue_retry(
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
      {:noreply, release_issue_claim(state, issue_id)}
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
    case safely_set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      :ok ->
        cleanup_terminal_issue_artifacts_fun.(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

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

  defp handle_active_retry(state, issue, attempt, metadata) do
    if Orchestrator.retry_candidate_issue?(issue, DispatchPolicy.terminal_state_set()) and
         Slots.dispatch_slots_available?(issue, state) and
         Slots.worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, Dispatcher.dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{State.issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           tracker_identity: Issue.tracker_identity(issue),
           error: "no available orchestrator slots",
           delay_type: :capacity_wait
         })
       )}
    end
  end

  defp schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata) do
    schedule_issue_retry(
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
    _ = safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, pending?) do
    if match?(%TrackerIdentity{}, identity) and TrackerIdentity.joinable?(identity) do
      case set_terminal_verification_pending_fun.(identity, pending?) do
        :ok -> :ok
        _ -> :error
      end
    else
      :ok
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize_retry_poll_failures(failures) when is_integer(failures) and failures > 0,
    do: failures

  defp normalize_retry_poll_failures(_failures), do: 0

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_poll_failures(previous_retry, metadata) do
    metadata
    |> Map.get(:retry_poll_failures, Map.get(previous_retry, :retry_poll_failures))
    |> normalize_retry_poll_failures()
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_tracker_identity(previous_retry, metadata) do
    if Map.has_key?(metadata, :tracker_identity) do
      Map.get(metadata, :tracker_identity)
    else
      Map.get(previous_retry, :tracker_identity)
    end
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
