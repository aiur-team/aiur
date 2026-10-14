defmodule Aiur.Orchestrator.PauseResume.PauseRequest do
  @moduledoc """
  Routes a pause request to the worker and records who asked and why.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.PauseResume.ControlRequest
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PauseResume.WorkerControl
  alias Aiur.Orchestrator.State
  alias Aiur.TrackerIdentity

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
  @doc false
  @spec legacy_control_entry?(term()) :: term()
  def legacy_control_entry?(running_entry) do
    control = Map.get(running_entry, :control, %{})

    Map.has_key?(control, :can_interrupt) and
      not (Map.has_key?(control, :generation) and Map.has_key?(control, :version) and
             Map.has_key?(control, :application_confirmation))
  end

  defp legacy_pause_request(state, running_entry, identifier, pause_reason) do
    reply = send_pause_control_message(state, identifier)
    paused_entry = Map.put(running_entry, :paused_reason, pause_reason)
    {reply, WorkerControl.transition_control_status(state, paused_entry, :paused, Atom.to_string(pause_reason))}
  end

  defp adopt_existing_pause(state, running_entry, pause_reason) do
    state = supersede_pending_resume(state, running_entry)
    running_entry = Map.put(running_entry, :paused_reason, pause_reason)
    state = WorkerControl.transition_control_status(state, running_entry, :paused, Atom.to_string(pause_reason))
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
            state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle() |> PauseResume.drop_stale_pending_pause_reason(issue_id)
            ControlRequest.publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
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
    state = Resume.put_running_entry(state, issue_id, running_entry)
    {state, running_entry, issue_id, identifier}
  end

  defp replace_running_issue(running_entry, %Issue{} = issue), do: Map.put(running_entry, :issue, issue)
  defp replace_running_issue(running_entry, _issue), do: running_entry

  defp submit_pause_request(state, running_entry, issue_id, identifier, pause_reason) do
    requester = pause_requester(pause_reason)
    {reply, state} = ControlRequest.submit_control_request(state, running_entry, identifier, :pause, requester)
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
  @spec pending_pause_request?(State.t(), term()) :: term()
  def pending_pause_request?(state, running_entry) do
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

  @doc false
  @spec matching_pending_pause(State.t(), term(), term()) :: term()
  def matching_pending_pause(state, running_entry, pause_reason) do
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

  defp pause_requester(:operator_pause), do: :operator
  defp pause_requester(reason) when reason in [:agent_pause_request, :github_budget_hold], do: :automatic
  defp pause_requester(_pause_reason), do: :system

  defp issue_id(_running_entry, %Issue{id: issue_id}) when not is_nil(issue_id), do: issue_id
  defp issue_id(running_entry, _issue), do: get_in(running_entry, [:issue, Access.key(:id)])

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil
end
