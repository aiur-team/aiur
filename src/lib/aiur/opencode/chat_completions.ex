defmodule Aiur.Opencode.ChatCompletions do
  @moduledoc false

  require Logger

  alias Aiur.{AgentChat, AgentPubSub}
  alias Aiur.Events.DebugLog

  alias Aiur.Opencode.{
    ActiveTurns,
    Config,
    Db,
    EventRow,
    SessionWriterRegistry,
    Slot,
    SlotRegistry,
    Style,
    TokenRegistry
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

  @max_body_bytes 65_536
  @watchdog_ms 600_000
  # SSE keepalive interval. Empirically opencode-attach's HTTP client
  # times out the chat-completion request after ~28-30s of silence and
  # reopens it, which used to create multiple bridge subscribers (3x
  # rendering of every transcript event). Sending an empty-delta chunk
  # well under that timeout keeps the connection warm so each turn has
  # exactly one bridge process.
  @heartbeat_ms 15_000

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
    case last_user_text(body) do
      {:ok, text} -> handle_identified_text(body, conn, identifier, text)
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_identified_text(_body, conn, identifier, @turn_marker_prefix <> _ = marker) do
    case Regex.run(@turn_marker_regex, marker) do
      [_, aiur_turn_id] -> stream_codex_turn(conn, identifier, aiur_turn_id)
      _ -> json(conn, 400, %{error: "invalid turn marker"})
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
    dispatch_user_text(body, conn, identifier, raw_text)
  end

  # Bridge-as-LLM path: an Aiur.AgentRunner posted `__aiur_turn__:<id>` to
  # opencode at the start of a codex turn. opencode wrote that as a user
  # message and now opens this chat-completion request to fetch the
  # "assistant response". We hold the SSE open and stream every
  # transcript-event body and turn-event signal that fires on this
  # identifier's AgentPubSub topic, until the codex turn finishes.
  # opencode renders ONE assistant message that streams in live —
  # matching native opencode UX. SessionWriter still writes parts to
  # SQL in parallel so re-attach renders complete history from disk
  # (manual-override preserved: agents work without opencode attached).
  defp stream_codex_turn(conn, identifier, aiur_turn_id) do
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

    case ActiveTurns.lookup(identifier, aiur_turn_id) do
      :active ->
        Logger.info("opencode_bridge turn_stream_open identifier=#{identifier} aiur_turn=#{aiur_turn_id}")
        Process.send_after(self(), {:turn_watchdog, aiur_turn_id}, @watchdog_ms)
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, nil)

      {:closed, reason} ->
        Logger.info("opencode_bridge turn_stream_late_close identifier=#{identifier} aiur_turn=#{aiur_turn_id} reason=#{inspect(reason)}")
        _ = DebugLog.unsubscribe()
        finalize_stream(conn, completion_id, reason)

      :not_found ->
        # No AgentRunner registered this aiur_turn_id this boot — the
        # marker was replayed by opencode-serve from a prior session
        # whose run_turn never completed. Close without rendering the
        # 10-minute watchdog notice.
        Logger.info("opencode_bridge turn_stream_phantom identifier=#{identifier} aiur_turn=#{aiur_turn_id}")
        _ = DebugLog.unsubscribe()
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
  defp codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role) do
    receive do
      {:transcript_event, %{role: role, body: body} = event}
      when role in [:assistant, :command, :system, :alert, :reasoning, :tool] ->
        delta = bar_connector(last_role, role) <> format_delta(role, body, event)
        conn = chunk(conn, completion_id, delta, nil)
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, role)

      # A remote-origin user message (typed in the Claude Remote Control
      # app) is the one `:user` event opencode never echoed locally, so
      # render it. Opencode-origin `:user` events carry no payload and
      # fall through to the drop clause below to avoid double-rendering
      # the operator's own typed input.
      {:transcript_event, %{role: :user, body: body, payload: %{origin: :remote}}} ->
        delta = bar_connector(last_role, :system) <> format_delta(:user, body)
        conn = chunk(conn, completion_id, delta, nil)
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, :system)

      {:transcript_event, %{role: :user}} ->
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role)

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
              codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role)

            body ->
              delta = bar_connector(last_role, :event_debug) <> "\n#{body}\n"
              conn = chunk(conn, completion_id, delta, nil)
              codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, :event_debug)
          end
        else
          codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role)
        end

      {:aiur_turn_done, ^identifier, ^aiur_turn_id, reason} ->
        Logger.info("opencode_bridge turn_stream_close identifier=#{identifier} aiur_turn=#{aiur_turn_id} reason=#{inspect(reason)}")
        _ = DebugLog.unsubscribe()
        finalize_stream(conn, completion_id, reason)

      :heartbeat ->
        # Empty-delta chunk keeps opencode's HTTP client from timing
        # out and reopening the chat-completion request mid-turn. The
        # chunk renders as nothing in the chat pane.
        conn = chunk(conn, completion_id, nil, nil)
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role)

      {:turn_watchdog, ^aiur_turn_id} ->
        Logger.warning("opencode_bridge turn_stream_watchdog identifier=#{identifier} aiur_turn=#{aiur_turn_id}")

        conn =
          chunk(
            conn,
            completion_id,
            "\n**system:** No turn activity in 10 minutes; closing stream.",
            nil
          )

        chunk(conn, completion_id, nil, "timeout")

      _other ->
        codex_turn_stream_loop(conn, identifier, aiur_turn_id, completion_id, last_role)
    after
      @watchdog_ms ->
        conn =
          chunk(
            conn,
            completion_id,
            "\n**system:** No turn activity in 10 minutes; closing stream.",
            nil
          )

        chunk(conn, completion_id, nil, "timeout")
    end
  end

  defp finalize_stream(conn, completion_id, {:failed, reason}) do
    conn = chunk(conn, completion_id, "\n**system:** " <> inspect(reason), nil)
    chunk(conn, completion_id, nil, "stop")
  end

  defp finalize_stream(conn, completion_id, :input_required) do
    conn =
      chunk(
        conn,
        completion_id,
        "\n**system:** Agent is awaiting approval. Resolve in the dashboard to continue.",
        nil
      )

    chunk(conn, completion_id, nil, "tool_calls")
  end

  defp finalize_stream(conn, completion_id, _reason),
    do: chunk(conn, completion_id, nil, "stop")

  # Format a transcript event's body as a chat-completion delta. The
  # SQL part written by SessionWriter is authoritative; this is the
  # live-stream summary. Public so tests can exercise it without going
  # through Plug.Conn.
  #
  # Commands and generic tools render through `Style.dim/1` so opencode's
  # glamour pipeline draws them as a dim blockquote with a left-margin
  # bar — same visual vocabulary as :system/:alert and the edit/read
  # tool rows. This subordinates command chatter under the agent's prose
  # and shares one visual language across non-agent content.
  @doc false
  @spec format_delta(atom(), String.t()) :: String.t()
  def format_delta(role, body), do: format_delta(role, body, %{})

  @doc """
  Format a transcript event into an SSE chunk-ready string. The
  optional `event` map carries the full transcript event (role, body,
  payload, …) so role-specific formatters can pick up payload fields
  the body string alone doesn't carry. Currently used by `:tool`'s
  `edit` branch to surface the file-change diff hunks via a fenced
  ```diff block beneath the summary line.
  """
  @spec format_delta(atom(), String.t(), map()) :: String.t()
  def format_delta(:command, body, _event) do
    # Convert literal `\n` sequences from codex's transcript JSON
    # into real newlines so multi-line heredocs render as multiple
    # rows in the chat pane instead of showing the escape glyphs.
    normalized = normalize_escaped_newlines(body)
    render_dim_blockquote("$ ", normalized)
  end

  def format_delta(:tool, body, event) do
    cond do
      String.starts_with?(body, "edit ") ->
        diff = edit_diff_from_payload(event)
        path = String.trim_leading(body, "edit ")
        summary = render_dim_blockquote("✏️  ", "edit " <> path)

        if diff == "" do
          summary
        else
          # Show the summary then the actual diff hunks. Glamour
          # renders ```diff fences with red/green highlighting on
          # +/- lines — close to the native opencode edit-tool look
          # without forking opencode.
          String.trim_trailing(summary) <> "\n\n```diff\n#{diff}\n```\n"
        end

      String.starts_with?(body, "read ") ->
        path = String.trim_leading(body, "read ")
        render_dim_blockquote("📖 ", "read " <> path)

      true ->
        normalized = normalize_escaped_newlines(body)
        render_dim_blockquote("→ ", normalized)
    end
  end

  def format_delta(:reasoning, body, _event), do: "\n_#{body}_\n"
  def format_delta(:alert, body, _event), do: "\n> 🔔 #{body}\n"
  def format_delta(:system, body, _event), do: "\n> #{body}\n"
  # Remote Control app message — the only `:user` line the bridge renders.
  def format_delta(:user, body, _event), do: "\n> 💬 #{body}\n"
  def format_delta(_role, body, _event), do: body

  # Render a command-style line as `> <prefix>\`<body>\`` so the
  # leading prefix (emoji + space, or `$ `) stays OUTSIDE the
  # inline-code span. Glamour paints inline code via `markdownCode`
  # (theme: `darkStep11` grey), giving us a visibly-dim body while
  # the emoji prefix and the blockquote bar keep their normal
  # colors.
  #
  # When the body contains literal newlines OR backticks, falls
  # back to the bar-only blockquote via `Style.dim/1`. Inline code
  # can't wrap content with `\``s (they'd close the span midway)
  # or `\n`s (inline code is a one-line construct).
  defp render_dim_blockquote(prefix, body) do
    if String.contains?(body, "\n") or String.contains?(body, "`") do
      "\n" <> Style.dim(prefix <> body) <> "\n"
    else
      "\n> #{prefix}`#{body}`\n"
    end
  end

  # Codex transcripts arrive as JSON-decoded strings. A shell
  # `$'…\n…'` heredoc gets stored as a single Elixir string where
  # the `\n` characters are real newlines (JSON decoded them) — but
  # SOMETIMES the agent sees them as escape sequences (literal
  # `\` followed by `n`), so we normalise the literal form too.
  defp normalize_escaped_newlines(body) do
    body
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
  end

  # Pull the diff content out of a `:tool` transcript event for the
  # `edit` tool. `Aiur.Codex.Transcript.build_tool_payload/2` stuffs
  # the joined diff into the payload's `:output` field; we surface
  # it here when present.
  #
  # Codex emits two shapes for file edits:
  #   1. A unified diff (lines start with `@@`, `+`, `-`, ` `) when
  #      the edit was a patch.
  #   2. The full new file content with no diff markers when the
  #      edit was a whole-file replace or new-file create.
  #
  # Glamour renders ```diff blocks by coloring lines based on their
  # leading character: `+` → green, `-` → red, ` ` → context. Shape
  # 1 already paints correctly. For shape 2, every line is treated
  # as context (no color). We detect shape 2 and prefix each line
  # with `+ ` so the whole block reads as additions (green), making
  # the change visible at a glance.
  defp edit_diff_from_payload(%{payload: %{output: output, tool: "edit"}})
       when is_binary(output) and output != "" do
    if looks_like_unified_diff?(output) do
      output
    else
      output
      |> String.split("\n")
      |> Enum.map_join("\n", &("+ " <> &1))
    end
  end

  defp edit_diff_from_payload(_), do: ""

  defp looks_like_unified_diff?(text) do
    String.contains?(text, "\n@@ ") or
      String.starts_with?(text, "@@ ") or
      String.contains?(text, "\n+++") or
      String.contains?(text, "\n--- ")
  end

  @doc """
  Inter-chunk connector for the chat-completion delta stream. Two
  cases that need handling:

  1. **blockquote → blockquote** — the blank line between them must
     carry the `>` bar or glamour renders two separate blockquotes
     with a visible gap. Connector: `"> "`. Combined with the
     trailing `\\n` of the previous chunk and the leading `\\n` of
     the next, this produces a `> ` line on its own (continuous
     vertical bar through the gap).

  2. **blockquote → prose** — without a connector here, markdown's
     lazy-continuation rule pulls the next prose line INTO the
     prior blockquote because only one `\\n` separates them.
     Connector: `"\\n"` (extra blank line to terminate the
     blockquote before prose starts).

  All other transitions return `""`. `nil` previous role means
  "first chunk of the turn" — never a connector.
  """
  @spec bar_connector(atom() | nil, atom()) :: String.t()
  def bar_connector(prev_role, curr_role) do
    cond do
      blockquote_role?(prev_role) and blockquote_role?(curr_role) -> "> "
      blockquote_role?(prev_role) and not blockquote_role?(curr_role) -> "\n"
      true -> ""
    end
  end

  defp blockquote_role?(role) when role in [:command, :tool, :system, :alert, :event_debug], do: true
  defp blockquote_role?(_), do: false

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
    AgentChat.send(identifier, text,
      delivery_policy: :auto,
      turn_id: turn_id
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
