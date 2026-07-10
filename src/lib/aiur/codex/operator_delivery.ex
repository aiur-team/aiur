defmodule Aiur.Codex.OperatorDelivery do
  @moduledoc """
  Codex operator-message delivery over the app-server turn/start request.
  """

  alias Aiur.Codex.{Frames, Rpc}

  @spec send_operator_message(map(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(
        %{port: port, thread_id: thread_id, workspace: workspace} = session,
        %{kind: :text, body: text}
      )
      when is_port(port) and is_binary(thread_id) and is_binary(workspace) and is_binary(text) do
    request_id = :erlang.unique_integer([:positive])

    frame = Frames.operator_turn_frame(session, request_id, text)

    Rpc.send_message(port, frame)
    {:ok, request_id}
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_session}
end
