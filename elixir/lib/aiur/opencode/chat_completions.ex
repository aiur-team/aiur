defmodule Aiur.Opencode.ChatCompletions do
  @moduledoc false

  require Logger

  alias Aiur.{AgentChat, AgentPubSub}
  alias Aiur.Opencode.{Config, Db, SessionWriterRegistry, TokenRegistry}

  @stream_marker_prefix "__aiur_stream__:"
  @stream_marker_regex ~r/\A__aiur_stream__:(msg_[A-Z0-9]+)\z/
  # Nudge markers ("__aiur_stream__:nudge:<N>") are sent by Slot workers
  # to force opencode-attach to re-render after a select. They aren't
  # tied to a specific message id; the bridge just returns an empty
  # SSE stream so opencode treats the turn as a no-op rather than
  # rendering a "Bad Request: invalid stream marker" toast.
  @nudge_marker_regex ~r/\A__aiur_stream__:nudge:/

  @max_body_bytes 65_536
  @watchdog_ms 600_000

  @spec handle(map(), Plug.Conn.t()) :: Plug.Conn.t()
  def handle(body, conn) do
    case identifier_from_model(Map.get(body, "model")) do
      {:ok, identifier} ->
        handle_identified(body, conn, identifier)

      {:error, :placeholder_session} ->
        # Stray call against the warm placeholder session. Return an empty
        # SSE stream so opencode doesn't render an error toast.
        empty_stream(conn)

      {:error, reason} ->
        json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_identified(body, conn, identifier) do
    text = last_user_text(body)

    case text do
      {:ok, @stream_marker_prefix <> _ = marker} ->
        cond do
          Regex.match?(@nudge_marker_regex, marker) ->
            # Refresh-only nudge — slot sent this to force a TUI redraw.
            # Reply with an empty SSE stream so opencode commits no rows
            # and renders no toast.
            empty_stream(conn)

          match = Regex.run(@stream_marker_regex, marker) ->
            [_, message_id] = match
            replay_message_as_stream(conn, identifier, message_id)

          true ->
            json(conn, 400, %{error: "invalid stream marker"})
        end

      {:ok, raw_text} ->
        dispatch_user_text(body, conn, identifier, raw_text)

      {:error, reason} ->
        json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp dispatch_user_text(body, conn, identifier, raw_text) do
    with {:ok, sanitized} <- validate_body(raw_text),
         {:ok, conn} <- maybe_authorized(conn, identifier) do
      route_turn(conn, identifier, sanitized, Map.get(body, "stream", true))
    else
      {:error, :unauthorized} -> json(conn, 401, auth_failed_body())
      {:error, :body_too_large} -> json(conn, 400, %{error: "body too large"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp route_turn(conn, identifier, sanitized, true),
    do: stream_turn(conn, identifier, sanitized)

  defp route_turn(conn, identifier, sanitized, _),
    do: non_stream_turn(conn, identifier, sanitized)

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

  defp stream_turn(conn, identifier, text) do
    turn_id = random_id()
    completion_id = "chatcmpl-" <> random_id()
    :ok = AgentPubSub.subscribe_agent(identifier)

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        Process.send_after(self(), {:turn_watchdog, turn_id}, @watchdog_ms)
        stream_loop(conn, identifier, turn_id, completion_id)

      {:error, reason} ->
        emit_error_and_close(conn, completion_id, reason)
    end
  end

  defp non_stream_turn(conn, identifier, text) do
    turn_id = random_id()
    :ok = AgentPubSub.subscribe_agent(identifier)

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        body = collect_turn(identifier, turn_id, [])

        json(conn, 200, %{
          id: "chatcmpl-" <> random_id(),
          object: "chat.completion",
          choices: [%{index: 0, message: %{role: "assistant", content: body}, finish_reason: "stop"}]
        })

      {:error, reason} ->
        json(conn, 200, %{error: inspect(reason)})
    end
  end

  defp send_operator(identifier, text, turn_id) do
    # Chat UX expects messages to interrupt the active turn; `:checkpoint` queues until a safe boundary.
    AgentChat.send(identifier, text,
      delivery_policy: :interrupt,
      fallback: :queue_next,
      turn_id: turn_id
    )
  end

  defp stream_loop(conn, identifier, turn_id, completion_id) do
    receive do
      {:transcript_event, %{role: role, body: body, turn_id: ^turn_id}} when role in [:assistant, :command] ->
        conn = chunk(conn, completion_id, body, nil)
        stream_loop(conn, identifier, turn_id, completion_id)

      {:transcript_event, %{role: :user}} ->
        stream_loop(conn, identifier, turn_id, completion_id)

      {:turn_event, ^identifier, :turn_completed, %{turn_id: ^turn_id}} ->
        chunk(conn, completion_id, nil, "stop")

      {:turn_event, ^identifier, :turn_failed, %{turn_id: ^turn_id} = payload} ->
        conn = chunk(conn, completion_id, "**system:** " <> inspect(Map.get(payload, :reason, :failed)), nil)
        chunk(conn, completion_id, nil, "stop")

      {:turn_event, ^identifier, :turn_input_required, %{turn_id: ^turn_id}} ->
        conn = chunk(conn, completion_id, "**system:** Agent is awaiting approval. Resolve in the dashboard to continue.", nil)
        chunk(conn, completion_id, nil, "tool_calls")

      {:turn_watchdog, ^turn_id} ->
        conn = chunk(conn, completion_id, "**system:** Agent appears to have hung - no response in 10 minutes. Reload the pane to try again.", nil)
        chunk(conn, completion_id, nil, "timeout")

      _other ->
        stream_loop(conn, identifier, turn_id, completion_id)
    after
      @watchdog_ms ->
        conn = chunk(conn, completion_id, "**system:** Agent appears to have hung - no response in 10 minutes. Reload the pane to try again.", nil)
        chunk(conn, completion_id, nil, "timeout")
    end
  end

  defp collect_turn(identifier, turn_id, acc) do
    receive do
      {:transcript_event, %{role: role, body: body, turn_id: ^turn_id}} when role in [:assistant, :command] ->
        collect_turn(identifier, turn_id, [body | acc])

      {:turn_event, ^identifier, :turn_completed, %{turn_id: ^turn_id}} ->
        acc |> Enum.reverse() |> Enum.join("\n")

      _other ->
        collect_turn(identifier, turn_id, acc)
    after
      @watchdog_ms -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp emit_error_and_close(conn, completion_id, reason) do
    conn = chunk(conn, completion_id, "**system:** " <> inspect(reason), nil)
    chunk(conn, completion_id, nil, "stop")
  end

  defp chunk(conn, completion_id, content, finish_reason) do
    payload = build_chunk(completion_id, %{content: content, finish_reason: finish_reason})
    {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")
    conn
  end

  defp delta(nil), do: %{}
  defp delta(content), do: %{content: content}

  defp identifier_from_model(model) when is_binary(model) do
    if placeholder_model?(model) do
      {:error, :placeholder_session}
    else
      # opencode sends just `issue-<id>` to the provider's chat-completions endpoint;
      # the `aiur/` provider routing has already happened. Accept both shapes.
      prefix = Regex.escape(Config.model_prefix())
      regex = ~r/\A(?:#{prefix}\/)?issue-([A-Za-z0-9._-]+)\z/

      case Regex.run(regex, model) do
        [_match, identifier] ->
          {:ok, identifier}

        _ ->
          Logger.warning("opencode_bridge invalid_model received_model=#{inspect(model)}")
          {:error, :invalid_model}
      end
    end
  end

  defp identifier_from_model(model) do
    Logger.warning("opencode_bridge invalid_model received_model=#{inspect(model)}")
    {:error, :invalid_model}
  end

  defp placeholder_model?(model) do
    prefix = Config.model_prefix()
    model == "placeholder" or model == "#{prefix}/placeholder"
  end

  defp empty_stream(conn) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    conn
  end

  # Synthetic-marker round-trip: `SessionWriter` writes assistant rows
  # directly into opencode's SQLite, then POSTs a synthetic user message
  # carrying `__aiur_stream__:<msg_id>`. opencode triggers a chat-completion
  # call here; we read the just-written rows back and stream them as
  # assistant deltas so the attached TUI renders them in real time.
  defp replay_message_as_stream(conn, identifier, message_id) do
    completion_id = "chatcmpl-" <> random_id()

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    session_id =
      case SessionWriterRegistry.lookup(identifier) do
        {:ok, %{session_id: sid}} -> sid
        _ -> nil
      end

    case session_id && Db.fetch_message_with_parts(session_id, message_id) do
      {:ok, %{parts: parts}} ->
        conn = Enum.reduce(parts, conn, &chunk_part(&1, &2, completion_id))
        chunk(conn, completion_id, nil, "stop")

      _ ->
        Logger.warning("opencode_bridge stream_replay message_not_found identifier=#{identifier} message_id=#{message_id}")

        conn = chunk(conn, completion_id, "**system:** message not found", nil)
        chunk(conn, completion_id, nil, "stop")
    end
  end

  defp chunk_part(%{"type" => "text", "text" => text}, conn, completion_id)
       when is_binary(text) and text != "" do
    chunk(conn, completion_id, text, nil)
  end

  defp chunk_part(_, conn, _completion_id), do: conn

  defp last_user_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => text} when is_binary(text) -> text
      %{"role" => "user", "content" => parts} when is_list(parts) -> text_from_parts(parts)
      _ -> nil
    end)
    |> case do
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, :missing_user_message}
    end
  end

  defp last_user_text(_), do: {:error, :missing_user_message}

  defp text_from_parts(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp validate_body(body) when byte_size(body) > @max_body_bytes, do: {:error, :body_too_large}

  defp validate_body(body) do
    if String.valid?(body) do
      {:ok, String.replace(body, ~r/[\x00-\x08\x0B-\x1F]/, "")}
    else
      {:error, :invalid_utf8}
    end
  end

  defp maybe_authorized(conn, _identifier) do
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

  defp auth_failed_body do
    %{
      error: "auth_failed",
      message: "Bridge token did not match an active workspace. If Aiur was restarted, close and reopen the pane to refresh the token."
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp random_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
