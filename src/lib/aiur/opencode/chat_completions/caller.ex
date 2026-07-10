defmodule Aiur.Opencode.ChatCompletions.Caller do
  @moduledoc """
  Identify and authorize the opencode-serve behind a bridge request.

  Resolves the bearer token in the `Authorization` header to a live slot
  (`base_url/1`), checks token validity (`authorize/1`), and looks up
  the originating session writer for segmentation (`writer/2`).
  """

  require Logger

  alias Aiur.Opencode.{
    SessionWriterRegistry,
    Slot,
    SlotRegistry,
    TokenRegistry
  }

  @doc false
  @spec authorize(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, :unauthorized}
  def authorize(conn) do
    # Token validity is independent of identifier; the identifier comes
    # from the request body's `model` field via `identifier_from_model/1`
    # and routes the request, while the bearer just authorizes "this is
    # a live aiur workspace."
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         true <- TokenRegistry.valid?(token) do
      {:ok, conn}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc false
  @spec auth_failed_body() :: map()
  def auth_failed_body do
    %{
      error: "auth_failed",
      message: "Bridge token did not match an active workspace. If Aiur was restarted, close and reopen the pane to refresh the token."
    }
  end

  @doc false
  @spec base_url(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def base_url(conn) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, slot_index} <- TokenRegistry.lookup_slot(token),
         {:ok, slot_pid} <- SlotRegistry.lookup(slot_index),
         %{base_url: base_url} when is_binary(base_url) <- Slot.snapshot(slot_pid) do
      {:ok, base_url}
    else
      _ -> :error
    end
  end

  # Resolve the writer (serve base_url + session id) whose opencode issued
  # THIS chat-completion request — continuations must go only to the
  # originating serve or N attached panes would multiply segment streams
  # combinatorially. nil disables segmentation for the stream (degrades to
  # the long-held SSE).
  @doc false
  @spec writer(Plug.Conn.t(), String.t()) :: map() | nil
  def writer(conn, identifier) do
    with {:ok, base_url} <- base_url(conn),
         {:ok, %{session_id: session_id}} <- SessionWriterRegistry.lookup(identifier, base_url) do
      %{session_id: session_id, base_url: base_url}
    else
      _ ->
        # Always-on: a nil writer disables segmentation for this stream, so
        # opencode never gets a segment-close to flush its TUI-local input
        # queue — typed operator text then sits QUEUED for the whole turn.
        # Surfacing it at info makes a stuck-codex-input repro diagnosable.
        Logger.info("opencode_bridge segment_writer_unresolved identifier=#{identifier}")
        nil
    end
  end
end
