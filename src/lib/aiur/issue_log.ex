defmodule Aiur.IssueLog do
  @moduledoc """
  Per-issue file writer that captures the same transcript + alert stream
  the opencode pane shows. One GenServer per active issue; it
  subscribes to the agent's PubSub topic on startup and appends every
  event to a repository-qualified file below `<logs-root>/log`.

  Multiple agent sessions on the same issue reuse the running writer —
  `attach/1` is idempotent. The writer stays alive until the BEAM exits;
  there's no automatic detach when the issue completes (the file is
  capped by disk, not by a watchdog), and the closed-then-reopened case
  is handled by the underlying `File.open([:append])`.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, TicketObservation, TrackerIdentity}
  alias Aiur.IssueLog.{Encoding, EventHistory, Paths}

  import Aiur.IssueLog.Files
  import Aiur.IssueLog.Format
  import Aiur.IssueLog.Writers

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    identifier = Keyword.fetch!(opts, :identifier)

    %{
      id: Keyword.get(opts, :writer_key, writer_key(identifier)),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # Cap on how many recent events we keep in memory for `history/2`.
  @history_limit 100
  # The API permits a page of up to 50 records. Read enough for that many
  # capped records, while retaining a fixed ceiling independent of log size.
  # How long a writer waits before trying its subscription again while
  # `Aiur.PubSub` is restarting. Short enough that the gap costs at most a
  # couple of transcript rows, long enough not to spin.
  @resubscribe_delay_ms 100

  @doc """
  Ensure a writer is running for `identifier`. Returns `:ok` on success;
  writers are scoped by the configured repository and ticket identifier.
  """
  @spec attach(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: :ok
  def attach(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) do
      attach_writer(
        identity.identifier,
        log_path(identity),
        event_log_path(identity),
        transcript_path(identity),
        writer_key(identity)
      )
    else
      :ok
    end
  end

  def attach(identifier) when is_binary(identifier) do
    attach_writer(identifier, log_path(identifier), event_log_path(identifier), transcript_path(identifier), writer_key(identifier))
  end

  @doc """
  Return up to `limit` recent transcript/alert events captured for this
  issue, oldest first. Returns `[]` if no writer is running yet for the
  given identifier — callers should still treat that as "no history
  available" rather than as an error.
  """
  @spec history(AgentEvents.agent_identifier(), pos_integer()) :: [map()]
  def history(identifier, limit \\ @history_limit) when is_binary(identifier) do
    case writer_for_path(identifier, log_path(identifier), writer_key(identifier)) do
      [{pid, _}] -> GenServer.call(pid, {:history, limit}, 1_000)
      [] -> []
    end
  catch
    :exit, _ -> []
  end

  @doc """
  Reads the on-disk log file for `identifier` and returns the last `limit`
  parsed events. Unlike `history/2`, this reaches back beyond the in-memory
  ring — useful when the BEAM restarted while the underlying agent kept
  running, so prior conversation can be replayed into a fresh opencode pane.
  """
  @spec disk_history(AgentEvents.agent_identifier(), pos_integer()) :: [map()]
  def disk_history(identifier, limit \\ @history_limit) when is_binary(identifier) do
    path = log_path(identifier)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&EventHistory.parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-limit)

      _ ->
        []
    end
  end

  @doc """
  Reads a bounded, newest-first page from the durable JSONL transcript.

  `:before` is the exclusive byte offset returned as `:next_cursor` by the
  previous call. It is intentionally a file offset rather than an event id:
  transcript producers do not share an event-id sequence. The read is capped
  at the requested page's number of maximum-size records (and never more than
  #{EventHistory.max_tail_bytes()} bytes), so a busy or historic transcript cannot turn a
  Stream Deck refresh into a full-log scan.
  """
  @spec read_tail(AgentEvents.agent_identifier() | TrackerIdentity.t(), keyword()) ::
          {:ok, %{events: [map()], next_cursor: String.t() | nil}} | {:error, atom()}
  def read_tail(identifier, opts \\ []) do
    limit = Keyword.get(opts, :limit, 7)
    before = Keyword.get(opts, :before)

    with true <- is_integer(limit) and limit > 0,
         {:ok, cursor} <- EventHistory.parse_tail_cursor(before),
         {:ok, %{size: size}} <- File.stat(transcript_path(identifier)) do
      end_offset = min(cursor || size, size)
      start_offset = max(end_offset - EventHistory.tail_chunk_bytes(limit), 0)

      with {:ok, bytes} <- EventHistory.read_tail_chunk(transcript_path(identifier), start_offset, end_offset - start_offset) do
        {:ok, EventHistory.tail_page(bytes, start_offset, limit)}
      end
    else
      false -> {:error, :invalid_limit}
      {:error, :enoent} -> {:ok, %{events: [], next_cursor: nil}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Parse `[event:emit]` / `[event:emit_alert]` / `[event:self]` / `[event:consumed]`
  lines from the per-issue log. A legacy display identifier returns the parsed
  list for bootstrap compatibility. A joinable `TrackerIdentity` returns a
  typed `{:ok, events}` / `{:error, reason}` result and resolves the exact
  owner/repository path. Events with `id > last_seen_event_id` represent
  activity the agent missed while inactive.

  Options:
    * `:since_id` — only return events with `id > since_id` (default 0)
    * `:kinds` — list of kinds to include (default `[:emit, :emit_alert]`)
    * `:limit` — max number of returned events (default `@history_limit`)
  """
  @type event_history_error :: :missing_source | :invalid_identity | {:unavailable, term()}

  @spec event_history(AgentEvents.agent_identifier() | TrackerIdentity.t(), keyword()) ::
          [map()] | {:ok, [map()]} | {:error, event_history_error()}
  def event_history(identifier_or_identity, opts \\ [])

  def event_history(identifier, opts) when is_binary(identifier) do
    case EventHistory.read_event_history(event_log_path(identifier), Keyword.put_new(opts, :limit, @history_limit)) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  def event_history(%TrackerIdentity{} = identity, opts) do
    if TrackerIdentity.joinable?(identity) do
      EventHistory.read_event_history(event_log_path(identity), Keyword.put_new(opts, :limit, @history_limit))
    else
      {:error, :invalid_identity}
    end
  end

  @doc """
  Returns the resolved file path for an issue's log. Useful for tests
  and for users who want to `tail -F` a specific issue.
  """
  @spec log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  defdelegate log_path(identifier), to: Paths

  @doc false
  @spec event_log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  defdelegate event_log_path(identifier), to: Paths

  @doc """
  Returns the durable JSONL transcript path used by the classified events API.

  Unlike the human-readable `.log`, this sidecar preserves the complete
  transcript event, including its provider payload.
  """
  @spec transcript_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  defdelegate transcript_path(identifier), to: Paths

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    writer_key = Keyword.get(opts, :writer_key, writer_key(identifier))
    GenServer.start_link(__MODULE__, opts, name: via(writer_key))
  end

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    path = Keyword.get(opts, :path, log_path(identifier))
    event_path = Keyword.get(opts, :event_path, event_log_path(identifier))
    transcript_path = Keyword.get(opts, :transcript_path, transcript_path(identifier))
    :ok = File.mkdir_p(Path.dirname(path))

    # #2557. A writer's subscription links it to an `Aiur.PubSub` partition —
    # `Phoenix.PubSub.subscribe/2` registers, and `Registry` links every
    # registered process to the partition it registered in. Without
    # `trap_exit`, one PubSub crash therefore kills *every* live writer at
    # once, and `Aiur.IssueLog.Supervisor` restarts each one: N simultaneous
    # deaths blow a `DynamicSupervisor`'s 3-in-5 budget for any N > 3
    # (a daemon holds one writer per active ticket), so the supervisor itself
    # exits `:shutdown`. That death is a *second*, independent child death in
    # `Aiur.Supervisor`, arriving from child #6 rather than from PubSub at
    # child #1 — which defeats the whole point of `:rest_for_one`: the
    # cascade then restarts PubSub's dependents while PubSub is still absent,
    # they raise `unknown registry: Aiur.PubSub`, and the retry loop takes the
    # application tree down (`Aiur.ApplicationTest`, "a crashing Aiur.PubSub
    # does not topple the application supervision tree").
    #
    # Trapping exits makes the link informational instead of fatal: the writer
    # keeps its files and its history, and re-subscribes when the registry is
    # back. Nothing restarts, so no budget anywhere is spent.
    Process.flag(:trap_exit, true)

    case open_log_files(path, event_path, transcript_path) do
      {:ok, file, event_file, transcript_file} ->
        Logger.debug("IssueLog attached identifier=#{identifier} path=#{path}")

        state = %{
          identifier: identifier,
          file: file,
          event_file: event_file,
          transcript_file: transcript_file,
          transcript_path: transcript_path,
          path: path,
          event_path: event_path,
          history: :queue.new(),
          history_size: 0,
          subscribed?: false,
          writer_key: Keyword.get(opts, :writer_key, writer_key(identifier))
        }

        {:ok, subscribe_agent(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Best-effort, and deliberately not a startup precondition: a writer that is
  # restarted (or attached) inside the window where `Aiur.PubSub` is down would
  # otherwise raise `unknown registry: Aiur.PubSub` out of `init/1` and count a
  # failed start against `Aiur.IssueLog.Supervisor`. Unsubscribe-then-subscribe
  # keeps it idempotent: `Phoenix.PubSub` subscriptions stack, so a re-entry
  # after a spurious `:EXIT` must not leave the writer receiving each event
  # twice.
  defp subscribe_agent(state) do
    _ = AgentPubSub.unsubscribe_agent(state.identifier)
    :ok = AgentPubSub.subscribe_agent(state.identifier)
    %{state | subscribed?: true}
  rescue
    ArgumentError -> schedule_resubscribe(state)
  catch
    :exit, _reason -> schedule_resubscribe(state)
  end

  # The writer is registered under `writer_key` in `Aiur.IssueLog.Registry`,
  # which links it to that registry's partition too. A writer that outlives its
  # partition would otherwise be *unregistered* and invisible to `attach/1`,
  # holding its files open while a replacement writes the same log — so
  # surviving the signal has to include putting the name back. If some other
  # process already holds the name, this incarnation is the redundant one and
  # stops normally (`restart: :transient`, so nothing restarts it).
  defp ensure_registered(state) do
    case Registry.lookup(Aiur.IssueLog.Registry, state.writer_key) do
      [{pid, _value}] when pid == self() -> :ok
      [{_other, _value}] -> :taken
      [] -> register_writer_key(state)
    end
  rescue
    ArgumentError -> :ok
  end

  defp register_writer_key(state) do
    case Registry.register(Aiur.IssueLog.Registry, state.writer_key, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, pid}} when pid == self() -> :ok
      {:error, {:already_registered, _pid}} -> :taken
    end
  rescue
    ArgumentError -> :ok
  end

  defp schedule_resubscribe(state) do
    Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
    %{state | subscribed?: false}
  end

  @impl true
  def terminate(_reason, %{file: file, event_file: event_file, transcript_file: transcript_file}) when not is_nil(file) do
    _ = File.close(file)
    _ = File.close(event_file)
    _ = File.close(transcript_file)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:history, limit}, _from, state) do
    items =
      state.history
      |> :queue.to_list()
      |> Enum.take(-limit)
      |> Enum.map(fn
        {:transcript_event, event} -> Map.put_new(event, :turn_id, nil)
        {:alert, event} -> %{role: :alert, body: event[:message] || "", turn_id: nil}
        bare when is_map(bare) -> bare
      end)

    {:reply, items, state}
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_info({:transcript_event, %{role: _role, body: _body} = event}, state) do
    # Also surface the line in the system-wide `aiur.log` using the
    # same `[tag]` shape the pane shows. `Logger.debug` entries
    # (broadcast traces, codex notifications) only appear when
    # `--debug` is on; everything else in aiur.log is one of these
    # human-readable rows, mirroring what the Executor sees in the pane.
    Logger.info(format_log_line(event[:role], event[:body], state.identifier))

    write_and_continue(
      state,
      format_transcript(event[:role], event[:body], event),
      {:transcript_event, event}
    )
  end

  def handle_info({:alert, %{name: _name, message: _message} = event}, state) do
    # No Logger.info here — `Alerts.emit_system/2` already logs each
    # alert with `[alert] (#identifier) name: message`, so mirroring it
    # would double every alert row in aiur.log.
    write_and_continue(state, format_alert(event[:name], event[:message], event), {:alert, event})
  end

  def handle_info({:control_lifecycle, %{request_id: _request_id, status: _status} = event}, state) do
    history = %{role: :system, body: "control lifecycle", payload: event, turn_id: nil}
    write_and_continue(state, "[control] " <> Jason.encode!(event) <> "\n", history)
  end

  def handle_info({:aiur_event, kind, event}, state)
      when kind in [:emit, :emit_alert, :consumed, :self] do
    write_event_and_continue(state, format_event_marker(kind, event))
  end

  # The registry partition this writer subscribed through went down (see the
  # `trap_exit` note in `init/1`). The writer stays up; it just has to get its
  # subscription back once `Aiur.PubSub` is running again. A `gen_server`
  # routes its parent's exit to `terminate/2` before this clause is reached, so
  # a supervisor shutdown still shuts the writer down.
  def handle_info({:EXIT, _pid, _reason}, state) do
    case ensure_registered(state) do
      :ok -> {:noreply, subscribe_agent(state)}
      :taken -> {:stop, :normal, state}
    end
  end

  def handle_info(:resubscribe, state), do: {:noreply, subscribe_agent(state)}

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Writes an `[event:<kind>]` marker row to the per-issue log file.
  Called from `Aiur.Events.Publisher.publish/3` (for `:emit`),
  `Aiur.Events.SubscriptionStore` post-enqueue (`:consumed`), and the
  agent's own emit path (`:self`) so the Executor can `tail -F` the log
  and see every event for this issue in one place.

  Async cast — never blocks the publisher.
  """
  @spec record_event(String.t(), atom(), map()) :: :ok
  def record_event(identifier, kind, event)
      when is_binary(identifier) and kind in [:emit, :emit_alert, :consumed, :self] and
             is_map(event) do
    case event_identity(event, identifier) do
      {:ok, identity} ->
        case writer_for_path(identifier, log_path(identity), writer_key(identity)) do
          [{pid, _}] -> send(pid, {:aiur_event, kind, event})
          [] -> :ok
        end

      :error ->
        :ok
    end

    :ok
  end

  defp event_identity(%{ticket_observation: %TicketObservation{} = observation}, identifier) do
    identity = observation.tracker_identity

    if observation.status == :joinable and TrackerIdentity.joinable?(identity) and identity.identifier == identifier,
      do: {:ok, identity},
      else: :error
  end

  defp event_identity(_event, _identifier), do: :error

  defp push_history(state, item) do
    queue = :queue.in(item, state.history)
    size = state.history_size + 1

    if size > @history_limit do
      {_, trimmed} = :queue.out(queue)
      %{state | history: trimmed, history_size: @history_limit}
    else
      %{state | history: queue, history_size: size}
    end
  end

  defp write_and_continue(state, line, history_item) do
    # A writer's target is fixed when it starts. Re-resolving the mutable
    # workflow repository here could make an existing writer append to a
    # different repository's same-number ticket log after a config reload.
    write_line(state.file, line)

    state =
      case write_transcript_line(state.transcript_file, history_item, state.identifier) do
        :ok -> state
        {:error, _reason} -> reopen_transcript_and_retry(state, history_item)
      end

    state = push_history(state, history_item)
    {:noreply, state}
  end

  defp write_event_and_continue(state, line) do
    write_line(state.file, line)
    write_line(state.event_file, line)
    {:noreply, state}
  end

  defp write_transcript_line(file, event, identifier) do
    encoded = Encoding.encode(event)
    :ok = IO.write(file, encoded <> "\n")
  rescue
    error ->
      Logger.warning("IssueLog transcript write failed identifier=#{identifier} reason=#{Exception.message(error)}")
      {:error, error}
  end

  defp reopen_transcript_and_retry(state, event) do
    _ = File.close(state.transcript_file)

    case File.open(state.transcript_path, [:append, :utf8]) do
      {:ok, transcript_file} ->
        state = %{state | transcript_file: transcript_file}
        _ = write_transcript_line(transcript_file, event, state.identifier)
        state

      {:error, reason} ->
        Logger.warning("IssueLog transcript reopen failed identifier=#{state.identifier} reason=#{inspect(reason)}")
        state
    end
  end
end
