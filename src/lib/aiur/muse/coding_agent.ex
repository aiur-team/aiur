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
  def send_operator_message(%{port: port, thread_id: session_id}, %{kind: :text, body: text})
      when is_binary(text) and byte_size(text) > 0 do
    id = :erlang.unique_integer([:positive, :monotonic])
    frame = Protocol.turn_start_frame(id, session_id, text, if_busy: "queue")

    with :ok <- Transport.send_frame(port, frame), do: {:ok, id}
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_operator_message}
end
