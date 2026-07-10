defmodule Aiur.Opencode.ChatCompletions do
  @moduledoc false

  require Logger

  alias Aiur.Opencode.ChatCompletions.{
    Caller,
    OperatorDispatch,
    Replay,
    Sse,
    TurnRequest,
    TurnStream
  }

  alias Aiur.Opencode.{
    Config,
    TurnMarkers
  }

  @stream_marker_prefix "__aiur_stream__:"
  @stream_marker_regex ~r/\A__aiur_stream__:(msg_[A-Z0-9]+)\z/
  # Nudge markers ("__aiur_stream__:nudge:<N>") are sent by Slot workers
  # to force opencode-attach to re-render after a select. They aren't
  # tied to a specific message id; the bridge just returns an empty
  # SSE stream so opencode treats the turn as a no-op rather than
  # rendering a "Bad Request: invalid stream marker" toast.
  @nudge_marker_regex ~r/\A__aiur_stream__:nudge:/

  # Turn-start marker posted by Aiur.AgentRunner at the start of every
  # codex turn so opencode-attach opens a chat-completion request that
  # the bridge can hold open for the turn's full duration. The bridge
  # subscribes to AgentPubSub for the identifier and streams every
  # transcript-event body as an SSE delta until a `turn_event` arrives
  # — implementing the "bridge as LLM" path described in
  # docs/plans/2026-05-25-001-feat-chat-pane-native-parity-plan.md.
  @turn_marker_prefix "__aiur_turn__:"
  @turn_marker_regex ~r/\A__aiur_turn__:([A-Za-z0-9_-]+)\z/

  @spec handle(map(), Plug.Conn.t()) :: Plug.Conn.t()
  def handle(body, conn) do
    case identifier_from_model(Map.get(body, "model")) do
      {:ok, identifier} ->
        handle_identified(body, conn, identifier)

      {:error, :placeholder_session} ->
        # Stray call against the warm placeholder session. Return an empty
        # SSE stream so opencode doesn't render an error toast.
        Sse.empty_stream(conn)

      {:error, reason} ->
        Sse.json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_identified(body, conn, identifier) do
    case TurnRequest.last_user_text(body) do
      {:ok, text} -> handle_identified_text(body, conn, identifier, text)
      {:error, reason} -> Sse.json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_identified_text(body, conn, identifier, @turn_marker_prefix <> _ = marker) do
    case Regex.run(@turn_marker_regex, marker) do
      [_, aiur_turn_id] ->
        # Coalescing defense: if opencode folded queued operator text into
        # this request's trailing user batch, the marker (routed as the last
        # user message) would otherwise silently shadow it. Dispatch any
        # non-marker text in the batch before streaming the segment.
        dispatch_shadowed_operator_texts(body, identifier)
        TurnStream.stream(conn, identifier, aiur_turn_id)

      _ ->
        Sse.json(conn, 400, %{error: "invalid turn marker"})
    end
  end

  defp handle_identified_text(_body, conn, identifier, @stream_marker_prefix <> _ = marker) do
    cond do
      Regex.match?(@nudge_marker_regex, marker) ->
        Sse.empty_stream(conn)

      match = Regex.run(@stream_marker_regex, marker) ->
        [_, message_id] = match
        Replay.stream(conn, identifier, message_id)

      true ->
        Sse.json(conn, 400, %{error: "invalid stream marker"})
    end
  end

  defp handle_identified_text(body, conn, identifier, raw_text) do
    # Symmetric coalescing defense: when operator text routes (it was the
    # LAST user message), a turn marker coalesced earlier in the same
    # trailing batch would be consumed without ever opening its segment
    # stream. Re-post any such marker so the segment resumes after this
    # operator message dispatches.
    repost_shadowed_markers(body, conn, identifier)
    OperatorDispatch.dispatch_user_text(body, conn, identifier, raw_text)
  end

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

  # Operator text coalesced BEHIND the routed marker: dispatch it to the
  # agent before the segment stream opens, else it is silently dropped.
  defp dispatch_shadowed_operator_texts(body, identifier) do
    body
    |> TurnRequest.trailing_user_texts()
    # The routed (last) message handles itself in the caller.
    |> Enum.drop(-1)
    |> Enum.reject(&TurnRequest.synthetic_marker_text?/1)
    |> Enum.each(fn text ->
      case TurnRequest.validate_body(text) do
        {:ok, sanitized} when sanitized != "" ->
          Logger.info("opencode_bridge coalesced_operator_text identifier=#{identifier}")
          _ = OperatorDispatch.send_operator(identifier, sanitized, Sse.random_id())

        _ ->
          :ok
      end
    end)
  end

  # Turn marker coalesced BEHIND routed operator text: re-post it so the
  # segment stream still opens once this request closes.
  defp repost_shadowed_markers(body, conn, identifier) do
    markers =
      body
      |> TurnRequest.trailing_user_texts()
      |> Enum.drop(-1)
      |> Enum.filter(&String.starts_with?(&1, @turn_marker_prefix))

    with [_ | _] <- markers,
         writer when not is_nil(writer) <- Caller.writer(conn, identifier) do
      Enum.each(markers, fn @turn_marker_prefix <> marker_id ->
        Logger.info("opencode_bridge shadowed_marker_repost identifier=#{identifier} marker=#{marker_id}")
        TurnMarkers.post_marker(identifier, marker_id, writer)
      end)
    else
      _ -> :ok
    end
  end
end
