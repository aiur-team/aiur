defmodule Aiur.Orchestrator.PauseResume do
  @moduledoc """
  Owns the pause, resume, and reactivation state machine for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentPubSub, Config, Issue, Tracker, TrackerIdentity}
  alias Aiur.Events.IdGenerator
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.RemoteControlMode
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TrackedSet
  alias Aiur.RunTelemetry.Lifecycle
  require Logger

  # Attribution marker for agents held by the global pause switch, distinct
  # from every per-agent pause reason. Unpause resumes only these entries, so
  # an operator's individual pause is never overridden. See `Aiur.Orchestrator.GlobalPause`.
  @global_pause_reason :global_pause

  @spec global_pause_reason() :: :global_pause
  def global_pause_reason, do: @global_pause_reason

  @spec pause_agent(String.t() | TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(issue_identifier), do: pause_agent(Aiur.Orchestrator, issue_identifier)

  @spec pause_agent(GenServer.server(), String.t() | TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, issue_identifier),
    do: control_api_call(server, {:pause_agent, issue_identifier})

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(issue_identifier), do: resume_agent(Aiur.Orchestrator, issue_identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(server, issue_identifier),
    do: control_api_call(server, {:resume_agent, issue_identifier})

  @spec reset_dispatch_budget(String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(issue_identifier), do: reset_dispatch_budget(Aiur.Orchestrator, issue_identifier)

  @spec reset_dispatch_budget(GenServer.server(), String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(server, issue_identifier),
    do: control_api_call(server, {:reset_dispatch_budget, issue_identifier})

  @doc false
  @spec reset_dispatch_budget_call(State.t(), String.t()) :: {:reply, {:ok, :reset} | {:error, term()}, State.t()}
  def reset_dispatch_budget_call(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    case find_issue_id_by_identifier(state, issue_identifier) do
      {:ok, issue_id} ->
        issue = Map.get(state.last_polled_issues, issue_id)
        was_latched? = match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(state, issue_id))
        {state, reset_result} = Dispatcher.reset_lifetime_budget(state, issue_id)
        reply_for_reset(state, issue, was_latched?, reset_result, issue_identifier)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def reset_dispatch_budget_call(%State{} = state, _issue_identifier) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  defp reply_for_reset(state, issue, was_latched?, :ok, issue_identifier) do
    case restore_latched_error_state(state, issue, was_latched?) do
      {:ok, state} ->
        Logger.info("Lifetime dispatch budget reset: issue_identifier=#{issue_identifier} issue_id=#{issue.id}")
        {:reply, {:ok, :reset}, state}

      {:error, reason} ->
        Logger.error("Lifetime dispatch budget reset could not restore the ticket to a dispatchable state: issue_identifier=#{issue_identifier} reason=#{inspect(reason)}")

        {:reply, {:error, {:state_restore_failed, reason}}, state}
    end
  end

  defp reply_for_reset(state, _issue, _was_latched?, {:error, reason}, issue_identifier) do
    Logger.error("Lifetime dispatch budget reset failed (durable store): issue_identifier=#{issue_identifier} reason=#{inspect(reason)}")

    {:reply, {:error, {:budget_reset_failed, reason}}, state}
  end

  # A lifetime-latched ticket is durably moved to `agent:error` when it trips
  # (`Dispatcher.persist_lifetime_trip/3`), and `error` is not an active state —
  # so clearing the budget alone leaves the ticket undispatchable. Restore a
  # latched error ticket to `rework` (the active state the latch most commonly
  # trips from) so `reset-budget` actually returns it to dispatchable
  # (#1453 review P2c). Non-error or non-latched tickets pass through untouched.
  defp restore_latched_error_state(state, %Issue{state: tracker_state} = issue, true) do
    if DispatchPolicy.normalize_issue_state(tracker_state) == "error" and is_binary(issue.identifier) do
      case Tracker.update_issue_state(issue.identifier, "rework") do
        :ok ->
          refreshed = %{issue | state: "rework"}
          {:ok, %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, refreshed)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp restore_latched_error_state(state, _issue, _was_latched?), do: {:ok, state}

  defp find_issue_id_by_identifier(%State{} = state, issue_identifier) do
    case Enum.find(state.last_polled_issues, fn
           {_id, %Issue{identifier: ^issue_identifier}} -> true
           _ -> false
         end) do
      {issue_id, _issue} -> {:ok, issue_id}
      nil -> {:error, :unknown_issue}
    end
  end

  @spec request_control(String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(issue_identifier, action, request_id), do: request_control(Aiur.Orchestrator, issue_identifier, action, request_id)

  @spec request_control(GenServer.server(), String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(server, issue_identifier, action, request_id)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0 do
    control_api_call(server, {:request_control, issue_identifier, action, request_id})
  end

  @spec control_lifecycle(String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(issue_identifier), do: control_lifecycle(Aiur.Orchestrator, issue_identifier)

  @spec control_lifecycle(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(server, issue_identifier),
    do: control_api_call(server, {:control_lifecycle, issue_identifier})

  @spec resume_issue_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  # Global-hold-wins: while the daemon is globally paused, an individual resume
  # cannot override the single switch. Unpause the daemon to resume agents.
  def resume_issue_call(%State{globally_paused: true} = state, issue_identifier)
      when is_binary(issue_identifier) do
    {:reply, {:error, :globally_paused}, state}
  end

  def resume_issue_call(%State{} = state, issue_identifier) do
    {reply, state} = resume_issue(state, issue_identifier)
    StatusReport.notify_dashboard(state)
    {:reply, reply, state}
  end

  @spec pause_agent_call(State.t(), String.t() | TrackerIdentity.t()) :: {:reply, term(), State.t()}
  def pause_agent_call(%State{globally_paused: true} = state, _issue_identifier),
    do: {:reply, {:error, :globally_paused}, state}

  def pause_agent_call(%State{} = state, issue_identifier) do
    {reply, state} = pause_agent_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  @spec request_control_call(State.t(), String.t(), :pause | :resume, pos_integer()) ::
          {:reply, {:ok, pos_integer()} | {:error, term()}, State.t()}
  # Global-hold-wins: neither per-agent control can claim success while the
  # daemon-wide switch masks its effect. A global unpause is the only way out.
  def request_control_call(%State{globally_paused: true} = state, issue_identifier, action, request_id)
      when action in [:pause, :resume] and is_binary(issue_identifier) and is_integer(request_id) and request_id > 0 do
    {:reply, {:error, :globally_paused}, state}
  end

  def request_control_call(%State{} = state, issue_identifier, action, request_id)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0 do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        {reply, state} =
          case action do
            :pause -> submit_control_request(state, running_entry, issue_identifier, :pause, :operator, request_id)
            :resume -> submit_resume_control_request(state, running_entry, :operator, request_id)
          end

        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  @doc """
  Request a pause on every running agent that the global switch should hold.

  Skips agents that are already individually paused, deactivated, completed, or
  carry an in-flight pause request — so a per-agent pause is never overridden.
  Held agents are tagged with `#{inspect(@global_pause_reason)}` so `resume_running_from_global/1`
  can resume exactly this set.
  """
  @spec pause_running_for_global(State.t()) :: State.t()
  def pause_running_for_global(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.reduce(state, fn entry, state ->
      if globally_pausable?(state, entry) do
        {_reply, state} = request_pause(state, entry, Map.get(entry, :issue), @global_pause_reason)
        state
      else
        state
      end
    end)
  end

  @doc """
  Resume only the agents the global switch is holding.

  An agent is globally held when it is paused with reason `#{inspect(@global_pause_reason)}`
  or carries an in-flight global-pause request. Individually paused agents are
  left untouched, preserving the operator's per-agent pause.
  """
  @spec resume_running_from_global(State.t()) :: State.t()
  def resume_running_from_global(%State{} = state) do
    state.running
    |> Enum.filter(fn {_id, entry} -> globally_held?(state, entry) end)
    |> Enum.reduce(state, fn {_id, entry}, state ->
      if tracker_pause_override?(entry) do
        preserve_tracker_pause_after_global_hold(state, entry)
      else
        {_reply, state} = resume_issue(state, Map.get(entry, :identifier))
        state
      end
    end)
  end

  defp tracker_pause_override?(%{issue: %Issue{} = issue}), do: Issue.paused?(issue)
  defp tracker_pause_override?(_entry), do: false

  defp preserve_tracker_pause_after_global_hold(state, entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])

    entry =
      entry
      |> Map.put(:paused_reason, :label_override)
      |> update_pending_global_pause_reason()

    put_running_entry(state, issue_id, entry)
  end

  defp update_pending_global_pause_reason(%{pending_pause_reason: %{reason: @global_pause_reason} = pending} = entry),
    do: %{entry | pending_pause_reason: %{pending | reason: :label_override}}

  defp update_pending_global_pause_reason(entry), do: entry

  defp globally_pausable?(state, entry) do
    not State.paused_running_entry?(entry) and
      not State.deactivated_running_entry?(entry) and
      not State.completed_provenance?(entry) and
      not pending_pause_request?(state, entry)
  end

  defp globally_held?(state, entry) do
    applied_global_hold?(entry) or pending_global_hold?(state, entry)
  end

  defp applied_global_hold?(entry) do
    State.paused_running_entry?(entry) and Map.get(entry, :paused_reason) == @global_pause_reason
  end

  defp pending_global_hold?(state, entry) do
    pending_pause_request?(state, entry) and
      match?(%{reason: @global_pause_reason}, Map.get(entry, :pending_pause_reason))
  end

  @spec control_lifecycle_call(State.t(), String.t()) :: {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def control_lifecycle_call(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      %{issue: %{id: issue_id}} ->
        history = ControlLifecycle.history(state.control_lifecycle, issue_id)

        projection = %{
          current_pending:
            case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
              nil -> nil
              request -> ControlLifecycle.event_payload(request)
            end,
          history: Enum.map(history, &ControlLifecycle.event_payload/1)
        }

        {:reply, {:ok, projection}, state}

      _ ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  @doc false
  @spec expire_pending_controls(State.t(), DateTime.t(), non_neg_integer()) :: State.t()
  def expire_pending_controls(%State{} = state, %DateTime{} = now, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    {expired, lifecycle} = ControlLifecycle.expire_due(state.control_lifecycle, timeout_ms, now: now)

    if expired == [] do
      state
    else
      state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()

      Enum.each(expired, &publish_expired_control(state, &1))

      state
    end
  end

  defp publish_expired_control(state, request) do
    case Map.get(state.running, request.issue_id) do
      %{identifier: identifier} when is_binary(identifier) -> publish_control_lifecycle(identifier, request)
      _ -> :ok
    end
  end

  @spec resume_issue(State.t(), String.t()) ::
          {{:ok, :resumed | :started} | {:error, term()}, State.t()}
  def resume_issue(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        resume_running_issue(state, running_entry)

      nil ->
        resume_queued_issue(state, issue_identifier)
    end
  end

  defp resume_running_issue(%State{} = state, running_entry) do
    case clear_tracker_pause_override(state, running_entry) do
      {:ok, state, running_entry} ->
        do_resume_running_issue(state, running_entry)

      {:error, reason} ->
        Logger.warning("Pause override clear failed: #{pause_log_context(running_entry)} reason=#{inspect(reason)}")
        {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  defp do_resume_running_issue(state, running_entry) do
    cond do
      State.completed_provenance?(running_entry) ->
        restart_completed_provenance_issue(state, running_entry)

      State.deactivated_running_entry?(running_entry) ->
        reactivate_issue(state, running_entry)

      pending_pause_request?(state, running_entry) ->
        resume_pending_pause(state, running_entry)

      State.paused_running_entry?(running_entry) ->
        resume_paused_issue(state, running_entry)

      true ->
        {{:ok, :resumed}, state}
    end
  end

  defp clear_tracker_pause_override(%State{} = state, %{issue: %Issue{} = issue} = running_entry) do
    if Issue.paused?(issue) do
      case clear_pause_override(running_entry) do
        {:ok, cleared_entry} ->
          {:ok, put_running_entry(state, issue.id, cleared_entry), cleared_entry}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state, running_entry}
    end
  end

  defp clear_tracker_pause_override(%State{} = state, %Issue{} = issue) do
    if Issue.paused?(issue) do
      case clear_pause_override(issue) do
        {:ok, cleared_issue} ->
          state = %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, cleared_issue)}
          {:ok, state, cleared_issue}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state, issue}
    end
  end

  defp clear_tracker_pause_override(%State{} = state, running_entry),
    do: {:ok, state, running_entry}

  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue) do
    running_entry = Map.get(state.running, issue.id)

    if pending_local_pause?(state, running_entry, issue.id) do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      apply_label_override(state, running_entry, issue)
    end
  end

  defp apply_label_override(state, running_entry, issue) do
    case running_entry do
      nil ->
        RetryEngine.release_issue_claim(state, issue.id)

      %{completed_provenance: true} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: :deactivated}} = running_entry ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}} = running_entry ->
        apply_label_override_to_paused_issue(state, running_entry, issue)

      running_entry when is_map(running_entry) ->
        Logger.info("Issue pause override detected: #{State.issue_context(issue)}; pausing active agent")
        {_reply, state} = request_pause(state, running_entry, issue, :label_override)
        state

      _ ->
        state
    end
  end

  defp pending_local_pause?(state, running_entry, issue_id) when is_map(running_entry) do
    pending_reason = Map.get(running_entry, :pending_pause_reason)
    pending_request = ControlLifecycle.current_pending(state.control_lifecycle, issue_id)

    case {pending_reason, pending_request} do
      {%{request_id: request_id, reason: reason}, %{action: :pause, request_id: request_id}}
      when reason != :label_override ->
        true

      _ ->
        false
    end
  end

  defp pending_local_pause?(_state, _running_entry, _issue_id), do: false

  defp apply_label_override_to_paused_issue(state, running_entry, issue) do
    pause_reason = Map.get(running_entry, :paused_reason)

    if not is_nil(pause_reason) and pause_reason != :label_override do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      running_entry =
        running_entry
        |> Map.put(:issue, issue)
        |> Map.put(:paused_reason, :label_override)

      transition_control_status(state, running_entry, :paused, "label_override")
    end
  end

  @spec resume_label_overridden_issue(State.t(), map()) ::
          {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_label_overridden_issue(%State{} = state, running_entry),
    do: resume_running_issue(state, running_entry)

  defp pause_completed_issue_for_label_override(state, running_entry, issue) do
    if State.paused_running_entry?(running_entry) and
         not is_nil(Map.get(running_entry, :paused_reason)) do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      state = Reconciler.refresh_running_entry_issue(state, issue, running_entry)
      state = AgentTeardown.deactivate_running_issue(state, issue.id)
      parked_entry = Map.fetch!(state.running, issue.id)

      parked_entry =
        parked_entry
        |> Map.put(:issue, issue)
        |> Map.put(:paused_reason, :label_override)

      transition_control_status(state, parked_entry, :paused, "label_override.completed")
    end
  end

  # Wake a `:deactivated` running entry: flip its control status to
  # `:working`, re-add the id to the publisher tracked set, and spawn
  # a fresh agent task on the same issue. Mirrors `resume_paused_issue`
  # in shape but uses `do_dispatch_issue` because the deactivated
  # entry has no live pid to send a resume-control message to.
  #
  # Capacity check: returns `{:error, :max_concurrent_agents_reached}`
  # without flipping state when all slots are full. The Executor can
  # retry once a slot opens (a working agent flips to `:deactivated`
  # or merges its PR). No `pending_reactivation` flag — the existing
  # `max_concurrent_agents` gate is the natural backpressure.
  @doc false
  @spec reactivate_issue(State.t(), map()) :: {{:ok, :reactivated} | {:error, term()}, State.t()}
  def reactivate_issue(%State{} = state, running_entry) do
    if State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) do
      {{:error, :max_concurrent_agents_reached}, state}
    else
      do_reactivate(state, running_entry)
    end
  end

  # Pause-key behaviour, split out so the GenServer clause stays at
  # max-depth 2. A `:deactivated` row has no live pid to pause; we
  # return `:already_inactive` and rely on `:resume_agent` to handle
  # the wake path on the same space-key.
  @spec pause_agent_reply(State.t(), String.t() | TrackerIdentity.t()) :: {term(), State.t()}
  def pause_agent_reply(state, %TrackerIdentity{} = identity) do
    case State.find_unique_running_by_identity(state.running, identity) do
      {:ok, running_entry, issue_identifier} ->
        pause_running_or_inactive(state, running_entry, issue_identifier)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  def pause_agent_reply(state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        pause_running_or_inactive(state, running_entry, issue_identifier)

      _ ->
        {{:error, :no_running_agent}, state}
    end
  end

  # A control admission means the request reached the expected live worker; it
  # is deliberately not a status transition. Only the worker's correlated
  # acknowledgement below may move this entry to `:paused`.
  defp pause_running_or_inactive(state, running_entry, _issue_identifier) do
    if State.deactivated_running_entry?(running_entry) or
         State.completed_provenance?(running_entry) do
      {{:error, :already_inactive}, state}
    else
      request_pause(state, running_entry, Map.get(running_entry, :issue), :operator_pause)
    end
  end

  @doc false
  @spec request_pause(State.t(), map(), Issue.t() | nil, atom()) :: {term(), State.t()}
  def request_pause(%State{} = state, running_entry, issue, pause_reason)
      when is_map(running_entry) and is_atom(pause_reason) do
    {state, running_entry, issue_id, identifier} = prepare_pause_request(state, running_entry, issue)

    cond do
      State.paused_running_entry?(running_entry) and pending_resume_request?(state, running_entry) and
          is_binary(identifier) ->
        submit_pause_request(state, running_entry, issue_id, identifier, pause_reason)

      State.paused_running_entry?(running_entry) ->
        adopt_existing_pause(state, running_entry, pause_reason)

      true ->
        route_pause_request(state, running_entry, issue_id, identifier, pause_reason)
    end
  end

  defp route_pause_request(state, running_entry, issue_id, identifier, pause_reason) do
    cond do
      pending = matching_pending_pause(state, running_entry, pause_reason) ->
        {{:ok, pending.request_id}, state}

      legacy_control_entry?(running_entry) and is_binary(identifier) ->
        legacy_pause_request(state, running_entry, identifier, pause_reason)

      is_binary(identifier) ->
        submit_pause_request(state, running_entry, issue_id, identifier, pause_reason)

      true ->
        {{:error, :invalid_identifier}, state}
    end
  end

  # Entries created before the correlated protocol do not have the generation,
  # version, and confirmation fields required to make an application claim.
  # Preserve their existing best-effort control behavior without fabricating a
  # lifecycle identity. Dispatcher-created entries always take the correlated
  # path below.
  defp legacy_control_entry?(running_entry) do
    control = Map.get(running_entry, :control, %{})

    Map.has_key?(control, :can_interrupt) and
      not (Map.has_key?(control, :generation) and Map.has_key?(control, :version) and
             Map.has_key?(control, :application_confirmation))
  end

  defp legacy_pause_request(state, running_entry, identifier, pause_reason) do
    reply = send_pause_control_message(state, identifier)
    paused_entry = Map.put(running_entry, :paused_reason, pause_reason)
    {reply, transition_control_status(state, paused_entry, :paused, Atom.to_string(pause_reason))}
  end

  defp adopt_existing_pause(state, running_entry, pause_reason) do
    state = supersede_pending_resume(state, running_entry)
    running_entry = Map.put(running_entry, :paused_reason, pause_reason)
    state = transition_control_status(state, running_entry, :paused, Atom.to_string(pause_reason))
    {{:ok, :already_paused}, state}
  end

  defp supersede_pending_resume(state, running_entry) do
    issue_id = issue_id(running_entry, Map.get(running_entry, :issue))

    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      %{action: :resume, request_id: request_id} ->
        case ControlLifecycle.reject(
               state.control_lifecycle,
               request_id,
               :superseded,
               now: DateTime.utc_now()
             ) do
          {:ok, rejected, lifecycle} ->
            state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
            publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
            state

          {:ignored, lifecycle} ->
            %{state | control_lifecycle: lifecycle}
        end

      _ ->
        state
    end
  end

  defp prepare_pause_request(state, running_entry, supplied_issue) do
    issue = supplied_issue || Map.get(running_entry, :issue)
    issue_id = issue_id(running_entry, issue)
    identifier = Map.get(running_entry, :identifier) || issue_identifier(issue)
    running_entry = replace_running_issue(running_entry, issue)
    state = put_running_entry(state, issue_id, running_entry)
    {state, running_entry, issue_id, identifier}
  end

  defp replace_running_issue(running_entry, %Issue{} = issue), do: Map.put(running_entry, :issue, issue)
  defp replace_running_issue(running_entry, _issue), do: running_entry

  defp submit_pause_request(state, running_entry, issue_id, identifier, pause_reason) do
    requester = pause_requester(pause_reason)
    {reply, state} = submit_control_request(state, running_entry, identifier, :pause, requester)
    remember_pause_request(reply, state, issue_id, pause_reason)
  end

  defp remember_pause_request({:ok, request_id}, state, issue_id, pause_reason) do
    {{:ok, request_id}, put_pending_pause_reason(state, issue_id, request_id, pause_reason)}
  end

  defp remember_pause_request(reply, state, _issue_id, _pause_reason), do: {reply, state}

  # The raw message path remains for the rate-limit fallback's separate
  # checkpoint protocol. All ordinary pause causes use `request_pause/4`.
  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier) do
    OperatorMessages.send_running_control_message(state, issue_identifier, fn request_id ->
      {:pause_agent, request_id}
    end)
  end

  @doc false
  @spec handle_worker_control_state(State.t(), String.t(), :completed | :paused | :working, map()) ::
          {:noreply, State.t()}
  def handle_worker_control_state(%State{running: running} = state, issue_id, status, pause_payload) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        state = expire_pending_control_on_completion(state, running_entry, status)

        case apply_control_evidence(state, running_entry, status, pause_payload) do
          {:ignored, state} ->
            {:noreply, state}

          {:unrelated, state} ->
            apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, nil)

          {:applied, request, state} ->
            apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, request)
        end
    end
  end

  defp apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, request) do
    previous_status = get_in(running_entry, [:control, :status]) || :working
    previous_pause_reason = Map.get(running_entry, :paused_reason)
    pause_reason = worker_pause_reason(running_entry, pause_payload, request)
    transition_cause = control_transition_cause(request, status, pause_reason)

    updated_running_entry =
      running_entry
      |> put_control_status(status)
      |> State.apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())
      |> maybe_put_worker_pause_reason(status, pause_reason)
      |> maybe_clear_control_owned_pause(request, status)
      |> maybe_clear_pending_pause_reason(request, status)

    maybe_log_worker_pause(status, updated_running_entry, pause_reason)
    record_control_transition(updated_running_entry, previous_status, status, transition_cause)

    OperatorMessages.maybe_emit_agent_control_alert(
      previous_status,
      status,
      updated_running_entry,
      if(status == :working, do: previous_pause_reason, else: pause_reason)
    )

    state = %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
    state = finalize_applied_resume(state, issue_id, request)
    state = maybe_auto_resume_spurious_worker_pause(state, updated_running_entry, status)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  defp apply_control_evidence(state, running_entry, status, %{request_id: request_id, generation: generation})
       when is_integer(request_id) and is_integer(generation) do
    case ControlLifecycle.get(state.control_lifecycle, request_id) do
      nil ->
        {:ignored, state}

      request ->
        case control_evidence_outcome(running_entry, status, request) do
          :ignored ->
            {:ignored, state}

          {:rejected, class} ->
            reject_stale_control_evidence(state, running_entry, request, class)

          :applicable ->
            apply_control_request(state, running_entry, request_id, generation)
        end
    end
  end

  defp apply_control_evidence(state, _running_entry, _status, %{request_id: _request_id, generation: _generation}), do: {:ignored, state}
  defp apply_control_evidence(state, _running_entry, _status, _payload), do: {:unrelated, state}

  defp control_evidence_outcome(running_entry, status, request) do
    cond do
      request.issue_id != get_in(running_entry, [:issue, Access.key(:id)]) -> :ignored
      not action_matches_status?(request.action, status) -> :ignored
      not control_confirms_application?(running_entry) -> :ignored
      class = control_rejection_class(running_entry, request) -> {:rejected, class}
      true -> :applicable
    end
  end

  defp control_confirms_application?(running_entry) do
    running_entry
    |> Map.get(:control, %{})
    |> Map.get(:application_confirmation, :request_only)
    |> Kernel.==(:confirmed)
  end

  defp apply_control_request(state, running_entry, request_id, generation) do
    case ControlLifecycle.apply(state.control_lifecycle, request_id, generation, now: DateTime.utc_now()) do
      {:ok, applied, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_control_lifecycle(Map.get(running_entry, :identifier), applied)
        {:applied, applied, state}

      {:ignored, lifecycle} ->
        {:ignored, %{state | control_lifecycle: lifecycle}}
    end
  end

  defp control_rejection_class(running_entry, request) do
    control = Map.get(running_entry, :control, %{})

    cond do
      Map.get(control, :generation) != request.generation -> :stale_generation
      Map.get(control, :status, :working) != request.expected_status -> :already_in_state
      Map.get(control, :version, 0) != request.expected_version -> :already_in_state
      true -> nil
    end
  end

  defp reject_stale_control_evidence(state, running_entry, request, class) do
    case ControlLifecycle.reject(state.control_lifecycle, request.request_id, class, now: DateTime.utc_now()) do
      {:ok, rejected, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
        {:ignored, state}

      {:ignored, lifecycle} ->
        {:ignored, %{state | control_lifecycle: lifecycle}}
    end
  end

  defp expire_pending_control_on_completion(state, _running_entry, status) when status != :completed, do: state

  defp expire_pending_control_on_completion(state, running_entry, :completed) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      nil ->
        state

      pending ->
        case ControlLifecycle.expire(state.control_lifecycle, pending.request_id, :worker_unavailable, now: DateTime.utc_now()) do
          {:ok, expired, lifecycle} ->
            state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
            publish_control_lifecycle(Map.get(running_entry, :identifier), expired)
            state

          {:ignored, lifecycle} ->
            %{state | control_lifecycle: lifecycle}
        end
    end
  end

  defp action_matches_status?(:pause, :paused), do: true
  defp action_matches_status?(:resume, :working), do: true
  defp action_matches_status?(_action, _status), do: false

  defp put_control_status(running_entry, status) do
    control = Map.get(running_entry, :control, %{})
    current_status = Map.get(control, :status, :working)

    control =
      control
      |> Map.put(:status, status)
      |> maybe_increment_control_version(current_status, status)

    Map.put(running_entry, :control, control)
  end

  defp maybe_increment_control_version(control, status, status), do: control

  defp maybe_increment_control_version(control, _previous_status, _status) do
    if Map.has_key?(control, :version), do: Map.update!(control, :version, &(&1 + 1)), else: control
  end

  defp maybe_clear_control_owned_pause(running_entry, %{action: :resume}, :working) do
    if Map.get(running_entry, :paused_reason) in [
         :agent_pause_request,
         :ci_wait,
         :global_pause,
         :input_required,
         :label_override,
         :operator_pause,
         :pause_containment,
         :blocker_dependency
       ] do
      Map.delete(running_entry, :paused_reason)
    else
      running_entry
    end
  end

  defp maybe_clear_control_owned_pause(running_entry, _request, _status), do: running_entry

  defp maybe_clear_pending_pause_reason(running_entry, %{action: :pause, request_id: request_id}, :paused) do
    case Map.get(running_entry, :pending_pause_reason) do
      %{request_id: ^request_id} -> Map.delete(running_entry, :pending_pause_reason)
      _ -> running_entry
    end
  end

  defp maybe_clear_pending_pause_reason(running_entry, %{action: :resume}, :working),
    do: Map.delete(running_entry, :pending_pause_reason)

  defp maybe_clear_pending_pause_reason(running_entry, _request, _status), do: running_entry

  defp control_transition_cause(%{action: :resume, requester: :operator}, :working, _pause_reason),
    do: :operator_resume

  defp control_transition_cause(%{action: :resume}, :working, _pause_reason), do: :automatic_resume
  defp control_transition_cause(_request, _status, pause_reason), do: pause_reason

  defp finalize_applied_resume(state, issue_id, %{action: :resume, requester: requester}) do
    now = DateTime.utc_now()
    operator? = requester == :operator

    state
    |> PushRouting.finalize_applied_resume(issue_id)
    |> update_in([Access.key(:running)], &reset_last_codex_timestamp(&1, issue_id, now))
    |> update_in([Access.key(:running)], &reset_duration_clock_if_capped(&1, issue_id, now, operator?))
    |> then(fn state -> if operator?, do: Dispatcher.reset_thrash_budget(state, issue_id), else: state end)
  end

  defp finalize_applied_resume(state, _issue_id, _request), do: state

  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(%State{} = state, running_entry, new_status, reason) do
    previous_pause_reason = Map.get(running_entry, :paused_reason)
    running_entry = normalize_pause_context(running_entry, new_status)
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    identifier = Map.get(running_entry, :identifier)
    existing = Map.get(running_entry, :control, %{})
    old_status = Map.get(existing, :status, :working)

    if old_status == new_status do
      %{state | running: Map.put(state.running, issue_id, running_entry)}
    else
      Logger.info("Control status: identifier=#{identifier} #{old_status} -> #{new_status} reason=#{reason}")

      now = DateTime.utc_now()

      next_entry =
        running_entry
        |> put_control_status(new_status)
        |> State.apply_pause_runtime_clock(old_status, new_status, now)

      next_state = %{state | running: Map.put(state.running, issue_id, next_entry)}
      record_control_transition(next_entry, old_status, new_status, reason)
      OperatorMessages.maybe_emit_agent_control_alert(old_status, new_status, next_entry, previous_pause_reason)
      StatusReport.notify_dashboard(next_state)
      next_state
    end
  end

  defp normalize_pause_context(running_entry, :paused) do
    if Map.get(running_entry, :paused_reason) == :blocker_dependency do
      running_entry
    else
      running_entry
      |> Map.delete(:blocker_pause)
      |> Map.delete(:pending_auto_resume)
    end
  end

  defp normalize_pause_context(running_entry, _status), do: running_entry

  @doc false
  @spec replace_completed_issue(State.t(), map(), Issue.t()) :: State.t()
  def replace_completed_issue(%State{} = state, running_entry, %Issue{} = issue) do
    if State.completed_provenance?(running_entry) do
      revalidate_completed_replacement(state, running_entry, issue)
    else
      state
    end
  end

  defp normalize_completed_entry(running_entry, issue) do
    running_entry
    |> Map.put(:issue, issue)
    |> Map.put(:completed_provenance, true)
    |> Map.delete(:paused_reason)
    |> put_in([:control, :status], :completed)
  end

  defp revalidate_completed_replacement(state, running_entry, issue) do
    case Dispatcher.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, refreshed_issue} ->
        dispatch_completed_replacement(state, running_entry, refreshed_issue)

      {:skip, %Issue{} = refreshed_issue} ->
        Reconciler.refresh_running_entry_issue(state, refreshed_issue, running_entry)

      {:skip, :missing} ->
        state

      {:error, reason} ->
        Logger.warning("Completed runner replacement skipped; issue refresh failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        state
    end
  end

  @doc false
  @spec dispatch_completed_replacement(State.t(), map(), Issue.t(), keyword()) :: State.t()
  def dispatch_completed_replacement(state, running_entry, issue, opts \\ []) do
    running_entry = normalize_completed_entry(running_entry, issue)

    state =
      state
      |> Map.update!(:running, &Map.put(&1, issue.id, running_entry))
      |> Aiur.Orchestrator.cancel_ci_wait_rewake(issue.id)

    worker_host = Map.get(running_entry, :worker_host)

    if Slots.dispatch_slots_available?(issue, state) do
      admit = Keyword.get(opts, :admit_fun, &Dispatcher.admit_redispatch/3)
      replace = Keyword.get(opts, :replace_fun, &replace_completed_entry/4)

      case admit.(state, issue, worker_host) do
        {:ok, admitted_state} ->
          replace.(admitted_state, running_entry, issue, worker_host)

        {:error, _reason, rejected_state} ->
          rejected_state
      end
    else
      state
    end
  end

  # This is the single funnel every recycle re-dispatch goes through: the runner
  # reached its completed boundary (max_turns, or a replacement) while the issue
  # was still active, so the ticket already has a branch, workspace, and workpad.
  # Flag it as prior work so a thread that cannot be resumed continues from that
  # handoff instead of cold-starting brainstorm/plan over existing work.
  defp replace_completed_entry(state, running_entry, issue, worker_host) do
    prior_work? = Config.agent_prior_work_continuation?()

    replace_admitted_completed_entry(
      state,
      running_entry,
      issue,
      worker_host,
      fn dispatch_state, dispatch_issue, attempt, host ->
        Dispatcher.do_dispatch_issue(dispatch_state, dispatch_issue, attempt, host, prior_work: prior_work?)
      end
    )
  end

  @doc false
  @spec replace_admitted_completed_entry(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          State.t()
  def replace_admitted_completed_entry(
        state,
        running_entry,
        issue,
        worker_host,
        dispatch_fun
      )
      when is_function(dispatch_fun, 4) do
    issue_id = issue.id

    Logger.info("Replacing completed runner: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

    _ = Aiur.PauseContainment.release_target(issue.identifier || issue.id)

    next_state =
      state
      |> AgentTeardown.terminate_running_issue(issue_id, false)
      |> dispatch_fun.(issue, nil, worker_host)

    if live_replacement?(next_state, issue_id) do
      next_state
    else
      restore_completed_entry(next_state, running_entry, issue)
    end
  end

  defp live_replacement?(state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pid: pid, ref: ref, control: %{status: :working}} ->
        is_pid(pid) and Process.alive?(pid) and is_reference(ref)

      _ ->
        false
    end
  end

  defp restore_completed_entry(state, running_entry, issue) do
    issue_id = issue.id

    completed_entry =
      running_entry
      |> Map.put(:issue, issue)
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completed_provenance, true)
      |> Map.put(:completion_totals_recorded, true)
      |> put_in([:control, :status], :completed)

    %{
      state
      | running: Map.put(state.running, issue_id, completed_entry),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp restart_completed_issue(state, running_entry) do
    issue = Map.fetch!(running_entry, :issue)
    next_state = replace_completed_issue(state, running_entry, issue)

    if live_replacement?(next_state, issue.id) do
      {{:ok, :started}, next_state}
    else
      {{:error, :redispatch_deferred}, next_state}
    end
  end

  defp restart_completed_provenance_issue(state, running_entry),
    do: restart_completed_issue(state, running_entry)

  defp do_reactivate(%State{} = state, running_entry) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    existing_control = Map.get(running_entry, :control, %{})
    worker_host = Map.get(running_entry, :worker_host)
    issue = Map.get(running_entry, :issue)

    # Flip the entry to :working before dispatch so any concurrent
    # slot-count lookups see this entry as holding a slot (prevents a
    # double-claim race against another dispatch tick).
    new_entry = Map.put(running_entry, :control, Map.put(existing_control, :status, :working))
    state = %{state | running: Map.put(state.running, issue_id, new_entry)}
    state = TrackedSet.refresh(state)

    Logger.info("Reactivating deactivated issue: identifier=#{Map.get(running_entry, :identifier)}; spawning fresh agent task")

    # Reactivation is a deliberate Executor restart; clear the thrash
    # budget so the fresh task starts with a full window.
    state = Dispatcher.reset_thrash_budget(state, issue_id)

    dispatched_state =
      Dispatcher.do_dispatch_issue(state, issue, nil, worker_host, prior_work: Config.agent_prior_work_continuation?())

    case Map.get(dispatched_state.running, issue_id) do
      %{pid: pid} when is_pid(pid) ->
        unless DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
          record_control_transition(running_entry, Map.get(existing_control, :status), :working, :reactivation)
        end

        {{:ok, :reactivated}, dispatched_state}

      _ ->
        # `select_worker_host/2`, the thrash breaker, or Task.Supervisor can
        # decline a dispatch after the entry is optimistically made `:working`.
        # Restore the parked entry so the tracker still shows it as needing a
        # wake and the comment path can emit its durable Executor alert.
        restored_state = %{dispatched_state | running: Map.put(dispatched_state.running, issue_id, running_entry)}
        {{:error, :dispatch_not_started}, TrackedSet.refresh(restored_state)}
    end
  end

  # `operator?` distinguishes a deliberate Executor resume (label flip,
  # chat reply) from an automated/blocker auto-resume. It only matters
  # for a duration-capped pause: an Executor resume is "check in, keep
  # going" and earns a fresh budget; an automated resume must PRESERVE
  # the cumulative overrun so a runaway is still bounded (see
  # `reset_duration_clock_if_capped/4`). Defaults to Executor so the
  # Executor-facing callers stay unchanged.
  @doc false
  @spec resume_paused_issue(State.t(), map(), boolean()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_paused_issue(%State{} = state, running_entry, operator? \\ true) do
    case resume_paused_issue_preflight(state, running_entry) do
      :ok -> send_resume_control_message(state, running_entry, operator?)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @doc false
  @spec resume_paused_issue_preflight(State.t(), map()) :: :ok | {:error, :max_concurrent_agents_reached}
  def resume_paused_issue_preflight(%State{} = state, running_entry) do
    cond do
      # A CI-wait pause releases its reservation; other pauses retain one.
      # In both cases, resume must wait if the active count is already at the
      # cap (for example, after CI-wait capacity was filled by other work).
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {:error, :max_concurrent_agents_reached}

      not DispatchPolicy.state_slots_available?(Map.get(running_entry, :issue), state) ->
        {:error, :max_concurrent_agents_reached}

      not Slots.resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
        {:error, :max_concurrent_agents_reached}

      true ->
        :ok
    end
  end

  defp send_resume_control_message(%State{} = state, running_entry, operator?) do
    if legacy_control_entry?(running_entry) do
      send_legacy_resume_control_message(state, running_entry, operator?)
    else
      requester = if operator?, do: :operator, else: :automatic

      case submit_resume_control_request(state, running_entry, requester) do
        {{:ok, _request_id}, state} ->
          {{:ok, :resumed}, state}

        {error, state} ->
          {error, state}
      end
    end
  end

  defp send_legacy_resume_control_message(%State{} = state, running_entry, operator?) do
    case OperatorMessages.send_running_control_message(state, Map.get(running_entry, :identifier), fn request_id ->
           {:resume_agent, request_id}
         end) do
      {:ok, _request_id} ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        previous_status = get_in(running_entry, [:control, :status]) || :working
        now = DateTime.utc_now()

        state = put_running_control_status(state, issue_id, :working)
        state = update_in(state.running, &State.thaw_pause_clock(&1, issue_id, previous_status, now))
        state = update_in(state.running, &reset_last_codex_timestamp(&1, issue_id, now))
        state = update_in(state.running, &reset_duration_clock_if_capped(&1, issue_id, now, operator?))
        state = update_in(state.running, &clear_legacy_pause_reason(&1, issue_id))
        state = Dispatcher.reset_thrash_budget(state, issue_id)

        updated_entry = Map.get(state.running, issue_id, running_entry)
        resume_cause = if operator?, do: :operator_resume, else: :automatic_resume
        record_control_transition(updated_entry, previous_status, :working, resume_cause)

        OperatorMessages.maybe_emit_agent_control_alert(
          previous_status,
          :working,
          updated_entry,
          Map.get(running_entry, :paused_reason)
        )

        {{:ok, :resumed}, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp clear_legacy_pause_reason(running, issue_id) do
    case Map.get(running, issue_id) do
      entry when is_map(entry) -> Map.put(running, issue_id, Map.delete(entry, :paused_reason))
      _ -> running
    end
  end

  defp submit_resume_control_request(%State{} = state, running_entry, requester, request_id \\ nil) do
    if Map.get(running_entry, :control, %{}) |> Map.get(:status, :working) == :paused do
      cond do
        State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
          {{:error, :max_concurrent_agents_reached}, state}

        not DispatchPolicy.state_slots_available?(Map.get(running_entry, :issue), state) ->
          {{:error, :max_concurrent_agents_reached}, state}

        not Slots.resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
          {{:error, :max_concurrent_agents_reached}, state}

        true ->
          submit_control_request(
            state,
            running_entry,
            Map.get(running_entry, :identifier),
            :resume,
            requester,
            request_id
          )
      end
    else
      submit_control_request(
        state,
        running_entry,
        Map.get(running_entry, :identifier),
        :resume,
        requester,
        request_id
      )
    end
  end

  defp submit_control_request(%State{} = state, running_entry, issue_identifier, action, requester, request_id \\ nil)
       when action in [:pause, :resume] and is_binary(issue_identifier) and is_atom(requester) do
    case control_request_id(request_id) do
      {:ok, assigned_request_id} ->
        submit_control_request_with_id(state, running_entry, issue_identifier, action, requester, assigned_request_id)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp control_request_id(nil), do: next_control_request_id()
  defp control_request_id(request_id), do: {:ok, request_id}

  defp retry_control_reply(%{status: status, request_id: request_id}) when status in [:requested, :accepted, :applied],
    do: {:ok, request_id}

  defp retry_control_reply(%{status: :rejected, rejection: rejection}),
    do: {:error, {:control_rejected, rejection}}

  defp retry_control_reply(%{status: :expired, expiry: expiry}), do: {:error, {:control_expired, expiry}}

  defp submit_control_request_with_id(%State{} = state, running_entry, issue_identifier, action, requester, request_id) do
    control = Map.get(running_entry, :control, %{})

    attrs = %{
      request_id: request_id,
      issue_id: get_in(running_entry, [:issue, Access.key(:id)]),
      tracker_identity: Issue.tracker_identity(Map.get(running_entry, :issue)),
      action: action,
      generation: Map.get(control, :generation),
      expected_status: Map.get(control, :status, :working),
      expected_version: Map.get(control, :version, 0),
      requester: requester
    }

    pending = ControlLifecycle.current_pending(state.control_lifecycle, attrs.issue_id)

    case ControlLifecycle.request(state.control_lifecycle, attrs, now: DateTime.utc_now()) do
      {:duplicate, request, lifecycle} ->
        {retry_control_reply(request), %{state | control_lifecycle: lifecycle}}

      {:error, _rejection, lifecycle} ->
        {{:error, :control_request_conflict}, %{state | control_lifecycle: lifecycle}}

      {:ok, request, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_superseded_control_lifecycle(issue_identifier, pending, lifecycle)
        publish_control_lifecycle(issue_identifier, request)

        case preflight_rejection(control, action, pending) do
          nil -> route_admitted_control_request(state, issue_identifier, request)
          class -> reject_admitted_control_request(state, issue_identifier, request, class)
        end
    end
  end

  defp preflight_rejection(control, :pause, %{action: :resume}) do
    if Map.get(control, :application_confirmation, :request_only) == :confirmed,
      do: nil,
      else: :unsupported
  end

  defp preflight_rejection(control, :pause, _pending) do
    cond do
      Map.get(control, :status, :working) == :paused -> :already_in_state
      Map.get(control, :status, :working) not in [:working, :paused] -> :not_eligible
      Map.get(control, :application_confirmation, :request_only) != :confirmed -> :unsupported
      true -> nil
    end
  end

  defp preflight_rejection(control, :resume, %{action: :pause}) do
    if Map.get(control, :application_confirmation, :request_only) == :confirmed,
      do: nil,
      else: :unsupported
  end

  defp preflight_rejection(control, :resume, _pending) do
    cond do
      Map.get(control, :status, :working) == :working -> :already_in_state
      Map.get(control, :status, :working) not in [:working, :paused] -> :not_eligible
      Map.get(control, :application_confirmation, :request_only) != :confirmed -> :unsupported
      true -> nil
    end
  end

  defp reject_admitted_control_request(state, issue_identifier, request, class) do
    case ControlLifecycle.reject(state.control_lifecycle, request.request_id, class, now: DateTime.utc_now()) do
      {:ok, rejected, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_control_lifecycle(issue_identifier, rejected)
        {{:error, {:control_rejected, rejected.rejection}}, state}

      {:ignored, lifecycle} ->
        {{:error, {:control_rejected, %{class: class}}}, %{state | control_lifecycle: lifecycle}}
    end
  end

  defp route_admitted_control_request(state, issue_identifier, request) do
    case OperatorMessages.send_running_control_message(state, issue_identifier, request.request_id, fn _request_id ->
           control_message(request.action, request)
         end) do
      {:ok, request_id} ->
        accept_admitted_control_request(state, issue_identifier, request, request_id)

      {:error, reason} ->
        state = reject_routing_failure(state, request.request_id, reason)

        case ControlLifecycle.get(state.control_lifecycle, request.request_id) do
          nil -> :ok
          rejected -> publish_control_lifecycle(issue_identifier, rejected)
        end

        {{:error, reason}, state}
    end
  end

  defp accept_admitted_control_request(state, issue_identifier, request, request_id) do
    case ControlLifecycle.accept(state.control_lifecycle, request_id, request.generation, now: DateTime.utc_now()) do
      {:ok, accepted, lifecycle} ->
        arm_pause_containment(request, issue_identifier)
        publish_control_lifecycle(issue_identifier, accepted)
        {{:ok, request_id}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}

      {:ignored, lifecycle} ->
        {{:error, :stale_generation}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}
    end
  end

  defp arm_pause_containment(%{action: :pause}, issue_identifier), do: Aiur.PauseContainment.arm(issue_identifier)
  defp arm_pause_containment(_request, _issue_identifier), do: :ok

  defp next_control_request_id do
    case IdGenerator.reserve_durable_id() do
      {:ok, request_id} -> {:ok, request_id}
      {:error, :not_durable} -> {:error, :control_id_unavailable}
    end
  catch
    :exit, _ -> {:error, :control_id_unavailable}
  end

  defp control_message(:pause, request) do
    {:pause_agent, request.request_id, request.generation}
  end

  defp control_message(:resume, request) do
    {:resume_agent, request.request_id, request.generation}
  end

  defp reject_routing_failure(state, request_id, reason) do
    class = if reason in [:agent_finished, :no_running_agent], do: :worker_unavailable, else: :control_failed

    case ControlLifecycle.reject(state.control_lifecycle, request_id, class, now: DateTime.utc_now()) do
      {:ok, _request, lifecycle} -> %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
      {:ignored, lifecycle} -> %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
    end
  end

  defp persist_control_lifecycle(%State{} = state) do
    :ok = ControlLifecycleStore.save(state.control_lifecycle)
    state
  end

  defp publish_control_lifecycle(identifier, request) when is_binary(identifier) and is_map(request) do
    AgentPubSub.broadcast_control_lifecycle(identifier, ControlLifecycle.event_payload(request))
  end

  defp publish_control_lifecycle(_identifier, _request), do: :ok

  defp publish_superseded_control_lifecycle(identifier, %{request_id: request_id}, lifecycle) do
    case ControlLifecycle.get(lifecycle, request_id) do
      %{status: :rejected, rejection: %{class: :superseded}} = request ->
        publish_control_lifecycle(identifier, request)

      _ ->
        :ok
    end
  end

  defp publish_superseded_control_lifecycle(_identifier, _pending, _lifecycle), do: :ok

  defp record_control_transition(_running_entry, status, status, _cause), do: :ok

  defp record_control_transition(running_entry, _old_status, :paused, cause) do
    Lifecycle.record(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_pause,
      :point,
      %{cause: cause}
    )
  end

  defp record_control_transition(running_entry, old_status, :working, cause)
       when old_status in [:paused, :deactivated] do
    Lifecycle.record(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_resume,
      :point,
      %{cause: cause}
    )
  end

  defp record_control_transition(_running_entry, _old_status, _new_status, _cause), do: :ok

  @doc false
  @spec reset_last_codex_timestamp(map(), term(), DateTime.t()) :: map()
  def reset_last_codex_timestamp(running, issue_id, %DateTime{} = now) when is_map(running) do
    case Map.get(running, issue_id) do
      entry when is_map(entry) ->
        Map.put(running, issue_id, Map.put(entry, :last_codex_timestamp, now))

      _ ->
        running
    end
  end

  # Resume-side handling for a duration-capped pause. Only this control path
  # owns the `:max_agent_duration` marker; other pause/wait reasons must stay
  # intact until the subsystem that created them clears them.
  #
  # `operator?: true` ALSO restarts the duration baseline (`started_at` ->
  # now) so an Executor resume hands the agent a full fresh budget.
  #
  # `operator?: false` PRESERVES `started_at` (the cumulative overrun) so an
  # automated/blocker auto-resume cannot silently reset the budget: the
  # entry resumes already over the cap and the next overrun tick re-pauses
  # it, which is the runaway safety net — a wedged duration-capped agent
  # that keeps getting auto-resumed on blocker unblocked signals stays bounded
  # instead of running forever.
  #
  # Label-override pauses have no special duration semantics; resuming just
  # clears their attribution marker after the normal pause-clock thaw.
  #
  # A no-op for manually/blocker-paused entries (no marker).
  @doc false
  @spec reset_duration_clock_if_capped(map(), term(), DateTime.t(), boolean()) :: map()
  def reset_duration_clock_if_capped(running, issue_id, %DateTime{} = now, operator?)
      when is_map(running) do
    case Map.get(running, issue_id) do
      %{paused_reason: :max_agent_duration} = entry ->
        updated =
          entry
          |> maybe_reset_started_at(now, operator?)
          |> Map.delete(:paused_reason)

        Map.put(running, issue_id, updated)

      _ ->
        running
    end
  end

  defp maybe_reset_started_at(entry, now, true), do: Map.put(entry, :started_at, now)
  defp maybe_reset_started_at(entry, _now, false), do: entry

  defp maybe_auto_resume_spurious_worker_pause(
         state,
         %{paused_reason: reason} = running_entry,
         :paused
       )
       when reason in [:input_required, :worker_pause_unknown, :pause_containment] do
    case resume_paused_issue(state, running_entry) do
      {{:ok, :resumed}, state} ->
        state

      {{:error, reason}, state} ->
        Logger.warning("orchestrator.pause_resume_deferred issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{Map.get(running_entry, :paused_reason)} reason=#{inspect(reason)}")

        state
    end
  end

  defp maybe_auto_resume_spurious_worker_pause(state, _running_entry, _status), do: state

  defp worker_pause_reason(running_entry, pause_payload, request) do
    pending_pause_reason(running_entry, request) ||
      Map.get(running_entry, :paused_reason) ||
      Map.get(pause_payload, :kind) ||
      Map.get(pause_payload, "kind") ||
      request_pause_reason(request, pause_payload)
  end

  defp request_pause_reason(%{action: :pause, requester: :operator}, _pause_payload), do: :operator_pause
  defp request_pause_reason(%{action: :pause}, _pause_payload), do: :automatic_pause

  defp request_pause_reason(_request, pause_payload) do
    if Map.has_key?(pause_payload, :request_id), do: :pause_containment, else: :worker_pause_unknown
  end

  defp maybe_put_worker_pause_reason(entry, :paused, pause_reason),
    do: Map.put(entry, :paused_reason, pause_reason)

  defp maybe_put_worker_pause_reason(entry, _status, _pause_reason), do: entry

  defp maybe_log_worker_pause(:paused, running_entry, pause_reason) do
    Logger.warning(
      "orchestrator.pause issue_id=#{get_in(running_entry, [:issue, Access.key(:id)])} issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{pause_reason} source=worker_control_state"
    )
  end

  defp maybe_log_worker_pause(_status, _running_entry, _pause_reason), do: :ok

  defp pending_pause_request?(state, running_entry) do
    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id(running_entry, Map.get(running_entry, :issue))) do
      %{action: :pause} -> true
      _ -> false
    end
  end

  defp pending_resume_request?(state, running_entry) do
    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id(running_entry, Map.get(running_entry, :issue))) do
      %{action: :resume} -> true
      _ -> false
    end
  end

  defp resume_pending_pause(state, running_entry) do
    case submit_resume_control_request(state, running_entry, :operator) do
      {{:ok, _request_id}, state} ->
        {{:ok, :resumed}, state}

      {error, state} ->
        {error, state}
    end
  end

  defp matching_pending_pause(state, running_entry, pause_reason) do
    with issue_id when not is_nil(issue_id) <- issue_id(running_entry, Map.get(running_entry, :issue)),
         %{action: :pause} = request <- ControlLifecycle.current_pending(state.control_lifecycle, issue_id),
         %{request_id: request_id, reason: ^pause_reason} <- Map.get(running_entry, :pending_pause_reason),
         true <- request.request_id == request_id do
      request
    else
      _ -> nil
    end
  end

  defp put_pending_pause_reason(state, issue_id, request_id, pause_reason)
       when not is_nil(issue_id) do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        entry when is_map(entry) ->
          Map.put(running, issue_id, Map.put(entry, :pending_pause_reason, %{request_id: request_id, reason: pause_reason}))

        _ ->
          running
      end
    end)
  end

  defp put_pending_pause_reason(state, _issue_id, _request_id, _pause_reason), do: state

  defp pending_pause_reason(running_entry, %{action: :pause, request_id: request_id}) do
    case Map.get(running_entry, :pending_pause_reason) do
      %{request_id: ^request_id, reason: reason} -> reason
      _ -> nil
    end
  end

  defp pending_pause_reason(_running_entry, _request), do: nil

  defp pause_requester(:operator_pause), do: :operator
  defp pause_requester(:agent_pause_request), do: :automatic
  defp pause_requester(_pause_reason), do: :system

  defp issue_id(_running_entry, %Issue{id: issue_id}) when not is_nil(issue_id), do: issue_id
  defp issue_id(running_entry, _issue), do: get_in(running_entry, [:issue, Access.key(:id)])

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp put_running_entry(state, issue_id, running_entry) when not is_nil(issue_id) do
    %{state | running: Map.put(state.running, issue_id, running_entry)}
  end

  defp put_running_entry(state, _issue_id, _running_entry), do: state

  defp resume_queued_issue(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    issue =
      state.last_polled_issues
      |> Map.values()
      |> Enum.find(fn
        %Issue{identifier: ^issue_identifier} -> true
        _ -> false
      end)

    case issue do
      nil ->
        {{:error, :no_running_agent}, state}

      %Issue{} = issue ->
        resume_queued_issue(state, issue)
    end
  end

  defp resume_queued_issue(%State{} = state, %Issue{} = issue) do
    cond do
      # Manual start (Executor pressed space on a queued ticket): paused
      # agents are excluded from the cap so the Executor can fill a free
      # active slot even when a paused agent is parked in `running`.
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      # A lifetime-latched ticket is not resume-clearable by design. Name the
      # latch as the reason instead of letting the dispatch no-op silently and
      # reporting `:dispatch_failed`, which reads as a transient hiccup (#1453).
      match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(state, issue.id)) ->
        {{:error, :lifetime_dispatch_latch}, state}

      true ->
        clear_and_resume_queued_issue(state, issue)
    end
  end

  defp clear_and_resume_queued_issue(state, issue) do
    case clear_tracker_pause_override(state, issue) do
      {:ok, state, issue} ->
        dispatch_resumed_queued_issue(state, issue)

      {:error, reason} ->
        {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  defp dispatch_resumed_queued_issue(state, issue) do
    cond do
      not DispatchPolicy.dispatch_candidate?(
        issue,
        state,
        DispatchPolicy.active_state_set(),
        DispatchPolicy.terminal_state_set()
      ) ->
        {{:error, :not_resumable}, state}

      true ->
        next_state = Dispatcher.dispatch_issue(state, issue)

        cond do
          MapSet.member?(next_state.claimed, issue.id) ->
            {{:ok, :started}, next_state}

          match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(next_state, issue.id)) ->
            {{:error, :lifetime_dispatch_latch}, next_state}

          true ->
            {{:error, :dispatch_failed}, next_state}
        end
    end
  end

  defp clear_pause_override(%{issue: %Issue{} = issue} = running_entry) do
    case clear_pause_override(issue) do
      {:ok, cleared_issue} -> {:ok, Map.put(running_entry, :issue, cleared_issue)}
      {:error, _reason} = error -> error
    end
  end

  defp clear_pause_override(%Issue{} = issue) do
    label = pause_override_label()

    case Tracker.remove_label(issue.identifier, label) do
      :ok ->
        {:ok,
         issue
         |> RemoteControlMode.remove_issue_label(label)
         |> Map.put(:paused, false)}

      {:error, _reason} = error ->
        error
    end
  end

  defp pause_override_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"

  defp pause_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

  defp control_api_call(server, request) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec put_running_control_status(State.t(), String.t(), :paused | :working) :: State.t()
  def put_running_control_status(%State{} = state, issue_id, status)
      when is_binary(issue_id) and status in [:paused, :working] do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        nil -> running
        entry -> Map.put(running, issue_id, put_in(entry, [:control, :status], status))
      end
    end)
  end

  def put_running_control_status(%State{} = state, _issue_id, _status), do: state
end
