defmodule AiurWeb.StreamdeckChannel.Voice do
  @moduledoc """
  Voice input helpers for `AiurWeb.StreamdeckChannel`: opening and stopping the
  transcription session a mic hold streams into, and admitting the spoken
  message a `say` delivers. The authentication clauses stay on the channel's
  own `handle_in/3` heads so the gate is visible at the entry point.
  """

  import Phoenix.Socket, only: [assign: 3]

  alias Aiur.AgentChat
  alias Aiur.ElevenLabs.Realtime
  alias AiurWeb.Endpoint

  @spec stop_child(term()) :: :ok
  def stop_child(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  def stop_child(_absent), do: :ok

  # The session module is the seam, never the credential: a test supplies a fake
  # session and no configuration anywhere can be made to carry an API key into
  # this channel.
  defp voice_session_module do
    case Endpoint.config(:streamdeck_voice_session) do
      module when is_atom(module) and not is_nil(module) -> module
      _absent -> Realtime
    end
  end

  @spec open_voice_session() :: {:ok, map()} | {:error, term()}
  def open_voice_session do
    module = voice_session_module()

    case module.start(owner: self()) do
      # The module is remembered with the session rather than re-read per frame,
      # so a configuration change cannot leave `push` and `commit` addressing a
      # different implementation than the one that opened the connection.
      {:ok, pid} -> {:ok, %{id: mint_session_id(), pid: pid, ref: Process.monitor(pid), module: module}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :voice_unavailable}
    end
  end

  # Opaque and server-minted, so a device cannot address a session it did not
  # open and a replayed id from a previous hold cannot collide with a live one.
  defp mint_session_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @spec stop_voice_session(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def stop_voice_session(%{assigns: %{voice_session: %{pid: pid, ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    stop_child(pid)
    # `GenServer.stop/2` is synchronous, so everything the stopped session ever
    # sent is already in this mailbox. Draining it here is what stops a transcript
    # from the abandoned hold being pushed under the next session's id.
    drain_voice_messages()
    assign(socket, :voice_session, nil)
  end

  def stop_voice_session(socket), do: socket

  defp drain_voice_messages do
    receive do
      {:elevenlabs_transcript, _kind, _text} -> drain_voice_messages()
      {:elevenlabs_error, _reason} -> drain_voice_messages()
      {:elevenlabs_closed} -> drain_voice_messages()
    after
      0 -> :ok
    end
  end

  # Mirrors `Aiur.Orchestrator.OperatorMessages`' own ceiling so an over-long
  # dictation is refused here, with a reason the device can show, instead of
  # failing deeper in delivery.
  @max_message_chars 8_000

  @spec validate_message(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_message(""), do: {:error, "empty_message"}

  def validate_message(message) do
    if String.length(message) > @max_message_chars do
      {:error, "message_too_long"}
    else
      {:ok, message}
    end
  end

  # The sidecar sends one id per say press and reuses it when it re-pushes the
  # same frame, so a re-push after a timeout cannot queue a copy (#2717).
  @spec say_message_id(map()) :: String.t() | nil
  def say_message_id(%{"message_id" => message_id})
      when is_binary(message_id) and byte_size(message_id) in 1..128,
      do: message_id

  def say_message_id(_payload), do: nil

  # Same injection seam as the dashboard's chat box (`DashboardLive`), so tests
  # can observe delivery without a live orchestrator.
  @spec send_agent_message(String.t(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def send_agent_message(identifier, message, message_id) do
    case Endpoint.config(:agent_chat_send_fun) do
      fun when is_function(fun, 3) -> fun.(identifier, message, message_id: message_id)
      fun when is_function(fun, 2) -> fun.(identifier, message)
      _fun -> AgentChat.send(identifier, message, message_id: message_id)
    end
  end
end
