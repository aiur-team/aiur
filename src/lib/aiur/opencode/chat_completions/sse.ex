defmodule Aiur.Opencode.ChatCompletions.Sse do
  @moduledoc """
  OpenAI-compatible response encoding and disconnect-tolerant conn writes.

  Encodes turn events as `data: {...}\\n\\n` SSE frames, writes them to the
  Plug conn, and handles the write-on-closed-conn case gracefully (log once,
  return conn unchanged). No process interaction or side effects beyond the
  conn write itself.
  """

  require Logger

  @spec build_chunk(String.t(), map()) :: map()
  def build_chunk(completion_id, %{content: content, finish_reason: finish_reason}) do
    %{
      id: completion_id,
      object: "chat.completion.chunk",
      created: System.system_time(:second),
      model: "aiur",
      choices: [
        %{
          index: 0,
          delta: delta(content),
          finish_reason: finish_reason
        }
      ]
    }
  end

  # OpenAI finish_reason for a closed bridge turn. Always "stop".
  #
  # Critically NOT "tool_calls" for :input_required: a "tool_calls"
  # finish with no tool-call payload makes opencode's agent loop re-open
  # the chat-completion request to "run the tools and continue". But the
  # last user message is still the unanswered `__aiur_turn__:<id>` marker
  # whose ActiveTurns entry is now {:closed, :input_required}, so every
  # re-open returns "tool_calls" again and opencode busy-loops until the
  # entry expires (~60s) — pegging CPU and starving the TUI input loop.
  # "stop" ends the turn cleanly; the agent resumes via a fresh marker
  # once the approval is resolved in the dashboard.
  @doc false
  @spec finish_reason_for(term()) :: String.t()
  def finish_reason_for(_reason), do: "stop"

  @spec chunk(Plug.Conn.t(), String.t(), String.t() | nil, String.t() | nil) :: Plug.Conn.t()
  def chunk(conn, completion_id, content, finish_reason) do
    payload = build_chunk(completion_id, %{content: content, finish_reason: finish_reason})

    case Plug.Conn.chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n") do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        # opencode disconnected the SSE — common when it kills/respawns
        # the attach pane or hits its read timeout. Crashing the bridge
        # handler with a MatchError takes down the whole codex turn
        # rendering; instead, log once and return the conn unchanged so
        # the loop can finish via the `:aiur_turn_done` close broadcast
        # (subsequent writes will fast-fail the same way and be silently
        # dropped here).
        Logger.debug("opencode_bridge chunk_write_closed reason=#{inspect(reason)}")
        conn
    end
  end

  @spec empty_stream(Plug.Conn.t()) :: Plug.Conn.t()
  def empty_stream(conn) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    conn
  end

  @spec json(Plug.Conn.t(), non_neg_integer(), map()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  @spec random_id() :: String.t()
  def random_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp delta(nil), do: %{}
  defp delta(content), do: %{content: content}
end
