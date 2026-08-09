defmodule Aiur.Orchestrator.Reconciler do
  @moduledoc """
  Per-poll reconciliation of running entries against refreshed tracker states.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, CurrentRunMembership, Issue, Tracker, TrackerIdentity}
  alias Aiur.Orchestrator

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    LifecycleFence,
    MembershipLifecycle,
    PauseResume,
    RateLimitFallback,
    State
  }

  # A before_run hook failure parks the agent alive in
  # `AgentRunner.wait_for_before_run_resume/3`; resuming re-runs the hook inside
  # the agent's own loop WITHOUT going back through the dispatch counter, so a
  # persistently-failing hook (for example a real merge conflict) would retry on
  # every poll forever. Bound automatic recovery to a small number of attempts,
  # then leave the entry paused for operator-driven recovery.
  @max_before_run_resume_attempts 5

  @spec reconcile_running_lifecycle(State.t()) :: State.t()
  def reconcile_running_lifecycle(%State{} = state) do
    state = Orchestrator.reconcile_stalled_running_issues(state)
    state = Orchestrator.reconcile_overrunning_agents(state)
    state = Orchestrator.reconcile_pending_auto_resumes(state)
    RateLimitFallback.reconcile(state)
  end

  @spec refresh_running_issue_states(State.t()) :: State.t()
  def refresh_running_issue_states(%State{} = state) do
    refresh_running_issue_states(state, [])
  end

  @doc false
  @spec refresh_running_issue_states(State.t(), keyword()) :: State.t()
  def refresh_running_issue_states(%State{} = state, opts) when is_list(opts) do
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      if map_size(state.running_issue_cache) == 0,
        do: state,
        else: %{state | running_issue_cache: %{}}
    else
      issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids_conditional/2)

      case issue_fetcher.(running_ids, state.running_issue_cache) do
        {:ok, issues, cache} ->
          next_state =
            issues
            |> reconcile_running_issue_states(
              state,
              DispatchPolicy.active_state_set(),
              DispatchPolicy.terminal_state_set()
            )
            |> reconcile_missing_running_issue_ids(running_ids, issues)

          %{next_state | running_issue_cache: Map.take(cache, Map.keys(next_state.running))}

        {:error, reason, cache} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")
          %{state | running_issue_cache: Map.take(cache, running_ids)}

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t()) :: State.t()
  def reconcile_running_issue_states(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(
      issues,
      state,
      DispatchPolicy.active_state_set(),
      DispatchPolicy.terminal_state_set()
    )
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t(), MapSet.t(), MapSet.t()) ::
          State.t()
  def reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  def reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  @spec reconcile_issue_state(Issue.t() | term(), State.t(), MapSet.t(), MapSet.t()) :: State.t()
  def reconcile_issue_state(issue, state, active_states, terminal_states) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      &MembershipLifecycle.observe/2,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun
      )
      when is_function(observe_membership_fun, 2) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      observe_membership_fun,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun
      ),
      do: state

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term()),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun,
        mark_reconciled_fun
      )
      when is_function(observe_membership_fun, 2) and is_function(mark_reconciled_fun, 1) do
    if DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) do
      case LifecycleFence.reconcile_observed_state(state, issue, terminal_states) do
        :admit ->
          # Resolve any open divergence attention before the entry is removed,
          # so a terminal ticket never leaves a stuck alert behind. A fenced
          # issue is still running, so its divergence state is left intact.
          state
          |> clear_reported_divergence(issue.id, issue.identifier)
          |> reconcile_terminal_issue_state(
            issue,
            observe_membership_fun,
            mark_reconciled_fun
          )

        {:fenced, next_state} ->
          next_state
      end
    else
      state
      |> report_label_divergence(issue)
      |> reconcile_nonterminal_issue_state(
        issue,
        active_states,
        terminal_states,
        observe_membership_fun
      )
    end
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun,
        _mark_reconciled_fun
      ),
      do: state

  defp reconcile_terminal_issue_state(state, issue, observe_membership_fun, mark_reconciled_fun) do
    Logger.info([
      "Issue moved to terminal state: ",
      State.issue_context(issue),
      " state=",
      inspect(issue.state),
      "; stopping active agent"
    ])

    case record_membership(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           observe_membership_fun
         ) do
      :ok ->
        terminate_recorded_terminal_issue(state, issue, mark_reconciled_fun)

      {:error, :membership_observation_failed} ->
        mark_membership_unavailable(state, mark_reconciled_fun, issue.tracker_identity)
    end
  end

  # A label-override pause is authoritative only while the tracker still carries
  # `agent:paused`. If it disappears while the in-memory entry remains paused,
  # the Executor otherwise sees two incompatible fleet states until this poll
  # happens to resume the worker. Emit before reconciliation repairs it so the
  # discrepancy is visible in the alert feed.
  @doc false
  @spec report_label_divergence(State.t(), Issue.t()) :: State.t()
  def report_label_divergence(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{} = entry ->
        identifier = Map.get(entry, :identifier) || issue.identifier || issue.id

        case label_divergence(entry, issue) do
          nil ->
            clear_reported_divergence(state, issue.id)

          reason ->
            report_label_divergence_once(state, issue, entry, identifier, reason)
        end

      _ ->
        clear_reported_divergence(state, issue.id, issue.identifier)
    end
  end

  @doc false
  @spec resolve_orphaned_divergence_attentions(State.t()) :: State.t()
  def resolve_orphaned_divergence_attentions(%State{} = state) do
    running_identifiers =
      state.running
      |> Map.values()
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, :identifier) || get_in(entry, [:issue, Access.key(:identifier)]) do
          identifier when is_binary(identifier) and identifier != "" -> [identifier]
          _ -> []
        end
      end)
      |> MapSet.new()

    state.active_attention_topics
    |> Enum.reduce(state, &resolve_orphaned_divergence_attention(&2, &1, running_identifiers))
  end

  defp resolve_orphaned_divergence_attention(state, topic, running_identifiers) do
    identifier = divergence_identifier(topic)

    cond do
      not is_binary(identifier) -> state
      MapSet.member?(running_identifiers, identifier) -> state
      true -> emit_divergence_resolution(state, identifier, nil, identifier, topic)
    end
  end

  defp divergence_identifier("ticket." <> rest) do
    suffix = ".agent.attention.state_divergence"

    if String.ends_with?(rest, suffix), do: String.trim_trailing(rest, suffix)
  end

  defp divergence_identifier(_topic), do: nil

  defp label_divergence(%{control: %{status: :paused}, paused_reason: :label_override}, %Issue{} = issue)
       when not is_nil(issue) do
    unless Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=paused(label_override) tracker=agent:#{issue.state}."
  end

  defp label_divergence(%{control: %{status: :paused}, paused_reason: :max_agent_duration}, %Issue{} = issue)
       when not is_nil(issue) do
    unless Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=paused(max_agent_duration) tracker=agent:#{issue.state}; operator resume is required."
  end

  defp label_divergence(%{control: %{status: status}}, %Issue{} = issue) when status in [:working, :sleeping] do
    if Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=#{status} tracker=agent:paused."
  end

  defp label_divergence(_entry, _issue), do: nil

  defp report_label_divergence_once(state, issue, entry, identifier, reason) do
    topic = "ticket.#{identifier}.agent.attention.state_divergence"
    entry = Map.delete(entry, :label_divergence_attention_checked)

    if Map.get(entry, :label_divergence_reported) == reason or active_attention?(state, topic) do
      put_in(state.running[issue.id], Map.put(entry, :label_divergence_reported, reason))
    else
      Alerts.emit_custom(topic, reason,
        issue: identifier,
        workspace: Map.get(entry, :workspace_path),
        worker_host: Map.get(entry, :worker_host),
        reason: reason,
        needs_attention: true,
        severity: "warning",
        central: true
      )

      put_in(state.running[issue.id], Map.put(entry, :label_divergence_reported, reason))
    end
  end

  defp clear_reported_divergence(state, issue_id, fallback_identifier \\ nil) do
    case Map.get(state.running, issue_id) do
      %{} = entry ->
        clear_entry_divergence(state, issue_id, entry)

      _ when is_binary(fallback_identifier) and fallback_identifier != "" ->
        clear_persisted_divergence(state, issue_id, fallback_identifier)

      _ ->
        state
    end
  end

  defp clear_persisted_divergence(state, issue_id, identifier) do
    topic = "ticket.#{identifier}.agent.attention.state_divergence"

    if active_attention?(state, topic) do
      emit_divergence_resolution(state, issue_id, nil, identifier, topic)
    else
      state
    end
  end

  defp clear_entry_divergence(state, issue_id, entry) do
    identifier = Map.get(entry, :identifier) || issue_id
    topic = "ticket.#{identifier}.agent.attention.state_divergence"

    if reported_divergence_active?(state, entry, topic) do
      emit_divergence_resolution(state, issue_id, entry, identifier, topic)
    else
      mark_divergence_checked(state, issue_id, entry)
    end
  end

  defp reported_divergence_active?(state, entry, topic) do
    Map.has_key?(entry, :label_divergence_reported) or
      (not Map.get(entry, :label_divergence_attention_checked, false) and
         active_attention?(state, topic))
  end

  defp active_attention?(state, topic), do: MapSet.member?(state.active_attention_topics, topic)

  defp emit_divergence_resolution(state, issue_id, entry, identifier, topic) do
    metadata = entry || %{}
    previous_reason = Map.get(metadata, :label_divergence_reported, "the prior divergence")

    case Alerts.emit_custom(
           "#{topic}.resolved",
           "Tracker/local state reconciliation recovered for ticket #{identifier}.",
           issue: identifier,
           workspace: Map.get(metadata, :workspace_path),
           worker_host: Map.get(metadata, :worker_host),
           reason: "Resolved: #{previous_reason}",
           needs_attention: false,
           severity: "info",
           central: true
         ) do
      :ok -> mark_divergence_checked(state, issue_id, entry)
      {:error, _reason} -> state
    end
  end

  defp mark_divergence_checked(state, issue_id, entry) when is_map(entry) do
    checked_entry =
      entry
      |> Map.delete(:label_divergence_reported)
      |> Map.put(:label_divergence_attention_checked, true)

    put_in(state.running[issue_id], checked_entry)
  end

  defp mark_divergence_checked(state, _issue_id, nil), do: state

  defp terminate_recorded_terminal_issue(state, issue, mark_reconciled_fun) do
    if safely_set_terminal_verification_pending(issue.tracker_identity, false) == :ok do
      Orchestrator.terminate_running_issue(state, issue.id, true)
    else
      mark_membership_unavailable(state, mark_reconciled_fun, issue.tracker_identity)
    end
  end

  defp reconcile_nonterminal_issue_state(
         state,
         issue,
         active_states,
         terminal_states,
         observe_membership_fun
       ) do
    cond do
      !DispatchPolicy.issue_routable_to_worker?(issue) ->
        Logger.info([
          "Issue no longer routed to this worker: ",
          State.issue_context(issue),
          " assignee=",
          inspect(issue.assignee_id),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> clear_reported_divergence(issue.id)
        |> Orchestrator.terminate_running_issue(issue.id, false)

      !DispatchPolicy.issue_dispatch_authorized?(issue) ->
        Logger.warning([
          "Issue dispatch authorization was revoked: ",
          State.issue_context(issue),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> clear_reported_divergence(issue.id)
        |> Orchestrator.terminate_running_issue(issue.id, false)

      Issue.paused?(issue) ->
        PauseResume.pause_issue_for_label_override(state, issue)

      true ->
        reconcile_routable_nonterminal_issue_state(
          state,
          issue,
          active_states,
          terminal_states,
          observe_membership_fun
        )
    end
  end

  defp reconcile_routable_nonterminal_issue_state(
         state,
         issue,
         active_states,
         terminal_states,
         observe_membership_fun
       ) do
    case LifecycleFence.reconcile_observed_state(state, issue, terminal_states) do
      {:fenced, next_state} ->
        next_state

      :admit ->
        reconcile_unfenced_nonterminal_issue_state(
          state,
          issue,
          active_states,
          observe_membership_fun
        )
    end
  end

  defp reconcile_unfenced_nonterminal_issue_state(
         state,
         issue,
         active_states,
         observe_membership_fun
       ) do
    cond do
      DispatchPolicy.active_issue_state?(issue.state, active_states) ->
        maybe_reactivate_or_refresh(state, issue)

      Orchestrator.ci_wait_state?(issue.state) ->
        Orchestrator.pause_issue_for_ci_wait(state, issue)

      Orchestrator.human_review_state?(issue.state) ->
        Orchestrator.maybe_deactivate_human_review_issue(state, issue)

      Orchestrator.error_issue_state?(issue.state) ->
        Orchestrator.preserve_running_issue_on_external_error(state, issue)

      true ->
        Logger.info([
          "Issue moved to non-active state: ",
          State.issue_context(issue),
          " state=",
          inspect(issue.state),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> clear_reported_divergence(issue.id)
        |> Orchestrator.terminate_running_issue(issue.id, false)
    end
  end

  defp record_membership(%Issue{} = issue, lifecycle, observe_membership_fun) do
    MembershipLifecycle.record(issue, lifecycle, observe_membership_fun)
  end

  defp mark_membership_unavailable(state, mark_reconciled_fun, identity) do
    _ = safely_set_terminal_verification_pending(identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp safely_set_terminal_verification_pending(identity, pending?) do
    if match?(%TrackerIdentity{}, identity) and TrackerIdentity.joinable?(identity) do
      case CurrentRunMembership.set_terminal_verification_pending(identity, pending?) do
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

  @spec maybe_reactivate_or_refresh(State.t(), Issue.t()) :: State.t()
  def maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: :paused}, paused_reason: pause_reason} = running_entry
      when pause_reason not in [:before_run_failure, :ci_wait, :label_override] ->
        refresh_running_entry_issue(state, issue, running_entry)

      %{completed_provenance: true} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :deactivated}} = running_entry ->
        reactivate_deactivated_issue(state, running_entry, issue)

      %{control: %{status: :paused}, paused_reason: :before_run_failure} = running_entry ->
        resume_before_run_failure(state, running_entry, issue)

      %{control: %{status: :paused}, paused_reason: pause_reason} = running_entry
      when pause_reason in [:ci_wait, :label_override] ->
        resume_reactivated_issue(state, running_entry, issue, pause_reason)

      _ ->
        refresh_running_issue_state(state, issue)
    end
  end

  defp reactivate_deactivated_issue(state, running_entry, issue) do
    new_entry = Map.put(running_entry, :issue, issue)
    state = %{state | running: Map.put(state.running, issue.id, new_entry)}
    {_result, next_state} = Orchestrator.reactivate_issue(state, new_entry)
    next_state
  end

  defp resume_reactivated_issue(state, running_entry, issue, pause_reason) do
    new_entry = Map.put(running_entry, :issue, issue)
    state = %{state | running: Map.put(state.running, issue.id, new_entry)}

    state =
      if pause_reason == :ci_wait,
        do: Orchestrator.cancel_ci_wait_rewake(state, issue.id),
        else: state

    case Orchestrator.resume_paused_issue(state, new_entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        Logger.info("Paused issue resume deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        next_state
    end
  end

  # Resume-to-live-pid: the parked agent is still alive and blocked awaiting the
  # `:resume_agent` signal, so `resume_paused_issue` unblocks it directly (no
  # re-dispatch). Because that bypasses the dispatch/thrash counter, we count the
  # attempts here and give up once the budget is spent so a persistent failure
  # cannot loop. Only a resume that actually fired (message delivered) burns
  # budget — a capacity deferral leaves it for the next poll.
  defp resume_before_run_failure(state, running_entry, issue) do
    attempts = Map.get(running_entry, :before_run_resume_attempts, 0)

    cond do
      attempts < @max_before_run_resume_attempts ->
        new_entry = Map.put(running_entry, :issue, issue)
        state = %{state | running: Map.put(state.running, issue.id, new_entry)}

        case Orchestrator.resume_paused_issue(state, new_entry, false) do
          {{:ok, :resumed}, next_state} ->
            bump_before_run_resume_attempts(next_state, issue.id)

          {{:error, reason}, next_state} ->
            Logger.info("before_run_failure resume deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

            next_state
        end

      Map.get(running_entry, :before_run_resume_exhausted, false) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.warning(
          "orchestrator.before_run_resume_exhausted issue_id=#{issue.id} issue_identifier=#{Map.get(running_entry, :identifier)} attempts=#{attempts} leaving paused for operator recovery"
        )

        exhausted_entry = Map.put(running_entry, :before_run_resume_exhausted, true)
        state = %{state | running: Map.put(state.running, issue.id, exhausted_entry)}
        refresh_running_issue_state(state, issue)
    end
  end

  defp bump_before_run_resume_attempts(state, issue_id) do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        %{} = entry ->
          current = Map.get(entry, :before_run_resume_attempts, 0)
          Map.put(running, issue_id, Map.put(entry, :before_run_resume_attempts, current + 1))

        _ ->
          running
      end
    end)
  end

  @spec reconcile_missing_running_issue_ids(State.t(), [String.t()], [Issue.t() | term()]) ::
          State.t()
  def reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
      when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)

        state_acc
        |> clear_reported_divergence(issue_id)
        |> Orchestrator.terminate_running_issue(issue_id, false)
      end
    end)
  end

  def reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  @spec refresh_running_issue_state(State.t(), Issue.t()) :: State.t()
  def refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  @spec refresh_running_entry_issue(State.t(), Issue.t(), map()) :: State.t()
  def refresh_running_entry_issue(%State{} = state, %Issue{} = issue, running_entry)
      when is_map(running_entry) do
    %{state | running: Map.put(state.running, issue.id, Map.put(running_entry, :issue, issue))}
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info([
          "Issue no longer visible during running-state refresh: issue_id=",
          issue_id,
          " issue_identifier=",
          inspect(identifier),
          "; stopping active agent"
        ])

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok
end
