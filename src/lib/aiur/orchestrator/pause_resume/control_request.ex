defmodule Aiur.Orchestrator.PauseResume.ControlRequest do
  @moduledoc """
  Submits pause and resume control requests to workers and persists their lifecycle.
  """

  alias Aiur.AgentPubSub
  alias Aiur.Events.IdGenerator
  alias Aiur.Issue
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.ControlLifecycleStore
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.PauseResume.Clocks
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.WorkerControl
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Signal

  @doc false
  @spec send_resume_control_message(State.t(), term(), term()) :: term()
  def send_resume_control_message(%State{} = state, running_entry, operator?) do
    if PauseRequest.legacy_control_entry?(running_entry) do
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
        previous_state = state
        now = DateTime.utc_now()

        state = put_running_control_status(state, issue_id, :working)
        state = update_in(state.running, &State.thaw_pause_clock(&1, issue_id, previous_status, now))
        state = update_in(state.running, &Clocks.reset_last_codex_timestamp(&1, issue_id, now))
        state = update_in(state.running, &Clocks.reset_duration_clock_if_capped(&1, issue_id, now, operator?))
        state = update_in(state.running, &clear_legacy_pause_reason(&1, issue_id))
        state = Dispatcher.reset_thrash_budget(state, issue_id)
        state = WorkerControl.maybe_wake_after_first_active_resume(state, previous_state)

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

  @doc false
  @spec submit_resume_control_request(State.t(), term(), term(), term()) :: term()
  def submit_resume_control_request(%State{} = state, running_entry, requester, request_id \\ nil) do
    if Map.get(running_entry, :control, %{}) |> Map.get(:status, :working) == :paused do
      cond do
        Slots.active_slots(state) >= Slots.max_concurrent_agent_limit(state) ->
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

  @doc false
  @spec submit_control_request(State.t(), term(), term(), term(), term(), term()) :: term()
  def submit_control_request(%State{} = state, running_entry, issue_identifier, action, requester, request_id \\ nil)
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
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle() |> PauseResume.drop_stale_pending_pause_reason(request.issue_id)
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
        state = state |> reject_routing_failure(request.request_id, reason) |> PauseResume.drop_stale_pending_pause_reason(request.issue_id)

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

  @doc false
  @spec persist_control_lifecycle(State.t()) :: term()
  def persist_control_lifecycle(%State{} = state) do
    :ok = ControlLifecycleStore.save(state.control_lifecycle)
    state
  end

  @doc false
  @spec publish_control_lifecycle(term(), term()) :: term()
  def publish_control_lifecycle(identifier, request) when is_binary(identifier) and is_map(request) do
    AgentPubSub.broadcast_control_lifecycle(identifier, ControlLifecycle.event_payload(request))
  end

  def publish_control_lifecycle(_identifier, _request), do: :ok

  defp publish_superseded_control_lifecycle(identifier, %{request_id: request_id}, lifecycle) do
    case ControlLifecycle.get(lifecycle, request_id) do
      %{status: :rejected, rejection: %{class: :superseded}} = request ->
        publish_control_lifecycle(identifier, request)

      _ ->
        :ok
    end
  end

  defp publish_superseded_control_lifecycle(_identifier, _pending, _lifecycle), do: :ok

  @doc false
  @spec record_control_transition(term(), term(), term(), term()) :: term()
  def record_control_transition(_running_entry, status, status, _cause), do: :ok

  def record_control_transition(running_entry, _old_status, :paused, cause) do
    Signal.lifecycle(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_pause,
      :point,
      %{cause: cause}
    )
  end

  def record_control_transition(running_entry, old_status, :working, cause)
      when old_status in [:paused, :deactivated] do
    Signal.lifecycle(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_resume,
      :point,
      %{cause: cause}
    )
  end

  def record_control_transition(_running_entry, _old_status, _new_status, _cause), do: :ok

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
