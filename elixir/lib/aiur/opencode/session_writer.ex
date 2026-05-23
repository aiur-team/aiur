defmodule Aiur.Opencode.SessionWriter do
  @moduledoc """
  Per-identifier writer that owns the SQLite-injection lifecycle for one
  agent's opencode session. On start it replays the on-disk transcript
  history into opencode's `message`/`part` tables; for every subsequent
  transcript event it writes the assistant rows and POSTs a synthetic
  user message carrying the `__aiur_stream__:<msg_id>` marker so opencode
  triggers a chat-completion the bridge can stream back as the
  assistant's reply.

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

  @flush_after_ms 150

  defstruct [:identifier, :session_id, :base_url, :root_msg_id, pending_events: [], flush_ref: nil]

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

    # Registry value is the bare session id. The slot model owns
    # `pane_id` on the Slot worker, not on the writer — SessionWriter
    # only needs to know which opencode session it's mirroring to.
    case Registry.register(
           Aiur.Opencode.SessionWriterRegistry.Registry,
           identifier,
           session_id
         ) do
      {:ok, _} ->
        :ok = append_session_to_tempfile(session_id)

        state = %__MODULE__{
          identifier: identifier,
          session_id: session_id,
          base_url: Map.fetch!(opts, :base_url)
        }

        {:ok, state, {:continue, :boot}}

      {:error, {:already_registered, _pid}} ->
        :ignore
    end
  end

  # Append the new opencode session id to `$AIUR_SESSION_TMPFILE` so the
  # bash trap in `scripts/aiur` can reap it if Aiur exits abruptly (parent
  # terminal close, BEAM panic) — the layer-2 cleanup. Layer 1 is
  # `Aiur.Shutdown.cleanup/1` (graceful exit), layer 3 is `WarmServer`'s
  # boot-time GC (SIGKILL recovery).
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
    :ok = AgentPubSub.subscribe_agent(state.identifier)
    root_msg_id = replay_history(state)
    {:noreply, %{state | root_msg_id: root_msg_id}}
  end

  @impl true
  def handle_call(:await_replay, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:transcript_event, %{role: :user}}, state), do: {:noreply, state}

  def handle_info({:transcript_event, event}, state) do
    {:noreply, buffer_event(state, event)}
  end

  def handle_info({:alert, %{message: message}}, state) do
    {:noreply, buffer_event(state, %{role: :alert, body: message})}
  end

  def handle_info({:flush_pending, ref}, %{flush_ref: ref} = state) do
    {:noreply, flush_pending(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = flush_pending(state)
    :ok
  end

  # --- history replay ------------------------------------------------------

  defp replay_history(state) do
    events =
      case IssueLog.history(state.identifier, 500) do
        [] -> IssueLog.disk_history(state.identifier, 500)
        list -> list
      end

    # Each replayed assistant message needs a `parentID` that matches `^msg`.
    # We insert one synthetic user-role root message at the head and chain
    # every assistant message to it.
    root_msg_id = Db.msg_id()
    user_root_data = Protocol.user_message_data(state.identifier)

    # All replay inserts share one BEGIN IMMEDIATE → COMMIT transaction
    # so the SQLite write lock is acquired ONCE per writer instead of
    # once per row. Without this, N concurrent SessionWriters each doing
    # ~100 inserts produce N×100 contended lock acquisitions; the per-
    # row 5 s busy_timeout eventually blows past the 10 s await_replay
    # cap on the slow writers (observed wedging 4 of 5 agents on
    # 2026-05-22).
    replayed =
      Db.with_transaction(fn conn ->
        _ = Db.insert_message(conn, state.session_id, root_msg_id, user_root_data)
        replay_events(conn, state_with_root(state, root_msg_id), events)
      end)

    replayed = if is_integer(replayed), do: replayed, else: 0

    Logger.info("opencode_session_writer phase=ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{state.identifier} session_id=#{state.session_id} replayed=#{replayed}")

    root_msg_id
  end

  defp state_with_root(state, root_msg_id),
    do: %{state | root_msg_id: root_msg_id}

  defp replay_events(conn, state, events) do
    events
    |> Enum.reject(&match?(%{role: :user}, &1))
    |> Enum.reduce(0, fn event, count ->
      case write_event(conn, state, event) do
        {:ok, _msg_id} -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  # --- live event buffering -------------------------------------------------

  defp buffer_event(state, event) do
    state
    |> Map.update!(:pending_events, &[event | &1])
    |> schedule_flush()
  end

  defp schedule_flush(%{flush_ref: nil} = state) do
    ref = make_ref()
    _timer = Process.send_after(self(), {:flush_pending, ref}, @flush_after_ms)
    %{state | flush_ref: ref}
  end

  defp schedule_flush(state), do: state

  defp flush_pending(%{pending_events: []} = state), do: %{state | flush_ref: nil}

  defp flush_pending(state) do
    events = Enum.reverse(state.pending_events)
    state = %{state | pending_events: [], flush_ref: nil}

    case write_events(state, events) do
      {:ok, message_id} ->
        nudge_tui(state, message_id)
        :ok

      {:error, reason} ->
        Logger.warning("opencode_session_writer flush_failed identifier=#{state.identifier} reason=#{inspect(reason)}")
    end

    state
  end

  # --- write assistant messages + parts ------------------------------------

  # Live-write path used by handle_info — opens its own connection.
  defp write_events(state, events), do: Db.with_transaction(&write_events(&1, state, events))

  defp write_event(conn, state, %{role: role} = event)
       when role in [:assistant, :command, :system, :alert] do
    write_events(conn, state, [event])
  end

  defp write_event(_conn, _state, _event), do: {:error, :unsupported_role}

  defp write_events(conn, state, events) when is_list(events) do
    events = Enum.filter(events, &supported_event?/1)

    if events == [] do
      {:error, :unsupported_role}
    else
      insert_event_batch(conn, state, events)
    end
  end

  defp insert_event_batch(conn, state, events) do
    message_id = Db.msg_id()
    parent_id = state.root_msg_id || message_id

    cwd =
      Aiur.Config.workspace_root()
      |> Path.expand()
      |> Path.join(Aiur.Opencode.Config.safe_identifier(state.identifier))

    finish = if Enum.any?(events, &(&1.role == :command)), do: "tool-calls", else: "stop"

    message_data =
      Protocol.assistant_message_data(%{
        identifier: state.identifier,
        parent_id: parent_id,
        cwd: cwd,
        finish: finish
      })

    with :ok <- Db.insert_message(conn, state.session_id, message_id, message_data),
         :ok <-
           Db.insert_part(
             conn,
             state.session_id,
             message_id,
             Db.prt_id(),
             Protocol.step_start_part_data()
           ),
         :ok <- insert_batch_body_parts(conn, state, message_id, events),
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

  defp supported_event?(%{role: role}) when role in [:assistant, :command, :system, :alert], do: true
  defp supported_event?(_event), do: false

  defp insert_batch_body_parts(conn, state, message_id, events) do
    events
    |> Enum.reduce_while({:ok, []}, &insert_batch_event_part(&1, &2, conn, state, message_id))
    |> case do
      {:ok, text_buffer} -> flush_text_part(conn, state, message_id, text_buffer)
      error -> error
    end
  end

  defp insert_batch_event_part(%{role: :command} = event, {:ok, text_buffer}, conn, state, message_id) do
    with :ok <- flush_text_part(conn, state, message_id, text_buffer),
         :ok <- insert_command_part(conn, state, message_id, event[:body]) do
      {:cont, {:ok, []}}
    else
      error -> {:halt, error}
    end
  end

  defp insert_batch_event_part(%{role: role, body: body}, {:ok, text_buffer}, _conn, _state, _message_id)
       when role in [:assistant, :system, :alert] and is_binary(body) do
    {:cont, {:ok, [body | text_buffer]}}
  end

  defp insert_batch_event_part(_event, {:ok, text_buffer}, _conn, _state, _message_id) do
    {:cont, {:ok, text_buffer}}
  end

  defp flush_text_part(_conn, _state, _message_id, []), do: :ok

  defp flush_text_part(conn, state, message_id, text_buffer) do
    text_buffer
    |> Enum.reverse()
    |> Enum.join("")
    |> then(&Db.insert_part(conn, state.session_id, message_id, Db.prt_id(), Protocol.text_part_data(&1)))
  end

  defp insert_command_part(conn, state, message_id, body) do
    # Command transcript event from codex — capture as a single completed
    # tool call. We don't have separate stdout/exit; the body field carries
    # the raw command line (e.g., "$ ls").
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

  # --- nudge opencode to render the just-written rows ----------------------
  #
  # `POST /tui/publish` does NOT accept `EventMessagePartDelta` (verified
  # against opencode 1.15.6 — only `EventTui*` variants are publishable).
  # Direct SQLite writes don't fire opencode's `/event` SSE either, so the
  # attached TUI won't refresh on its own. To trigger a render we POST a
  # synthetic user message with the marker text; opencode reads it as a
  # user turn and calls `/v1/chat/completions` against our bridge, which
  # `ChatCompletions.replay_message_as_stream/3` then streams back as the
  # assistant reply using the just-written rows.

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
