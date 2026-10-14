defmodule Aiur.Orchestrator.PauseResume.ControlCalls do
  @moduledoc """
  Orchestrator call handlers for pause, control requests, the global pause switch, and control expiry.
  """

  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.PauseResume.ControlRequest
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.State
  alias Aiur.TrackerIdentity
  require Logger

  # Attribution marker for agents held by the global pause switch, distinct
  # from every per-agent pause reason. Unpause resumes only these entries, so
  # an operator's individual pause is never overridden. See `Aiur.Orchestrator.GlobalPause`.
  @global_pause_reason :global_pause

  @spec pause_agent_call(State.t(), String.t() | TrackerIdentity.t()) :: {:reply, term(), State.t()}
  def pause_agent_call(%State{globally_paused: true} = state, _issue_identifier),
    do: {:reply, {:error, :globally_paused}, state}

  def pause_agent_call(%State{} = state, issue_identifier) do
    guard_control_call(state, :pause, issue_identifier, fn ->
      {reply, state} = PauseRequest.pause_agent_reply(state, issue_identifier)
      {:reply, reply, state}
    end)
  end

  @doc false
  # Operator control calls run inside the Orchestrator GenServer, and that
  # process holds the agent registry (`state.running`). An exception raised
  # while handling one used to crash the Orchestrator: the supervisor restarted
  # it with an empty registry, so a live worker it did not re-adopt ran on
  # untracked (#2699). A control call is an operator request, never a reason
  # to lose the registry. Reply with a named error instead and keep the state
  # from before the call, because a handler that raised part way through
  # leaves no state that is safe to keep.
  #
  # The rollback covers in-memory Orchestrator state only. Side effects the
  # handler completed before it raised are not undone: a tracker label it
  # already changed stays changed, and a dispatch task it already spawned keeps
  # running without a registry entry (orphan adoption is #2705). That is why a
  # crash also raises an operator alert, not only a log line.
  @spec guard_control_call(State.t(), atom(), term(), (-> {:reply, term(), State.t()})) ::
          {:reply, term(), State.t()}
  def guard_control_call(%State{} = state, action, target, fun) when is_atom(action) and is_function(fun, 0) do
    fun.()
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      summary = control_crash_summary(kind, reason, stacktrace)

      Logger.error(
        "Operator #{action} control call failed for #{control_target_label(target)}; the orchestrator kept its agent registry: " <>
          Exception.format(kind, reason, stacktrace)
      )

      emit_control_crash_alert(action, target, summary)
      {:reply, {:error, {:control_call_crashed, action, summary}}, state}
  end

  @doc false
  @spec emit_control_crash_alert(term(), term(), term()) :: term()
  def emit_control_crash_alert(action, target, summary) do
    label = control_target_label(target)

    Alerts.emit_custom(
      "ticket.#{label}.agent.attention.control-call-crashed",
      "Operator #{action} of #{label} crashed inside the orchestrator (#{summary}). The agent registry was kept, " <>
        "but side effects the call made before it crashed (tracker labels, a started worker) were not undone; check the ticket.",
      issue: label,
      reason: summary,
      needs_attention: true,
      severity: "warning",
      event_source: :system
    )
  rescue
    exception ->
      Logger.warning("Control-call crash alert could not be emitted: #{Exception.message(exception)}")
      :ok
  end

  defp control_target_label(%TrackerIdentity{identifier: identifier}) when is_binary(identifier), do: identifier
  defp control_target_label(target) when is_binary(target), do: target
  defp control_target_label(target), do: inspect(target)

  @doc false
  @spec control_crash_summary(term(), term(), term()) :: term()
  def control_crash_summary(:error, reason, stacktrace) do
    :error
    |> Exception.normalize(reason, stacktrace)
    |> Exception.message()
    |> String.slice(0, 300)
  end

  def control_crash_summary(kind, reason, _stacktrace), do: "#{kind}: #{inspect(reason, limit: 20, printable_limit: 200)}"

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
    guard_control_call(state, action, issue_identifier, fn ->
      request_running_control(state, issue_identifier, action, request_id)
    end)
  end

  defp request_running_control(state, issue_identifier, action, request_id) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        {reply, state} =
          case action do
            :pause -> ControlRequest.submit_control_request(state, running_entry, issue_identifier, :pause, :operator, request_id)
            :resume -> ControlRequest.submit_resume_control_request(state, running_entry, :operator, request_id)
          end

        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  @doc false
  @spec pause_running_for_global(State.t()) :: State.t()
  def pause_running_for_global(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.reduce(state, fn entry, state ->
      if globally_pausable?(state, entry) do
        {_reply, state} = PauseRequest.request_pause(state, entry, Map.get(entry, :issue), @global_pause_reason)
        state
      else
        state
      end
    end)
  end

  @doc false
  @spec resume_running_from_global(State.t()) :: State.t()
  @spec resume_running_from_global(State.t(), keyword()) :: State.t()
  def resume_running_from_global(%State{} = state, opts \\ []) do
    backends = Keyword.get(opts, :backends, DispatchPolicy.read_provider_backends())
    ModelAvailability.probe_stale_limits(backends, opts)

    state.running
    |> Enum.filter(fn {_id, entry} -> globally_held?(state, entry) end)
    |> Enum.reduce(state, fn {_id, entry}, state ->
      if tracker_pause_override?(entry) do
        preserve_tracker_pause_after_global_hold(state, entry)
      else
        {_reply, state} =
          Resume.resume_issue_with_opts(state, Map.get(entry, :identifier), Keyword.put(opts, :probe_provider_limits?, false))

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

    Resume.put_running_entry(state, issue_id, entry)
  end

  defp update_pending_global_pause_reason(%{pending_pause_reason: %{reason: @global_pause_reason} = pending} = entry),
    do: %{entry | pending_pause_reason: %{pending | reason: :label_override}}

  defp update_pending_global_pause_reason(entry), do: entry

  defp globally_pausable?(state, entry) do
    not State.paused_running_entry?(entry) and
      not State.deactivated_running_entry?(entry) and
      not State.completed_provenance?(entry) and
      not PauseRequest.pending_pause_request?(state, entry)
  end

  defp globally_held?(state, entry) do
    applied_global_hold?(entry) or pending_global_hold?(state, entry)
  end

  defp applied_global_hold?(entry) do
    State.paused_running_entry?(entry) and Map.get(entry, :paused_reason) == @global_pause_reason
  end

  defp pending_global_hold?(state, entry) do
    PauseRequest.pending_pause_request?(state, entry) and
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
      state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle()

      Enum.each(expired, &publish_expired_control(state, &1))

      Enum.reduce(expired, state, &PauseResume.drop_stale_pending_pause_reason(&2, &1.issue_id))
    end
  end

  defp publish_expired_control(state, request) do
    case Map.get(state.running, request.issue_id) do
      %{identifier: identifier} when is_binary(identifier) -> ControlRequest.publish_control_lifecycle(identifier, request)
      _ -> :ok
    end
  end
end
