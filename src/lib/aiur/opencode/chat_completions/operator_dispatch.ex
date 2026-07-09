defmodule Aiur.Opencode.ChatCompletions.OperatorDispatch do
  @moduledoc """
  Route an operator text message to the agent and close the SSE.

  Validates the request body, authorizes the caller, dispatches the
  message to `AgentChat`, and returns the conn with the SSE closed. All
  three response paths (stream, non-stream, error) close via `Sse`.
  """

  require Logger

  alias Aiur.AgentChat
  alias Aiur.Opencode.OperatorText
  alias Aiur.Opencode.ChatCompletions.{Caller, Sse, TurnRequest}

  @spec dispatch_user_text(map(), Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def dispatch_user_text(body, conn, identifier, raw_text) do
    with {:ok, sanitized} <- TurnRequest.validate_body(raw_text),
         {:ok, conn} <- Caller.authorize(conn) do
      route_turn(conn, identifier, sanitized, Map.get(body, "stream", true))
    else
      {:error, :unauthorized} -> Sse.json(conn, 401, Caller.auth_failed_body())
      {:error, :body_too_large} -> Sse.json(conn, 400, %{error: "body too large"})
      {:error, reason} -> Sse.json(conn, 400, %{error: inspect(reason)})
    end
  end

  # `:auto` lets the backend decide: the persistent-REPL backend takes the
  # message immediately mid-turn, while codex/headless-claude hold it at the
  # next safe checkpoint (native CLI UX). Wait time is captured by
  # `Aiur.OperatorWaitLog`.
  @spec send_operator(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_operator(identifier, text, turn_id) do
    normalized = OperatorText.normalize(text)
    log_operator_text(identifier, text, normalized)

    case normalized do
      "" ->
        # Opencode wrapped a synthetic reminder with no operator content
        # (e.g. its own cwd-change / file-open scaffolding) — nothing for
        # the agent. Ack cleanly without forwarding.
        {:ok, :noop}

      operator_text ->
        AgentChat.send(identifier, operator_text,
          delivery_policy: :auto,
          turn_id: turn_id
        )
    end
  end

  defp route_turn(conn, identifier, sanitized, true),
    do: stream_turn(conn, identifier, sanitized)

  defp route_turn(conn, identifier, sanitized, _),
    do: non_stream_turn(conn, identifier, sanitized)

  # The operator-message SSE no longer waits for the agent to reply. As
  # soon as `AgentChat.send` accepts the message (either delivers via
  # `:interrupt` or queues via `:queue_next`), we close the SSE with
  # `finish_reason: "stop"` so opencode-attach clears the `QUEUED`
  # indicator within ~1s. The agent's response streams back through the
  # per-turn marker bridge (`stream_codex_turn`) when the next codex
  # turn fires — no need to hold this SSE open on a bridge-local turn_id
  # pin that codex transcript events would never match.
  defp stream_turn(conn, identifier, text) do
    turn_id = Sse.random_id()
    completion_id = "chatcmpl-" <> Sse.random_id()

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        Sse.chunk(conn, completion_id, nil, "stop")

      {:error, reason} ->
        emit_error_and_close(conn, completion_id, reason)
    end
  end

  defp non_stream_turn(conn, identifier, text) do
    turn_id = Sse.random_id()

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        Sse.json(conn, 200, %{
          id: "chatcmpl-" <> Sse.random_id(),
          object: "chat.completion",
          choices: [%{index: 0, message: %{role: "assistant", content: ""}, finish_reason: "stop"}]
        })

      {:error, reason} ->
        Sse.json(conn, 200, %{error: inspect(reason)})
    end
  end

  # Durable, greppable operator-path trace. The next live `--test3` repro
  # greps `opencode_bridge operator_text` to pin delivery-vs-drop: the BUG
  # signature is `wrapped=true dropped=true` — a genuine (non-blank) operator
  # message was present but normalize forwarded nothing, so `send_operator/3`
  # noops it and the agent never sees it (issue #332). `wrapped=false` covers
  # both raw text and opencode's own scaffolding-only reminders (and an
  # empty-bodied wrapper, which is not a message), so none raise a false alarm.
  # Bytes (not content) keep the operator's words out of the logs.
  defp log_operator_text(identifier, raw, normalized) do
    trace = OperatorText.trace(raw, normalized)

    Logger.info(
      "opencode_bridge operator_text identifier=#{identifier} " <>
        "in_bytes=#{trace.in_bytes} out_bytes=#{trace.out_bytes} " <>
        "wrapped=#{trace.wrapped} dropped=#{trace.dropped}"
    )
  end

  defp emit_error_and_close(conn, completion_id, reason) do
    conn = Sse.chunk(conn, completion_id, "**system:** " <> inspect(reason), nil)
    Sse.chunk(conn, completion_id, nil, "stop")
  end
end
