defmodule Aiur.Orchestrator.PauseResume do
  @moduledoc """
  Owns the pause, resume, and reactivation state machine for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.PauseResume.Clocks
  alias Aiur.Orchestrator.PauseResume.CompletedReplacement
  alias Aiur.Orchestrator.PauseResume.ControlCalls
  alias Aiur.Orchestrator.PauseResume.ControlRequest
  alias Aiur.Orchestrator.PauseResume.DeclineReason
  alias Aiur.Orchestrator.PauseResume.LabelOverride
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.QueuedDispatch
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PauseResume.TrackerControl
  alias Aiur.Orchestrator.PauseResume.WorkerControl
  alias Aiur.Orchestrator.State
  alias Aiur.TrackerIdentity

  # Pause reasons that mean the worker itself is waiting for input (#2730).
  @input_pause_reasons [:agent_pause_request, :input_required]

  @doc false
  @spec input_pause_reason?(term()) :: boolean()
  def input_pause_reason?(reason), do: reason in @input_pause_reasons

  @doc """
  Returns the entry's recorded pause reason only while its pause request is
  still the issue's current pending control. A reason left by an expired,
  rejected, or superseded request returns nil (#2730).
  """
  @spec current_pending_pause_reason(State.t(), map() | nil) :: atom() | nil
  def current_pending_pause_reason(%State{} = state, running_entry) when is_map(running_entry) do
    with %{reason: reason} <- Map.get(running_entry, :pending_pause_reason),
         %{action: :pause} <- PauseRequest.matching_pending_pause(state, running_entry, reason) do
      reason
    else
      _ -> nil
    end
  end

  def current_pending_pause_reason(%State{}, _running_entry), do: nil

  # Deletes `pending_pause_reason` once its pause request is no longer the
  # issue's current pending control (it expired, was rejected, or a newer
  # request superseded it and then resolved).
  @doc false
  @spec drop_stale_pending_pause_reason(State.t(), term()) :: State.t()
  def drop_stale_pending_pause_reason(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pending_pause_reason: %{}} = entry ->
        if current_pending_pause_reason(state, entry),
          do: state,
          else: %{state | running: Map.put(state.running, issue_id, Map.delete(entry, :pending_pause_reason))}

      _ ->
        state
    end
  end

  @spec pause_agent(String.t() | TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(issue_identifier), do: pause_agent(Aiur.Orchestrator, issue_identifier)

  @spec pause_agent(GenServer.server(), String.t() | TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, issue_identifier),
    do: control_api_call(server, {:pause_agent, issue_identifier})

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started | :reactivated} | {:error, term()}
  def resume_agent(issue_identifier), do: resume_agent(Aiur.Orchestrator, issue_identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started | :reactivated} | {:error, term()}
  def resume_agent(server, issue_identifier),
    do: resume_api_call(server, {:resume_agent, issue_identifier})

  @spec resume_agent_with_receipt(String.t()) ::
          {:ok, :resumed | :started | :reactivated | {:resumed, pos_integer()}} | {:error, term()}
  def resume_agent_with_receipt(issue_identifier),
    do: resume_agent_with_receipt(Aiur.Orchestrator, issue_identifier)

  @spec resume_agent_with_receipt(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started | :reactivated | {:resumed, pos_integer()}} | {:error, term()}
  def resume_agent_with_receipt(server, issue_identifier),
    do: resume_api_call(server, {:resume_agent_with_receipt, issue_identifier})

  # `reset-budget <id>` is the documented exit from the lifetime dispatch
  # latch. It runs as a synchronous orchestrator call so the CLI reports the
  # ACTUAL outcome (cleared, or a failure reason) rather than an unverifiable
  # "queued" at enqueue time. A fire-and-forget cast reported success while the
  # counter stayed unchanged for tickets the orchestrator could not resolve —
  # a surface claiming confident success for something that did not happen
  # (#2435).
  @spec reset_dispatch_budget(String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(issue_identifier), do: reset_dispatch_budget(Aiur.Orchestrator, issue_identifier)

  @spec reset_dispatch_budget(GenServer.server(), String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(server, issue_identifier) when is_binary(issue_identifier) and issue_identifier != "" do
    control_api_call(server, {:reset_dispatch_budget, issue_identifier})
  end

  def reset_dispatch_budget(_server, _issue_identifier), do: {:error, :invalid_identifier}

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

  @doc false
  @spec tracker_control_call(State.t(), atom(), String.t(), term(), term()) :: {:reply, term(), State.t()}
  defdelegate tracker_control_call(state, action, identifier, stage \\ :start, result \\ nil), to: TrackerControl

  @doc false
  @spec pause_agent_call(State.t(), String.t() | TrackerIdentity.t()) :: {:reply, term(), State.t()}
  defdelegate pause_agent_call(state, issue_identifier), to: ControlCalls

  @doc false
  @spec guard_control_call(State.t(), atom(), term(), (-> {:reply, term(), State.t()})) ::
          {:reply, term(), State.t()}
  defdelegate guard_control_call(state, action, target, fun), to: ControlCalls

  @doc false
  @spec request_control_call(State.t(), String.t(), :pause | :resume, pos_integer()) ::
          {:reply, {:ok, pos_integer()} | {:error, term()}, State.t()}
  defdelegate request_control_call(state, issue_identifier, action, request_id), to: ControlCalls

  @doc false
  @spec control_lifecycle_call(State.t(), String.t()) :: {:reply, {:ok, map()} | {:error, term()}, State.t()}
  defdelegate control_lifecycle_call(state, issue_identifier), to: ControlCalls

  @doc false
  @spec expire_pending_controls(State.t(), DateTime.t(), non_neg_integer()) :: State.t()
  defdelegate expire_pending_controls(state, now, timeout_ms), to: ControlCalls

  @doc false
  @spec resume_issue(State.t(), String.t()) ::
          {{:ok, :resumed | :started | :reactivated | :already_running | :sleeping} | {:error, term()}, State.t()}
  defdelegate resume_issue(state, issue_identifier), to: Resume

  @doc false
  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  defdelegate pause_issue_for_label_override(state, issue), to: LabelOverride

  @doc false
  @spec resume_label_overridden_issue(State.t(), map()) ::
          {{:ok, :resumed} | {:error, term()}, State.t()}
  defdelegate resume_label_overridden_issue(state, running_entry), to: LabelOverride

  @doc false
  @spec reactivate_issue(State.t(), map()) :: {{:ok, :reactivated} | {:error, term()}, State.t()}
  defdelegate reactivate_issue(state, running_entry), to: Resume

  @doc false
  @spec pause_agent_reply(State.t(), String.t() | TrackerIdentity.t()) :: {term(), State.t()}
  defdelegate pause_agent_reply(state, identity), to: PauseRequest

  @doc false
  @spec request_pause(State.t(), map(), Issue.t() | nil, atom()) :: {term(), State.t()}
  defdelegate request_pause(state, running_entry, issue, pause_reason), to: PauseRequest

  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  defdelegate send_pause_control_message(state, issue_identifier), to: PauseRequest

  @doc false
  @spec handle_worker_control_state(State.t(), String.t(), :completed | :paused | :working, map()) ::
          {:noreply, State.t()}
  defdelegate handle_worker_control_state(state, issue_id, status, pause_payload), to: WorkerControl

  @doc false
  @spec handle_worker_control_rejected(State.t(), String.t(), pos_integer(), non_neg_integer(), atom()) ::
          {:noreply, State.t()}
  defdelegate handle_worker_control_rejected(state, issue_id, request_id, generation, class), to: WorkerControl

  @doc false
  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  defdelegate transition_control_status(state, running_entry, new_status, reason), to: WorkerControl

  @doc false
  @spec replace_completed_issue(State.t(), map(), Issue.t()) :: State.t()
  defdelegate replace_completed_issue(state, running_entry, issue), to: CompletedReplacement

  @doc false
  @spec dispatch_completed_replacement(State.t(), map(), Issue.t(), keyword()) :: State.t()
  defdelegate dispatch_completed_replacement(state, running_entry, issue, opts \\ []), to: CompletedReplacement

  @doc false
  @spec dispatch_completed_replacement_result(State.t(), map(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, {:redispatch_deferred, term()}}, State.t()}
  defdelegate dispatch_completed_replacement_result(state, running_entry, issue, opts \\ []), to: CompletedReplacement

  @doc false
  @spec replace_admitted_completed_entry(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          State.t()
  defdelegate replace_admitted_completed_entry(state, running_entry, issue, worker_host, dispatch_fun), to: CompletedReplacement

  @doc false
  @spec replace_admitted_completed_entry_result(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          {{:ok, :started} | {:error, {:redispatch_deferred, term()}}, State.t()}
  defdelegate replace_admitted_completed_entry_result(state, running_entry, issue, worker_host, dispatch_fun), to: CompletedReplacement

  @doc false
  @spec resume_paused_issue(State.t(), map(), boolean()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  defdelegate resume_paused_issue(state, running_entry, operator? \\ true), to: Resume

  @doc false
  @spec resume_paused_issue_preflight(State.t(), map()) :: :ok | {:error, :max_concurrent_agents_reached}
  defdelegate resume_paused_issue_preflight(state, running_entry), to: Resume

  @doc false
  @spec pending_input_pause?(State.t(), map()) :: boolean()
  defdelegate pending_input_pause?(state, running_entry), to: Resume

  @doc false
  @spec reset_last_codex_timestamp(map(), term(), DateTime.t()) :: map()
  defdelegate reset_last_codex_timestamp(running, issue_id, now), to: Clocks

  @doc false
  @spec reset_duration_clock_if_capped(map(), term(), DateTime.t(), boolean()) :: map()
  defdelegate reset_duration_clock_if_capped(running, issue_id, now, operator?), to: Clocks

  @doc false
  @spec resume_decline_reason(atom(), Issue.t(), State.t(), keyword()) :: term()
  defdelegate resume_decline_reason(reason, issue, state, opts \\ []), to: DeclineReason

  @doc false
  @spec dispatch_resumed_queued_issue(State.t(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, term()}, State.t()}
  defdelegate dispatch_resumed_queued_issue(state, issue, opts \\ []), to: QueuedDispatch

  defp resume_api_call(server, {_action, identifier} = request) do
    if GenServer.whereis(server) do
      with {:ok, _result} <- control_caller_work(:resume, identifier, fn -> ModelAvailability.probe_stale_limits(DispatchPolicy.read_provider_backends(), []) end) do
        control_api_call(server, request)
      end
    else
      {:error, :unavailable}
    end
  end

  defp control_caller_work(action, identifier, fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      action = if action == :resume_with_receipt, do: :resume, else: action
      summary = ControlCalls.control_crash_summary(kind, reason, __STACKTRACE__)
      ControlCalls.emit_control_crash_alert(action, identifier, summary)
      {:error, {:control_call_crashed, action, summary}}
  end

  defp control_api_call(server, request) do
    timeout_ms = Application.get_env(:aiur, :control_api_call_timeout_ms, 5_000)

    if GenServer.whereis(server) do
      finish_control_api_call(server, GenServer.call(server, request, timeout_ms))
    else
      {:error, :unavailable}
    end
  catch
    # `:unavailable` is rendered to the operator as "orchestrator unavailable",
    # i.e. the daemon is not there to answer. Only the exits that actually mean
    # that may claim it (#1634); a crash raised *inside* the orchestrator while
    # it is running and answering must surface its own reason rather than be
    # laundered into a false "the daemon is down" diagnosis.
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, {{:nodedown, _node}, _} -> {:error, :unavailable}
    :exit, reason -> {:error, {:orchestrator_call_failed, reason}}
  end

  defp finish_control_api_call(server, {:tracker_io, {action, identifier, stage}, function, args}) do
    with {:ok, result} <- control_caller_work(action, identifier, fn -> TrackerControl.perform_tracker_io(function, args) end) do
      control_api_call(server, {:tracker_control_result, action, identifier, stage, result})
    end
  end

  defp finish_control_api_call(_server, reply), do: reply

  @doc false
  @spec put_running_control_status(State.t(), String.t(), :paused | :working) :: State.t()
  defdelegate put_running_control_status(state, issue_id, status), to: ControlRequest
end
