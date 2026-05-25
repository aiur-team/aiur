defmodule Aiur.Opencode.SessionWriter do
  @moduledoc """
  Per-identifier writer that owns the SQLite-injection lifecycle for one
  agent's opencode session. On start it replays the on-disk transcript
  history into opencode's `message`/`part` tables; for every subsequent
  transcript event it writes the assistant rows and POSTs a synthetic
  user message carrying the `__aiur_stream__:<msg_id>` marker so opencode
  triggers a chat-completion the bridge can stream back as the
  assistant's reply.

  Transcript events carrying a `turn_id` are grouped into a single
  assistant message per codex turn — first event opens the message with
  a `step-start` part, subsequent events append body parts to the same
  message, and the matching `:turn_event` from `AgentPubSub.broadcast_turn_event/3`
  appends a `step-finish` and closes the turn. Events with `turn_id: nil`
  keep the standalone-message shape (step-start + body + step-finish in
  one transaction).

  Started via `Aiur.Opencode.SessionWriterRegistry.ensure/2`; supervised
  by `Aiur.Opencode.SessionSupervisor` with `restart: :transient` so a
  crashed writer doesn't restart-loop on the same bad input.

  See `elixir/docs/notes/opencode-row-shapes-1.15.6.md` for the row JSON
  shapes this writes — kept in `Aiur.Opencode.Protocol`, not here.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentPubSub, IssueLog}
  alias Aiur.Opencode.{ApiClient, Db, Protocol}

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
    turns: %{}
  ]

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
  `ensure/2` returns is queued behind the boot continuation. If
  `replay_history/1` is ever made async (Tasks, `send(self(), …)`,
  etc.), this barrier must be revisited.
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
    # Replay BEFORE subscribing to AgentPubSub. The previous order
    # (subscribe → replay) allowed a live transcript event to land in
    # the SessionWriter mailbox while replay was still processing the
    # same event from IssueLog.history, producing duplicate writes
    # ("Starting work on issue #N" appearing twice). Replaying first
    # closes the race window: any live event between init and subscribe
    # is captured by IssueLog (which subscribes separately and persists
    # to disk) and will replay on the next attach.
    root_msg_id = replay_history(state)
    :ok = AgentPubSub.subscribe_agent(state.identifier)

    schedule_turn_sweep()

    {:noreply, %{state | root_msg_id: root_msg_id}}
  end

  @impl true
  def handle_call(:await_replay, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:transcript_event, %{role: :user}}, state), do: {:noreply, state}

  def handle_info({:transcript_event, event}, state) do
    case write_transcript_event(state, event) do
      {:ok, message_id, new_state} ->
        nudge_tui(state, message_id)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("opencode_session_writer write_failed identifier=#{state.identifier} reason=#{inspect(reason)}")

        {:noreply, state}
    end
  end

  def handle_info({:turn_event, _identifier, event_tag, %{turn_id: turn_id}}, state)
      when is_binary(turn_id) do
    {new_state, nudge_id} = finalize_turn(state, turn_id, step_finish_reason(event_tag))

    if nudge_id, do: nudge_tui(state, nudge_id)

    {:noreply, new_state}
  end

  def handle_info({:alert, %{message: message}}, state) do
    # Alerts are still standalone messages — no turn grouping.
    case write_standalone(state, %{role: :alert, body: message}) do
      {:ok, message_id} ->
        nudge_tui(state, message_id)
        :ok

      {:error, reason} ->
        Logger.warning("opencode_session_writer alert_failed identifier=#{state.identifier} reason=#{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:sweep_open_turns, state) do
    schedule_turn_sweep()
    {:noreply, sweep_stale_turns(state)}
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
  # `{new_state, message_id_to_nudge_or_nil}`. A turn_id we never saw
  # (event arrived twice, or for a different writer) returns `{state, nil}`.
  defp finalize_turn(state, turn_id, reason) do
    case Map.fetch(state.turns, turn_id) do
      {:ok, %{message_id: message_id}} ->
        write_finish_then_drop(state, turn_id, message_id, reason)

      :error ->
        {state, nil}
    end
  end

  defp write_finish_then_drop(state, turn_id, message_id, reason) do
    write_result =
      Db.with_conn(fn conn ->
        Db.insert_part(
          conn,
          state.session_id,
          message_id,
          Db.prt_id(),
          Protocol.step_finish_part_data(reason: reason)
        )
      end)

    state_after = %{state | turns: Map.delete(state.turns, turn_id)}

    case write_result do
      :ok ->
        {state_after, message_id}

      {:error, write_err} ->
        Logger.warning("opencode_session_writer step_finish_failed identifier=#{state.identifier} turn=#{turn_id} reason=#{inspect(write_err)}")

        {state_after, nil}
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

        {new_state, _} = finalize_turn(acc, turn_id, "stop")
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

    root_msg_id
  end

  defp state_with_root(state, root_msg_id), do: %{state | root_msg_id: root_msg_id}

  # Replay path: write each event as a standalone message, ignoring
  # turn_id grouping. Replay is bounded historical data — at the time of
  # write the turn boundaries from the live broadcast already played out;
  # there's no reliable way to reconstruct turn-end signals from disk.
  # The shape difference is acceptable: chat replay shows historical
  # turns as flatter messages, the live experience shows them grouped.
  defp replay_events(conn, state, events) do
    events
    |> Enum.reject(&match?(%{role: :user}, &1))
    |> Enum.reduce(0, fn event, count ->
      case write_standalone(conn, state, event) do
        {:ok, _msg_id} -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  # --- live transcript write ----------------------------------------------

  # Dispatch based on whether the event has a turn_id. Returns
  # `{:ok, message_id_to_nudge, new_state}` or `{:error, reason}`.
  defp write_transcript_event(state, %{turn_id: tid} = event) when is_binary(tid) do
    case Map.fetch(state.turns, tid) do
      {:ok, turn} -> append_to_open_turn(state, turn, tid, event)
      :error -> open_turn(state, event)
    end
  end

  defp write_transcript_event(state, event) do
    case write_standalone(state, event) do
      {:ok, message_id} -> {:ok, message_id, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_to_open_turn(state, %{message_id: message_id} = turn, tid, event) do
    write_result =
      Db.with_conn(fn conn ->
        insert_body_parts(conn, state, message_id, event.role, event.body, event)
      end)

    case write_result do
      :ok ->
        new_turn = %{turn | last_event_at_ms: System.os_time(:millisecond)}
        {:ok, message_id, %{state | turns: Map.put(state.turns, tid, new_turn)}}

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

    Db.with_transaction(fn conn ->
      with :ok <-
             Db.insert_message(
               conn,
               state.session_id,
               message_id,
               build_message_data(state, role)
             ),
           :ok <-
             Db.insert_part(
               conn,
               state.session_id,
               message_id,
               Db.prt_id(),
               Protocol.step_start_part_data()
             ) do
        insert_body_parts(conn, state, message_id, role, body, event)
      end
    end)
    |> case do
      :ok ->
        turn = %{message_id: message_id, started_at_ms: now_ms, last_event_at_ms: now_ms}
        {:ok, message_id, %{state | turns: Map.put(state.turns, tid, turn)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Standalone message: message + step-start + body + step-finish in one
  # transaction. Used for turn_id=nil events, alerts, and replay.
  defp write_standalone(state, event), do: Db.with_conn(&write_standalone(&1, state, event))

  defp write_standalone(conn, state, %{role: role, body: body} = event)
       when role in [:assistant, :command, :system, :alert] do
    message_id = Db.msg_id()
    finish = if role == :command, do: "tool-calls", else: "stop"

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             build_message_data(state, role)
           ),
         :ok <-
           Db.insert_part(
             conn,
             state.session_id,
             message_id,
             Db.prt_id(),
             Protocol.step_start_part_data()
           ),
         :ok <- insert_body_parts(conn, state, message_id, role, body, event),
         :ok <-
           Db.insert_part(
             conn,
             state.session_id,
             message_id,
             Db.prt_id(),
             Protocol.step_finish_part_data(reason: finish)
           ) do
      {:ok, message_id}
    end
  end

  defp write_standalone(_conn, _state, _event), do: {:error, :unsupported_role}

  defp build_message_data(state, role) do
    cwd =
      Aiur.Config.workspace_root()
      |> Path.expand()
      |> Path.join(Aiur.Opencode.Config.safe_identifier(state.identifier))

    # For turn-grouped messages the `finish` field is overwritten by the
    # final step-finish part's reason via opencode's TUI rendering rules;
    # we still set it on the message row so any reader that consults the
    # message JSON alone sees a sensible value. "tool-calls" is a safe
    # default for in-flight turns since step-start signals more parts
    # are coming.
    finish = if role == :command, do: "tool-calls", else: "stop"

    Protocol.assistant_message_data(%{
      identifier: state.identifier,
      parent_id: state.root_msg_id || Db.msg_id(),
      cwd: cwd,
      finish: finish
    })
  end

  defp insert_body_parts(conn, state, message_id, :command, body, _event) do
    part_data =
      Protocol.tool_part_data(
        tool: "bash",
        call_id: Db.call_id(),
        input: %{"command" => body},
        output: "",
        title: body
      )

    Db.insert_part(conn, state.session_id, message_id, Db.prt_id(), part_data)
  end

  defp insert_body_parts(conn, state, message_id, _role, body, _event) when is_binary(body) do
    Db.insert_part(conn, state.session_id, message_id, Db.prt_id(), Protocol.text_part_data(body))
  end

  defp insert_body_parts(_conn, _state, _message_id, _role, _body, _event), do: :ok

  # --- nudge opencode to render the just-written rows ----------------------

  defp nudge_tui(state, message_id) do
    marker = "__aiur_stream__:" <> message_id
    payload = %{parts: [Protocol.text_part_data(marker, synthetic: true)]}

    case ApiClient.post_message(state.base_url, state.session_id, payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("opencode_session_writer nudge_failed identifier=#{state.identifier} reason=#{inspect(reason)}")
    end
  end
end
