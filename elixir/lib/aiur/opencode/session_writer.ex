defmodule Aiur.Opencode.SessionWriter do
  @moduledoc """
  Per-identifier writer that owns the SQLite-injection lifecycle for one
  agent's opencode session.

  Agents run independently of opencode — direct SQL writes are the
  source of truth so the chat pane remains an *optional* viewer.
  When opencode-serve is running and a chat pane is attached, we
  ALSO fire `PATCH /session/:s/message/:m/part/:p` for each freshly
  written part. opencode's handler upserts the row (no-op against
  our own write) and publishes `message.part.updated` via its
  `/event` SSE so the attached TUI re-renders the part in place —
  the same hook native opencode uses internally during streaming.

  Direct SQL writes alone are invisible to the attached TUI (opencode
  only emits its `message.*` events from inside its own write paths).
  Previously aiur worked around this with a synthetic-user-message
  nudge, but that round-trips through opencode's chat-completion
  pathway and produced a mirror assistant message per nudge —
  duplicate noise that grew worse the more we nudged.

  Transcript events carrying a `turn_id` are grouped into a single
  assistant message per codex turn — first event opens the message
  with a `step-start` part, subsequent events append body parts to
  the same message, and the matching `:turn_event` appends a
  `step-finish`. Events with `turn_id: nil` keep the standalone-message
  shape (step-start + body + step-finish in one transaction).

  See `elixir/docs/notes/opencode-row-shapes-1.15.6.md` for row JSON
  shapes (kept in `Aiur.Opencode.Protocol`).
  """

  use GenServer
  require Logger

  alias Aiur.{AgentPubSub, IssueLog}
  alias Aiur.Events.DebugLog
  alias Aiur.Opencode.{ActiveTurns, ApiClient, Db, EventRow, Protocol}

  # Sweep open turn buffers every 60s; finalize any whose last event
  # is older than this threshold. Bounds memory if codex never sends
  # turn_completed (crash, network drop, indefinite pause).
  @turn_sweep_interval_ms 60_000
  @turn_idle_finalize_ms 10 * 60 * 1000

  defstruct [
    :identifier,
    :session_id,
    :base_url,
    :root_msg_id,
    turns: %{},
    # Tracks event_ids we've already persisted as cross-ticket ticker
    # rows (R2 from the chat-pane follow-ups plan). SubscriptionStore's
    # at-least-once delivery may re-broadcast `:receive`; the agent's
    # queue may re-deliver `events_digest`. The MapSet caps memory and
    # keeps double-writes out of opencode SQL.
    seen_event_ids: MapSet.new()
  ]

  # Soft cap for `seen_event_ids` — matches the IssueLog history-pull
  # window. Older ids may evict; very-late re-deliveries beyond the cap
  # could double-write (acceptable failure mode given DebugLog's
  # in-process broadcast contract).
  @seen_event_ids_cap 500

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Map.fetch!(opts, :identifier)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Block until the writer has finished replaying on-disk history into
  opencode's SQLite. Returns `:ok` once the boot continuation has run.

  The barrier works because `replay_history/1` runs **synchronously**
  inside `handle_continue(:boot, ...)` and the GenServer mailbox is
  strictly FIFO — any `handle_call` arriving after the registry's
  `ensure/2` returns is queued behind the boot continuation.
  """
  @spec await_replay(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_replay(server, timeout \\ 5_000) do
    GenServer.call(server, :await_replay, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_writer}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    identifier = Map.fetch!(opts, :identifier)
    session_id = Map.fetch!(opts, :session_id)
    base_url = Map.fetch!(opts, :base_url)

    case Registry.register(
           Aiur.Opencode.SessionWriterRegistry.Registry,
           identifier,
           %{session_id: session_id, base_url: base_url}
         ) do
      {:ok, _} ->
        :ok = append_session_to_tempfile(session_id)

        state = %__MODULE__{
          identifier: identifier,
          session_id: session_id,
          base_url: base_url
        }

        {:ok, state, {:continue, :boot}}

      {:error, {:already_registered, _pid}} ->
        :ignore
    end
  end

  defp append_session_to_tempfile(session_id) do
    case System.get_env("AIUR_SESSION_TMPFILE") do
      path when is_binary(path) and path != "" ->
        _ = File.write(path, "#{session_id}\n", [:append])
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    # Replay BEFORE subscribing to AgentPubSub. The old order
    # (subscribe → replay) allowed a live transcript event to land in
    # the SessionWriter mailbox while replay was still processing the
    # same event from IssueLog.history, producing duplicate writes.
    # Replay first → any live event between init and subscribe is
    # captured by IssueLog (separate subscriber) and will replay on
    # the next attach.
    root_msg_id = replay_history(state)
    :ok = AgentPubSub.subscribe_agent(state.identifier)
    # Subscribe to the cross-ticket event debug stream so we can persist
    # 📥/📤/📄 ticker rows for this agent on every DebugLog mark whose
    # `identifier` matches ours. The filter happens in handle_info —
    # DebugLog's topic is process-global so we receive every agent's
    # marks and skip the ones that aren't ours.
    :ok = DebugLog.subscribe()

    schedule_turn_sweep()

    {:noreply, %{state | root_msg_id: root_msg_id}}
  end

  @impl true
  def handle_call(:await_replay, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:transcript_event, %{role: :user}}, state), do: {:noreply, state}

  def handle_info({:transcript_event, event}, state) do
    case write_transcript_event(state, event) do
      {:ok, _message_id, parts, new_state} ->
        _ = parts
        {:noreply, new_state}

      {:error, reason} ->
        log_session_write_failure("write_failed", state.identifier, reason)

        {:noreply, state}
    end
  end

  def handle_info({:turn_event, _identifier, event_tag, %{turn_id: turn_id}}, state)
      when is_binary(turn_id) do
    {new_state, _finalize_parts} = finalize_turn(state, turn_id, step_finish_reason(event_tag))

    {:noreply, new_state}
  end

  def handle_info({:alert, %{message: message}}, state) do
    # Alerts are still standalone messages — no turn grouping.
    case write_standalone(state, %{role: :alert, body: message}) do
      {:ok, _message_id, _parts} ->
        :ok

      {:error, reason} ->
        log_session_write_failure("alert_failed", state.identifier, reason)
    end

    {:noreply, state}
  end

  def handle_info(:sweep_open_turns, state) do
    schedule_turn_sweep()
    {:noreply, sweep_stale_turns(state)}
  end

  # Cross-ticket event ticker row (R2 of the chat-pane follow-ups plan).
  # DebugLog broadcasts on a global topic; filter via
  # `EventRow.matches?/2` (identifier match OR topic prefix match).
  # Dedup against re-deliveries by event_id.
  def handle_info({:event_debug, entry}, state) do
    if EventRow.matches?(entry, state.identifier) do
      handle_matching_event_debug(state, entry)
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- turn-event handling -------------------------------------------------

  defp step_finish_reason(:turn_completed), do: "stop"
  defp step_finish_reason(:turn_failed), do: "error"
  defp step_finish_reason(:turn_cancelled), do: "cancelled"
  # turn_input_required terminates the turn for chat purposes — agent is
  # awaiting operator input, render as a closed turn rather than leaving
  # it open.
  defp step_finish_reason(:turn_input_required), do: "stop"
  defp step_finish_reason(_), do: "stop"

  # Finalize a turn: append step-finish part if the turn is open. Returns
  # `{new_state, parts_written}` — caller fires PATCH events.
  defp finalize_turn(state, turn_id, reason) do
    case Map.fetch(state.turns, turn_id) do
      {:ok, %{message_id: message_id}} ->
        write_finish_then_drop(state, turn_id, message_id, reason)

      :error ->
        {state, []}
    end
  end

  defp write_finish_then_drop(state, turn_id, message_id, reason) do
    part_id = Db.prt_id()
    part_data = Protocol.step_finish_part_data(reason: reason)

    write_result =
      Db.with_conn(fn conn ->
        Db.insert_part(conn, state.session_id, message_id, part_id, part_data)
      end)

    state_after = %{state | turns: Map.delete(state.turns, turn_id)}

    case write_result do
      :ok ->
        {state_after, [{message_id, part_id, part_data}]}

      {:error, write_err} ->
        Logger.warning("opencode_session_writer step_finish_failed identifier=#{state.identifier} turn=#{turn_id} reason=#{inspect(write_err)}")

        {state_after, []}
    end
  end

  defp schedule_turn_sweep do
    Process.send_after(self(), :sweep_open_turns, @turn_sweep_interval_ms)
  end

  defp sweep_stale_turns(state) do
    cutoff = System.os_time(:millisecond) - @turn_idle_finalize_ms

    Enum.reduce(state.turns, state, fn {turn_id, %{last_event_at_ms: last}}, acc ->
      if last < cutoff do
        Logger.info("opencode_session_writer sweep_finalize identifier=#{acc.identifier} turn=#{turn_id} idle_ms=#{System.os_time(:millisecond) - last}")

        {new_state, _parts} = finalize_turn(acc, turn_id, "stop")
        new_state
      else
        acc
      end
    end)
  end

  # --- history replay ------------------------------------------------------

  defp replay_history(state) do
    events =
      case IssueLog.history(state.identifier, 500) do
        [] -> IssueLog.disk_history(state.identifier, 500)
        list -> list
      end

    root_msg_id = Db.msg_id()
    user_root_data = Protocol.user_message_data(state.identifier)

    # All replay inserts share one BEGIN IMMEDIATE → COMMIT transaction
    # so the SQLite write lock is acquired ONCE per writer instead of
    # once per row.
    replayed =
      Db.with_transaction(fn conn ->
        _ = Db.insert_message(conn, state.session_id, root_msg_id, user_root_data)
        replay_events(conn, state_with_root(state, root_msg_id), events)
      end)

    replayed = if is_integer(replayed), do: replayed, else: 0

    Logger.info("opencode_session_writer phase=ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{state.identifier} session_id=#{state.session_id} replayed=#{replayed}")

    catch_up_active_turn_markers(state)

    root_msg_id
  end

  # On `--debug` resume, SessionWriter replay can take ~6s while the codex
  # turn fires its `__aiur_turn__:<id>` markers at t=0 — those markers find
  # zero writers in `SessionWriterRegistry.attached/1` and silently no-op,
  # so the bridge never opens the live SSE stream and the chat pane gets no
  # deltas for the rest of the run (transcript content arrives via SQL
  # replay only). Once this writer reaches `phase=ready`, check ActiveTurns
  # for any in-flight aiur turn on its identifier and fire the marker
  # against its own session so the bridge sees the chat-completion request.
  # Fire-and-forget Task.start — same pattern as AgentRunner.post_aiur_turn_markers/4.
  defp catch_up_active_turn_markers(state) do
    for aiur_turn_id <- ActiveTurns.active_turn_ids(state.identifier) do
      Task.start(fn -> post_catchup_marker(state, aiur_turn_id) end)
    end

    :ok
  end

  defp post_catchup_marker(state, aiur_turn_id) do
    payload = %{
      parts: [Protocol.text_part_data("__aiur_turn__:" <> aiur_turn_id, synthetic: true)]
    }

    case ApiClient.post_message(state.base_url, state.session_id, payload) do
      {:ok, _} ->
        Logger.debug("session_writer_marker_catchup_posted identifier=#{state.identifier} aiur_turn=#{aiur_turn_id} base_url=#{state.base_url}")

      {:error, reason} ->
        Logger.debug("session_writer_marker_catchup_failed identifier=#{state.identifier} aiur_turn=#{aiur_turn_id} reason=#{inspect(reason)}")
    end
  end

  defp state_with_root(state, root_msg_id), do: %{state | root_msg_id: root_msg_id}

  # Replay path: write each event as a standalone message, ignoring
  # turn_id grouping. Replay is historical — turn-boundary signals are
  # not on disk. The chat shows historical turns flatter than live; live
  # rendering benefits from turn grouping, replay falls back gracefully.
  # No PATCH calls during replay — TUI fetches state on attach via GET.
  defp replay_events(conn, state, events) do
    events
    |> Enum.reject(&match?(%{role: :user}, &1))
    |> Enum.reduce(0, fn event, count ->
      case write_standalone_in_txn(conn, state, event) do
        {:ok, _msg_id, _parts} -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  # --- live transcript write ----------------------------------------------

  # Dispatch based on whether the event has a turn_id. Returns
  # `{:ok, message_id, parts_written, new_state}` or `{:error, reason}`.
  # parts_written is a list of `{message_id, part_id, part_data}` for the
  # caller to feed into fire_part_updates/2.
  defp write_transcript_event(state, %{turn_id: tid} = event) when is_binary(tid) do
    case Map.fetch(state.turns, tid) do
      {:ok, turn} -> append_to_open_turn(state, turn, tid, event)
      :error -> open_turn(state, event)
    end
  end

  defp write_transcript_event(state, event) do
    case write_standalone(state, event) do
      {:ok, message_id, parts} -> {:ok, message_id, parts, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_to_open_turn(state, %{message_id: message_id} = turn, tid, event) do
    parts = build_body_parts(event.role, event.body, event)

    write_result =
      Db.with_conn(fn conn ->
        insert_part_list(conn, state.session_id, message_id, parts)
      end)

    case write_result do
      :ok ->
        new_turn = %{turn | last_event_at_ms: System.os_time(:millisecond)}

        {:ok, message_id, tag_parts(message_id, parts), %{state | turns: Map.put(state.turns, tid, new_turn)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Open a new turn-grouped assistant message: insert the message row,
  # the step-start part, and the first body parts in a single transaction.
  # Record the open turn in state.turns.
  defp open_turn(state, %{turn_id: tid, role: role, body: body} = event) do
    message_id = Db.msg_id()
    now_ms = System.os_time(:millisecond)
    step_start_id = Db.prt_id()
    body_parts = build_body_parts(role, body, event)
    all_parts = [{step_start_id, Protocol.step_start_part_data()} | body_parts]

    write_result =
      Db.with_transaction(fn conn ->
        with :ok <-
               Db.insert_message(
                 conn,
                 state.session_id,
                 message_id,
                 build_message_data(state, role)
               ) do
          insert_part_list(conn, state.session_id, message_id, all_parts)
        end
      end)

    case write_result do
      :ok ->
        turn = %{message_id: message_id, started_at_ms: now_ms, last_event_at_ms: now_ms}

        {:ok, message_id, tag_parts(message_id, all_parts), %{state | turns: Map.put(state.turns, tid, turn)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Standalone message: message + step-start + body + step-finish in one
  # transaction. Used for turn_id=nil events and alerts.
  defp write_standalone(state, event) do
    Db.with_conn(fn conn -> write_standalone_in_txn(conn, state, event) end)
  end

  defp write_standalone_in_txn(conn, state, %{role: role, body: body} = event)
       when role in [:assistant, :command, :system, :alert, :reasoning, :tool] do
    message_id = Db.msg_id()
    finish = if role in [:command, :tool], do: "tool-calls", else: "stop"

    step_start_id = Db.prt_id()
    body_parts = build_body_parts(role, body, event)
    step_finish_id = Db.prt_id()

    all_parts =
      [{step_start_id, Protocol.step_start_part_data()}] ++
        body_parts ++
        [{step_finish_id, Protocol.step_finish_part_data(reason: finish)}]

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             build_message_data(state, role)
           ),
         :ok <- insert_part_list(conn, state.session_id, message_id, all_parts) do
      {:ok, message_id, tag_parts(message_id, all_parts)}
    end
  end

  defp write_standalone_in_txn(_conn, _state, _event), do: {:error, :unsupported_role}

  # System-role standalone message — used for cross-ticket event ticker
  # rows (R2 of the chat-pane follow-ups plan). Bypasses
  # `assistant_message_data`'s `mode: build` / `agent: build` fields so
  # opencode-attach renders the row without the `▣ Build · issue-N`
  # chrome that wraps codex turn messages.
  defp write_system_standalone(state, body) when is_binary(body) do
    Db.with_conn(fn conn -> write_system_standalone_in_txn(conn, state, body) end)
  end

  defp write_system_standalone_in_txn(conn, state, body) do
    message_id = Db.msg_id()
    step_start_id = Db.prt_id()
    text_part_id = Db.prt_id()
    step_finish_id = Db.prt_id()

    all_parts = [
      {step_start_id, Protocol.step_start_part_data()},
      {text_part_id, Protocol.text_part_data(body)},
      {step_finish_id, Protocol.step_finish_part_data(reason: "stop")}
    ]

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             Protocol.system_message_data(%{
               identifier: state.identifier,
               parent_id: state.root_msg_id || Db.msg_id()
             })
           ),
         :ok <- insert_part_list(conn, state.session_id, message_id, all_parts) do
      {:ok, message_id}
    end
  end

  # --- event-row helpers (R2 from chat-pane follow-ups plan) ---------------

  defp handle_matching_event_debug(state, entry) do
    id = Map.get(entry, :id)

    cond do
      is_nil(id) ->
        # No event id → no dedup possible. Render anyway; the in-memory
        # MapSet only protects against re-deliveries, not first writes.
        write_event_row(state, entry)

      MapSet.member?(state.seen_event_ids, id) ->
        {:noreply, state}

      true ->
        case write_event_row(state, entry) do
          {:noreply, new_state} -> {:noreply, remember_event_id(new_state, id)}
        end
    end
  end

  defp write_event_row(state, entry) do
    case EventRow.from(entry, state.identifier) do
      nil ->
        {:noreply, state}

      body ->
        case write_system_standalone(state, body) do
          {:ok, _message_id} ->
            {:noreply, state}

          {:error, reason} ->
            log_session_write_failure(
              "event_row_failed",
              state.identifier,
              reason,
              kind: inspect(entry[:kind])
            )

            {:noreply, state}
        end
    end
  end

  # FOREIGN KEY violations land here when opencode's SQL session row has
  # been deleted out from under us — usually because Aiur.Shutdown is
  # tearing down sessions while events are still in flight, or because
  # the slot respawned and the writer hasn't been notified yet. Neither
  # is a real failure; demote those to debug so the warning-level
  # surface stays signal-only. Other write failures still warn.
  defp log_session_write_failure(tag, identifier, reason, extra \\ []) do
    extras = extra |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
    msg = "opencode_session_writer #{tag} identifier=#{identifier} #{extras} reason=#{inspect(reason)}"

    if foreign_key_violation?(reason) do
      Logger.debug(msg)
    else
      Logger.warning(msg)
    end
  end

  defp foreign_key_violation?(%Exqlite.Error{message: msg}) when is_binary(msg),
    do: String.contains?(msg, "FOREIGN KEY")

  defp foreign_key_violation?(_), do: false

  defp remember_event_id(state, id) do
    seen = MapSet.put(state.seen_event_ids, id)

    seen =
      if MapSet.size(seen) > @seen_event_ids_cap do
        # Cap exceeded — drop a single arbitrary element. MapSet eviction
        # isn't strictly ordered but the cap exists only to bound memory;
        # very-late re-deliveries beyond the cap could double-write
        # (acceptable per the plan's risk table).
        {dropped, smaller} = pop_any(seen)
        _ = dropped
        smaller
      else
        seen
      end

    %{state | seen_event_ids: seen}
  end

  defp pop_any(set) do
    [first | _] = MapSet.to_list(set)
    {first, MapSet.delete(set, first)}
  end

  # --- part-data builders --------------------------------------------------

  # Returns a list of `{part_id, part_data}` for the event's body. The
  # caller inserts these and (in the live path) fires PATCH events on
  # them.
  defp build_body_parts(:command, body, event) do
    payload = event[:payload] || %{}
    command = Map.get(payload, :command, body)
    output = Map.get(payload, :output, "")
    title = Map.get(payload, :title, body)
    workdir = Map.get(payload, :workdir, "")

    input = %{"command" => command}
    input = if workdir != "", do: Map.put(input, "workdir", workdir), else: input

    part_data =
      Protocol.tool_part_data(
        tool: "bash",
        call_id: Db.call_id(),
        input: input,
        output: output,
        title: title
      )

    [{Db.prt_id(), part_data}]
  end

  defp build_body_parts(:tool, body, event) do
    payload = event[:payload] || %{}
    tool = Map.get(payload, :tool, "tool")
    input = Map.get(payload, :input, %{})
    output = Map.get(payload, :output, "")
    title = Map.get(payload, :title, body)

    part_data =
      Protocol.tool_part_data(
        tool: tool,
        call_id: Db.call_id(),
        input: input,
        output: output,
        title: title
      )

    [{Db.prt_id(), part_data}]
  end

  defp build_body_parts(:reasoning, body, _event) when is_binary(body) and body != "" do
    [{Db.prt_id(), Protocol.reasoning_part_data(body)}]
  end

  defp build_body_parts(_role, body, _event) when is_binary(body) do
    [{Db.prt_id(), Protocol.text_part_data(body)}]
  end

  defp build_body_parts(_role, _body, _event), do: []

  defp insert_part_list(conn, session_id, message_id, parts) do
    Enum.reduce_while(parts, :ok, fn {part_id, part_data}, _acc ->
      case Db.insert_part(conn, session_id, message_id, part_id, part_data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tag_parts(message_id, parts) do
    Enum.map(parts, fn {part_id, part_data} -> {message_id, part_id, part_data} end)
  end

  defp build_message_data(state, role) do
    cwd =
      Aiur.Config.workspace_root()
      |> Path.expand()
      |> Path.join(Aiur.Opencode.Config.safe_identifier(state.identifier))

    # For turn-grouped messages, opencode renders `finish` from the
    # step-finish part. Set a sensible default on the message row so
    # any reader that consults message JSON alone sees a useful value.
    finish = if role in [:command, :tool], do: "tool-calls", else: "stop"

    Protocol.assistant_message_data(%{
      identifier: state.identifier,
      parent_id: state.root_msg_id || Db.msg_id(),
      cwd: cwd,
      finish: finish
    })
  end

  # Live TUI updates flow through `Aiur.Opencode.ChatCompletions`'s
  # bridge-as-LLM stream now (the `__aiur_turn__:<id>` marker posted by
  # AgentRunner at turn start opens an SSE that the bridge holds and
  # streams transcript events to). SessionWriter no longer needs to
  # poke opencode per-part — its only job is persisting message + part
  # rows so re-attach renders the full history via GET /messages.
end
