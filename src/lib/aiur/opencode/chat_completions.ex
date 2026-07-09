defmodule Aiur.Opencode.ChatCompletions do
  @moduledoc false

  require Logger

  alias Aiur.{AgentChat, AgentPubSub}
  alias Aiur.Events.DebugLog

  alias Aiur.Opencode.OperatorText
  alias Aiur.Opencode.ChatCompletions.{DeltaRenderer, StreamPolicy, TurnRequest}

  alias Aiur.Opencode.{
    ActiveTurns,
    Config,
    Db,
    EventRow,
    SessionWriterRegistry,
    Slot,
    SlotRegistry,
    TokenRegistry,
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
        empty_stream(conn)

      {:error, reason} ->
        json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_identified(body, conn, identifier) do
    case TurnRequest.last_user_text(body) do
      {:ok, text} -> handle_identified_text(body, conn, identifier, text)
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
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
        stream_codex_turn(conn, identifier, aiur_turn_id)

      _ ->
        json(conn, 400, %{error: "invalid turn marker"})
    end
  end

  defp handle_identified_text(_body, conn, identifier, @stream_marker_prefix <> _ = marker) do
    cond do
      Regex.match?(@nudge_marker_regex, marker) ->
        empty_stream(conn)

      match = Regex.run(@stream_marker_regex, marker) ->
        [_, message_id] = match
        replay_message_as_stream(conn, identifier, message_id)

      true ->
        json(conn, 400, %{error: "invalid stream marker"})
    end
  end

  defp handle_identified_text(body, conn, identifier, raw_text) do
    # Symmetric coalescing defense: when operator text routes (it was the
    # LAST user message), a turn marker coalesced earlier in the same
    # trailing batch would be consumed without ever opening its segment
    # stream. Re-post any such marker so the segment resumes after this
    # operator message dispatches.
    repost_shadowed_markers(body, conn, identifier)
    dispatch_user_text(body, conn, identifier, raw_text)
  end

  # Bridge-as-LLM path: an Aiur.AgentRunner posted `__aiur_turn__:<id>` to
  # opencode at the start of a codex turn. opencode wrote that as a user
  # message and now opens this chat-completion request to fetch the
  # "assistant response". We stream every transcript-event body and
  # turn-event signal that fires on this identifier's AgentPubSub topic
  # until the codex turn finishes OR a segment boundary closes this SSE —
  # in which case a continuation marker (`<parent>-s<N>`) was posted just
  # before the close, opencode flushes any queued operator input, and the
  # next segment's request resumes streaming. SessionWriter still writes
  # parts to SQL in parallel so re-attach renders complete history from
  # disk (manual-override preserved: agents work without opencode attached).
  #
  # The marker may carry a `-s<N>` segment suffix; ActiveTurns and
  # `:aiur_turn_done` are keyed by the bare PARENT id only (an exact-key
  # lookup with the suffixed id would phantom-close every segment).
  defp stream_codex_turn(conn, identifier, marker_turn_id) do
    {parent_id, seg_n} = TurnMarkers.parse_turn_id(marker_turn_id)
    completion_id = "chatcmpl-" <> random_id()
    # Subscribe first so a close broadcast that races our ActiveTurns
    # lookup still lands in the mailbox; we drain it inside the loop.
    :ok = AgentPubSub.subscribe_agent(identifier)
    # Subscribe to the cross-ticket event debug stream for the duration
    # of this codex turn so 📬/📤/📄 ticker rows for THIS agent get
    # chunked inline in the active assistant message (R2 live render).
    # Filtering by identifier happens in the receive clause.
    :ok = DebugLog.subscribe()

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    case ActiveTurns.lookup(identifier, parent_id) do
      :active ->
        Logger.info("opencode_bridge turn_stream_open identifier=#{identifier} aiur_turn=#{parent_id} seg=#{seg_n}")
        Process.send_after(self(), {:turn_watchdog, parent_id}, StreamPolicy.watchdog_ms())
        Process.send_after(self(), :heartbeat, StreamPolicy.heartbeat_ms())

        seg = %{
          n: seg_n,
          # nil writer = cannot resolve the caller's serve; segmentation is
          # disabled for this stream and it degrades to the long-held SSE.
          writer: originating_writer(conn, identifier),
          opened_at: now_ms(),
          last_event_at: now_ms(),
          streamed?: false,
          threshold_ms: StreamPolicy.segment_threshold_ms()
        }

        codex_turn_stream_loop(conn, identifier, parent_id, completion_id, nil, seg)

      {:closed, reason} ->
        Logger.info("opencode_bridge turn_stream_late_close identifier=#{identifier} aiur_turn=#{parent_id} reason=#{inspect(reason)}")
        unsubscribe_stream(identifier)
        finalize_stream(conn, completion_id, reason)

      :not_found ->
        # No AgentRunner registered this parent id this boot — the marker
        # was replayed by opencode-serve from a prior session whose
        # run_turn never completed. Close without rendering the 10-minute
        # watchdog notice.
        Logger.info("opencode_bridge turn_stream_phantom identifier=#{identifier} aiur_turn=#{parent_id}")
        unsubscribe_stream(identifier)
        finalize_stream(conn, completion_id, :done)
    end
  end

  # Receive loop for a single aiur turn. Lifecycle is bounded by
  # `Aiur.AgentRunner`'s `run_turn` call — when that call returns,
  # agent_runner broadcasts `{:aiur_turn_done, identifier, aiur_turn_id, reason}`
  # and the bridge closes the SSE with the matching finish reason.
  # We intentionally do NOT filter transcript events by codex's
  # `params.turnId`: operator messages injected mid-codex-turn share
  # the active turnId (verified empirically), and any internal codex
  # sub-turn boundaries are an implementation detail we render as
  # one growing assistant message (Approach C.2 per the brainstorm).
  defp codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg) do
    receive do
      {:transcript_event, event} ->
        stream_event_then_continue(conn, identifier, parent_id, completion_id, last_role, seg, event)

      # R2 live render — cross-ticket event ticker row for THIS agent.
      # DebugLog broadcasts on a global topic; filter via
      # `EventRow.matches?/2` (identifier match OR topic prefix match)
      # and silently drop entries scoped to other agents. The row
      # content is wrapped via `EventRow.from/2`'s `Style.dim/1`. The
      # rendering identifier is passed so :publish entries on this
      # agent's own topics render in first person.
      {:event_debug, entry} ->
        if EventRow.matches?(entry, identifier) do
          case EventRow.from(entry, identifier) do
            nil ->
              codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)

            body ->
              delta = DeltaRenderer.bar_connector(last_role, :event_debug) <> "\n#{body}\n"
              conn = chunk(conn, completion_id, delta, nil)
              seg = %{seg | last_event_at: now_ms(), streamed?: true}
              codex_turn_stream_loop(conn, identifier, parent_id, completion_id, :event_debug, seg)
          end
        else
          codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)
        end

      {:aiur_turn_done, ^identifier, ^parent_id, reason} ->
        Logger.info("opencode_bridge turn_stream_close identifier=#{identifier} aiur_turn=#{parent_id} reason=#{inspect(reason)}")
        unsubscribe_stream(identifier)
        finalize_stream(conn, completion_id, reason)

      :heartbeat ->
        # The heartbeat doubles as the idle-boundary clock: a segment that
        # has streamed content but gone quiet closes here so queued
        # operator input flushes during silent stretches (origin R4's idle
        # cadence). Empty continuation segments do NOT idle-close — that
        # would churn one marker per threshold through a long quiet tool
        # run with nothing to flush it for.
        if seg.writer != nil and
             StreamPolicy.idle_segment_boundary?(
               seg.streamed?,
               seg.n,
               now_ms() - seg.opened_at,
               now_ms() - seg.last_event_at,
               seg.threshold_ms,
               StreamPolicy.heartbeat_ms()
             ) do
          close_segment(conn, identifier, parent_id, completion_id, seg)
        else
          # Empty-delta chunk keeps opencode's HTTP client from timing
          # out and reopening the chat-completion request mid-turn. The
          # chunk renders as nothing in the chat pane.
          conn = chunk(conn, completion_id, nil, nil)
          Process.send_after(self(), :heartbeat, StreamPolicy.heartbeat_ms())
          codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)
        end

      # Inactivity watchdog. Armed once at stream open (`@watchdog_ms`
      # after the SSE opens), but it is NOT an absolute wall-clock cap:
      # when it fires we compare against `seg.last_event_at` (bumped only
      # by real transcript/event deltas, never by the 15s heartbeat). If
      # genuine activity happened since the timer was armed we reschedule
      # for the remaining window, so an actively-streaming turn is never
      # cut at the 10-minute mark — only true silence closes the stream.
      {:turn_watchdog, ^parent_id} ->
        case StreamPolicy.watchdog_action(now_ms() - seg.last_event_at, StreamPolicy.watchdog_ms()) do
          {:reschedule, delay_ms} ->
            Process.send_after(self(), {:turn_watchdog, parent_id}, delay_ms)
            codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)

          {:close, silent_ms} ->
            Logger.warning("opencode_bridge turn_stream_watchdog identifier=#{identifier} aiur_turn=#{parent_id} silent_ms=#{silent_ms}")
            # Paint the agent row 💤 (AgentEvents.state_emoji/1) so the
            # operator sees the agent went to sleep on a genuinely idle
            # stream. The next turn's `:worker_control_state :working`
            # flips it back to 🟢.
            Aiur.Orchestrator.mark_sleeping(identifier)
            unsubscribe_stream(identifier)

            conn =
              chunk(
                conn,
                completion_id,
                "\n**system:** 💤 No turn activity in #{div(StreamPolicy.watchdog_ms(), 60_000)} minutes; closing stream.",
                nil
              )

            chunk(conn, completion_id, nil, "timeout")
        end

      _other ->
        codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)
    end
  end

  # Drop BOTH subscriptions this stream opened. The agent-topic unsubscribe
  # is the duplication fix: opencode reopens a completion per segment on one
  # keep-alive connection, Bandit reuses the handler process, and without
  # this each segment's `subscribe_agent/1` stacks another subscription so
  # one broadcast event streams N copies into the assistant message.
  defp unsubscribe_stream(identifier) do
    _ = DebugLog.unsubscribe()
    _ = AgentPubSub.unsubscribe_agent(identifier)
    :ok
  end

  # Stream one transcript event's delta, then either close the segment at a
  # boundary or keep looping. Split from the receive loop for readability
  # (and credo's complexity budget).
  defp stream_event_then_continue(conn, identifier, parent_id, completion_id, last_role, seg, event) do
    case DeltaRenderer.transcript_delta(event, last_role) do
      {:delta, delta, new_role} ->
        conn = chunk(conn, completion_id, delta, nil)
        seg = %{seg | last_event_at: now_ms(), streamed?: true}

        if seg.writer != nil and
             StreamPolicy.segment_boundary?(new_role, now_ms() - seg.opened_at, seg.threshold_ms) do
          close_segment(conn, identifier, parent_id, completion_id, seg)
        else
          codex_turn_stream_loop(conn, identifier, parent_id, completion_id, new_role, seg)
        end

      :drop ->
        codex_turn_stream_loop(conn, identifier, parent_id, completion_id, last_role, seg)
    end
  end

  # Close THIS segment: post the continuation marker for the next segment
  # to the originating writer FIRST (it queues behind any operator text
  # opencode is holding), then end the SSE with a normal "stop" so opencode
  # flushes its queue. Aiur state is untouched — the parent turn stays
  # :active and the next segment's request resumes streaming.
  defp close_segment(conn, identifier, parent_id, completion_id, seg) do
    Logger.info("opencode_bridge turn_stream_segment_close identifier=#{identifier} aiur_turn=#{parent_id} seg=#{seg.n}")

    :ok = TurnMarkers.post_continuation(identifier, parent_id, seg.n + 1, seg.writer)
    unsubscribe_stream(identifier)
    chunk(conn, completion_id, nil, "stop")
  end

  # Resolve the writer (serve base_url + session id) whose opencode issued
  # THIS chat-completion request — continuations must go only to the
  # originating serve or N attached panes would multiply segment streams
  # combinatorially. nil disables segmentation for the stream (degrades to
  # the long-held SSE).
  defp originating_writer(conn, identifier) do
    with {:ok, base_url} <- caller_base_url(conn),
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp finalize_stream(conn, completion_id, {:failed, reason} = r) do
    conn = chunk(conn, completion_id, "\n**system:** " <> inspect(reason), nil)
    chunk(conn, completion_id, nil, finish_reason_for(r))
  end

  defp finalize_stream(conn, completion_id, :input_required = r) do
    conn =
      chunk(
        conn,
        completion_id,
        "\n**system:** Agent is awaiting approval. Resolve in the dashboard to continue.",
        nil
      )

    chunk(conn, completion_id, nil, finish_reason_for(r))
  end

  defp finalize_stream(conn, completion_id, reason),
    do: chunk(conn, completion_id, nil, finish_reason_for(reason))

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

  defp dispatch_user_text(body, conn, identifier, raw_text) do
    with {:ok, sanitized} <- TurnRequest.validate_body(raw_text),
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

  # The operator-message SSE no longer waits for the agent to reply. As
  # soon as `AgentChat.send` accepts the message (either delivers via
  # `:interrupt` or queues via `:queue_next`), we close the SSE with
  # `finish_reason: "stop"` so opencode-attach clears the `QUEUED`
  # indicator within ~1s. The agent's response streams back through the
  # per-turn marker bridge (`stream_codex_turn`) when the next codex
  # turn fires — no need to hold this SSE open on a bridge-local turn_id
  # pin that codex transcript events would never match.
  defp stream_turn(conn, identifier, text) do
    turn_id = random_id()
    completion_id = "chatcmpl-" <> random_id()

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_chunked(200)

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        chunk(conn, completion_id, nil, "stop")

      {:error, reason} ->
        emit_error_and_close(conn, completion_id, reason)
    end
  end

  defp non_stream_turn(conn, identifier, text) do
    turn_id = random_id()

    case send_operator(identifier, text, turn_id) do
      {:ok, _request_id} ->
        json(conn, 200, %{
          id: "chatcmpl-" <> random_id(),
          object: "chat.completion",
          choices: [%{index: 0, message: %{role: "assistant", content: ""}, finish_reason: "stop"}]
        })

      {:error, reason} ->
        json(conn, 200, %{error: inspect(reason)})
    end
  end

  # `:auto` lets the backend decide: the persistent-REPL backend takes the
  # message immediately mid-turn, while codex/headless-claude hold it at the
  # next safe checkpoint (native CLI UX). Wait time is captured by
  # `Aiur.OperatorWaitLog`.
  defp send_operator(identifier, text, turn_id) do
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
    conn = chunk(conn, completion_id, "**system:** " <> inspect(reason), nil)
    chunk(conn, completion_id, nil, "stop")
  end

  defp chunk(conn, completion_id, content, finish_reason) do
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

    session_id = resolve_session_for_replay(conn, identifier)

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
    case caller_base_url(conn) do
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

  defp caller_base_url(conn) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, slot_index} <- TokenRegistry.lookup_slot(token),
         {:ok, slot_pid} <- SlotRegistry.lookup(slot_index),
         %{base_url: base_url} when is_binary(base_url) <- Slot.snapshot(slot_pid) do
      {:ok, base_url}
    else
      _ -> :error
    end
  end

  defp chunk_part(%{"type" => "text", "text" => text}, conn, completion_id)
       when is_binary(text) and text != "" do
    chunk(conn, completion_id, text, nil)
  end

  defp chunk_part(_, conn, _completion_id), do: conn

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
          _ = send_operator(identifier, sanitized, random_id())

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
         writer when not is_nil(writer) <- originating_writer(conn, identifier) do
      Enum.each(markers, fn @turn_marker_prefix <> marker_id ->
        Logger.info("opencode_bridge shadowed_marker_repost identifier=#{identifier} marker=#{marker_id}")
        TurnMarkers.post_marker(identifier, marker_id, writer)
      end)
    else
      _ -> :ok
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
