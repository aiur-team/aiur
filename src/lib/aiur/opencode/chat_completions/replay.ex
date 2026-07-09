defmodule Aiur.Opencode.ChatCompletions.Replay do
  @moduledoc """
  Stream a previously-recorded message back to opencode as SSE deltas.

  Reads the parts written by `SessionWriter` to the slot-local SQLite and
  re-streams them as `chat.completion.chunk` frames so an attached TUI can
  render the message in real time (`__aiur_stream__:<msg_id>` marker path).
  """

  require Logger

  alias Aiur.Opencode.{Db, SessionWriterRegistry}
  alias Aiur.Opencode.ChatCompletions.{Caller, Sse}

  # Synthetic-marker round-trip: `SessionWriter` writes assistant rows
  # directly into opencode's SQLite, then POSTs a synthetic user message
  # carrying `__aiur_stream__:<msg_id>`. opencode triggers a chat-completion
  # call here; we read the just-written rows back and stream them as
  # assistant deltas so the attached TUI renders them in real time.
  @spec stream(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def stream(conn, identifier, message_id) do
    completion_id = "chatcmpl-" <> Sse.random_id()

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    session_id = resolve_session_for_replay(conn, identifier)

    case session_id && Db.fetch_message_with_parts(session_id, message_id) do
      {:ok, %{parts: parts}} ->
        conn = Enum.reduce(parts, conn, &chunk_part(&1, &2, completion_id))
        Sse.chunk(conn, completion_id, nil, "stop")

      _ ->
        Logger.warning("opencode_bridge stream_replay message_not_found identifier=#{identifier} message_id=#{message_id}")

        conn = Sse.chunk(conn, completion_id, "**system:** message not found", nil)
        Sse.chunk(conn, completion_id, nil, "stop")
    end
  end

  # Each slot's opencode-serve owns its own per-agent session_id (sessions
  # aren't portable across serves, even with a shared SQLite DB). The
  # bearer token identifies which slot's serve issued the chat-completion
  # callback, so we look up that exact (identifier, base_url) pair.
  #
  # NO FALLBACK to "any writer for identifier" — with `:duplicate` keys
  # in `SessionWriterRegistry`, `lookup/1` returns whichever writer the
  # registry happened to order first, and that writer's session_id may
  # be in a DIFFERENT serve's DB view from the one that wrote `message_id`.
  # The replay query then returns no rows and the user sees
  # `**system:** message not found` even though the message was written
  # correctly elsewhere. Returning nil here forces the same not-found
  # error path but with a clearer logged reason.
  defp resolve_session_for_replay(conn, identifier) do
    case Caller.base_url(conn) do
      {:ok, base_url} ->
        case SessionWriterRegistry.lookup(identifier, base_url) do
          {:ok, %{session_id: sid}} ->
            sid

          :not_found ->
            Logger.warning("opencode_bridge resolve_session writer_not_found identifier=#{identifier} base_url=#{base_url}")

            nil
        end

      :error ->
        Logger.warning("opencode_bridge resolve_session caller_unresolved identifier=#{identifier}")

        nil
    end
  end

  defp chunk_part(%{"type" => "text", "text" => text}, conn, completion_id)
       when is_binary(text) and text != "" do
    Sse.chunk(conn, completion_id, text, nil)
  end

  defp chunk_part(_, conn, _completion_id), do: conn
end
