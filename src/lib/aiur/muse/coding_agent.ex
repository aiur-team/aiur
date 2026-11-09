defmodule Aiur.Muse.CodingAgent do
  @moduledoc "Native Muse MSP backend for Aiur's agent lifecycle."
  @behaviour Aiur.CodingAgent.Backend

  alias Aiur.Muse.EventNormalizer
  alias Aiur.Muse.{Protocol, Session, Transport, Turn}

  @impl true
  defdelegate start_session(workspace, opts), to: Session, as: :start

  @impl true
  defdelegate run_turn(session, prompt, issue, opts), to: Turn, as: :run

  @impl true
  defdelegate stop_session(session), to: Session, as: :stop

  @impl true
  def normalize_event(message), do: EventNormalizer.normalize_event(message)

  @impl true
  def steer(_session, _payload, nil), do: {:error, :no_active_turn}

  def steer(%{port: port, thread_id: session_id} = session, %{kind: :text, body: text}, turn_id)
      when is_binary(text) and byte_size(text) > 0 and is_binary(turn_id) do
    id = :erlang.unique_integer([:positive, :monotonic])
    opts = if is_binary(session[:effort]), do: [reasoning_effort: session.effort], else: []
    frame = Protocol.turn_steer_frame(id, session_id, turn_id, text, opts)

    with :ok <- Transport.send_frame(port, frame),
         do: {:ok, %{request_id: id, command_id: frame["params"]["commandId"]}}
  end

  def steer(_session, _payload, _turn_id), do: {:error, :invalid_operator_message}

  @impl true
  def send_operator_message(%{port: port, thread_id: session_id}, %{kind: :text, body: text})
      when is_binary(text) and byte_size(text) > 0 do
    id = :erlang.unique_integer([:positive, :monotonic])
    frame = Protocol.turn_start_frame(id, session_id, text, if_busy: "queue")

    with :ok <- Transport.send_frame(port, frame), do: {:ok, id}
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_operator_message}
end
