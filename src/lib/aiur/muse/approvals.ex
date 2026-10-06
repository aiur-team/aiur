defmodule Aiur.Muse.Approvals do
  @moduledoc "Native approvals fenced by session and requirement, answered only by Executor input."

  alias Aiur.Muse.{Protocol, Transport}

  @spec new(map()) :: map()
  def new(session), do: %{session: session, pending: %{}, submitted: %{}, superseded_commands: MapSet.new()}

  @spec pending?(map()) :: boolean()
  def pending?(state), do: map_size(state.pending) > 0

  @spec observe(map(), map()) :: map()
  def observe(state, %{"method" => method, "params" => params} = frame)
      when method in ["approval/request", "approval/requested", "approval/updated"] do
    with true <- params["sessionId"] == state.session.thread_id,
         id when is_binary(id) <- params["approvalId"],
         requirement when is_map(requirement) <- params["currentRequirementId"],
         ^id <- requirement["approvalId"],
         token when is_binary(token) <- requirement_token(requirement),
         choices when is_list(choices) <- params["availableChoices"],
         false <- older_requirement?(state.pending[id], requirement) do
      acknowledge_presentation(state, frame)
      state = settle_changed_requirement(state, id, requirement)
      %{state | pending: Map.put(state.pending, id, params)}
    else
      _ -> state
    end
  end

  def observe(state, %{"method" => "approval/resolved", "params" => params}) do
    if params["sessionId"] == state.session.thread_id and
         not MapSet.member?(state.superseded_commands, params["decidedByCommandId"]) do
      id = params["approvalId"]
      state = settle_resolution(state, id, params)
      %{state | pending: Map.delete(state.pending, id)}
    else
      state
    end
  end

  def observe(state, %{"id" => request_id, "error" => _}) do
    case Enum.find(state.submitted, fn {_id, request} -> request.request_id == request_id end) do
      {id, request} ->
        request.failure.({:invalid_native_response, :provider_rejected})
        %{state | submitted: Map.delete(state.submitted, id)}

      nil ->
        state
    end
  end

  # An accepted JSON-RPC command receipt is not an applied approval.
  def observe(state, _frame), do: state

  @spec deliver(map(), String.t(), function(), function()) :: map()
  def deliver(state, text, success, failure) do
    case String.split(String.trim(text)) do
      ["/approve", id, requirement, choice] ->
        submit(state, id, requirement, choice, success, failure)

      ["/approve" | _] ->
        failure.({:invalid_native_response, :invalid_approval_command})
        state

      _ ->
        failure.(:native_approval_pending)
        state
    end
  end

  @spec requirement_token(term()) :: String.t() | nil
  def requirement_token(%{"approvalId" => id, "sourceIndex" => index})
      when is_binary(id) and id != "" and is_integer(index) and index >= 0 do
    %{"approvalId" => id, "sourceIndex" => index} |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  def requirement_token(_requirement), do: nil

  @spec close(map()) :: :ok
  def close(state) do
    Enum.each(state.submitted, fn {_id, request} -> request.failure.(:native_approval_unconfirmed) end)
    :ok
  end

  defp submit(state, id, requirement, choice, success, failure) do
    with %{"currentRequirementId" => native_requirement, "availableChoices" => choices} <- state.pending[id],
         ^requirement <- requirement_token(native_requirement),
         true <- Enum.any?(choices, &match?(%{"choiceId" => ^choice}, &1)),
         false <- Map.has_key?(state.submitted, id) do
      request_id = System.unique_integer([:positive])
      command_id = Protocol.command_id()

      frame = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "approval/decide",
        "params" => %{"commandId" => command_id, "sessionId" => state.session.thread_id, "approvalId" => id, "requirementId" => native_requirement, "choiceId" => choice}
      }

      case Transport.send_frame(state.session.port, frame) do
        :ok ->
          request = %{request_id: request_id, command_id: command_id, requirement: native_requirement, success: success, failure: failure}
          %{state | submitted: Map.put(state.submitted, id, request)}

        {:error, reason} ->
          failure.(reason)
          state
      end
    else
      _ ->
        failure.({:invalid_native_response, :stale_or_invalid_approval_choice})
        state
    end
  end

  defp settle_resolution(state, id, params) do
    case Map.pop(state.submitted, id) do
      {nil, _} ->
        state

      {request, remaining} ->
        if params["decidedByCommandId"] == request.command_id do
          request.success.(%{transport: :muse_msp, approval_id: id, decision: params["decision"], command_id: request.command_id, view_cursor: params["viewCursor"]})
        else
          request.failure.({:invalid_native_response, :resolved_elsewhere})
        end

        %{state | submitted: remaining}
    end
  end

  defp settle_changed_requirement(state, id, requirement) do
    case state.submitted[id] do
      %{requirement: prior} = request when prior != requirement ->
        # A changed requirement alone cannot attribute application to our command.
        request.failure.({:invalid_native_response, :requirement_changed})
        %{state | submitted: Map.delete(state.submitted, id), superseded_commands: MapSet.put(state.superseded_commands, request.command_id)}

      _ ->
        state
    end
  end

  defp older_requirement?(
         %{"currentRequirementId" => %{"approvalId" => id, "sourceIndex" => prior}},
         %{"approvalId" => id, "sourceIndex" => incoming}
       ),
       do: incoming < prior

  defp older_requirement?(_pending, _incoming), do: false

  defp acknowledge_presentation(state, %{"id" => id}) do
    Transport.send_frame(state.session.port, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp acknowledge_presentation(_state, _frame), do: :ok
end
