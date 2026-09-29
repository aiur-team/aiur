defmodule Aiur.Muse.TurnControl do
  @moduledoc "Native interrupt admission and typed terminal outcomes."

  alias Aiur.Muse.{Protocol, Transport}

  @spec interrupt(map(), term()) :: {:continue, map()} | {:error, term()}
  def interrupt(%{interrupt: interrupt} = state, _action) when not is_nil(interrupt), do: {:continue, state}

  def interrupt(state, action) do
    request_id = System.unique_integer([:positive])
    command_id = Protocol.command_id()
    frame = Protocol.turn_interrupt_frame(request_id, state.session.thread_id, state.turn_id, command_id: command_id)

    case Transport.send_frame(state.session.port, frame) do
      :ok -> {:continue, %{state | interrupt: %{request_id: request_id, command_id: command_id, action: action}}}
      {:error, reason} -> {:error, {:native_interrupt_failed, reason}}
    end
  end

  @spec finish(map(), {atom(), map()}) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def finish(state, {outcome, params}) do
    base = %{session_id: "#{state.session.thread_id}-#{state.turn_id}", thread_id: state.session.thread_id, turn_id: state.turn_id, view_cursor: params["viewCursor"], usage: params["usage"]}

    case {state.interrupt && state.interrupt.action, outcome} do
      # Completion can win the race with interruption. Both matching terminal
      # outcomes prove the turn stopped; retain the actual terminal in details.
      {{:pause, request}, terminal} when terminal in [:cancelled, :completed] ->
        {:paused, base |> Map.merge(pause_details(request, params)) |> Map.put(:native_terminal, terminal)}

      {:operator_message, :cancelled} ->
        {:ok, Map.put(base, :result, :turn_interrupted_for_operator_message)}

      {{:error, reason}, terminal} when terminal in [:cancelled, :completed] ->
        {:error, reason}

      {_, :completed} ->
        {:ok, Map.put(base, :result, :turn_completed)}

      {_, :failed} ->
        {:error, {:native_turn_failed, params["error"]}}

      {_, :cancelled} ->
        {:error, {:native_turn_cancelled, params["reason"]}}
    end
  end

  defp pause_details(%{request_id: request_id, generation: generation} = control, params)
       when is_integer(request_id) and is_integer(generation), do: %{control: control, details: params}

  defp pause_details(request_id, params), do: %{request_id: request_id, details: params}
end
