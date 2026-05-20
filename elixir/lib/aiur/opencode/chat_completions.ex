defmodule Aiur.Opencode.ChatCompletions do
  @moduledoc false

  alias Aiur.{AgentChat, AgentPubSub}
  alias Aiur.Opencode.Config

  @max_body_bytes 65_536
  @watchdog_ms 600_000

  @spec handle(map(), Plug.Conn.t()) :: Plug.Conn.t()
  def handle(body, conn) do
    with {:ok, identifier} <- identifier_from_model(Map.get(body, "model")),
         {:ok, text} <- last_user_text(body),
         {:ok, sanitized} <- validate_body(text),
         {:ok, conn} <- maybe_authorized(conn, identifier) do
      if Map.get(body, "stream", true) do
        stream_turn(conn, identifier, sanitized)
      else
        non_stream_turn(conn, identifier, sanitized)
      end
    else
      {:error, :unauthorized} -> json(conn, 401, auth_failed_body())
      {:error, :body_too_large} -> json(conn, 400, %{error: "body too large"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

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
    AgentChat.send(identifier, text,
      delivery_policy: :checkpoint,
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
    prefix = Regex.escape(Config.model_prefix())
    regex = ~r/\A#{prefix}\/issue-([A-Za-z0-9._-]+)\z/

    case Regex.run(regex, model) do
      [_match, identifier] -> {:ok, identifier}
      _ -> {:error, :invalid_model}
    end
  end

  defp identifier_from_model(_), do: {:error, :invalid_model}

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
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp validate_body(body) when byte_size(body) > @max_body_bytes, do: {:error, :body_too_large}

  defp validate_body(body) do
    if String.valid?(body) do
      {:ok, String.replace(body, ~r/[\x00-\x08\x0B-\x1F]/, "")}
    else
      {:error, :invalid_utf8}
    end
  end

  defp maybe_authorized(conn, identifier) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         true <- Aiur.Opencode.TokenRegistry.valid?(token, identifier) do
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
