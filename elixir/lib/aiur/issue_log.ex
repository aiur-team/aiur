defmodule Aiur.IssueLog do
  @moduledoc """
  Per-issue file writer that captures the same transcript + alert stream
  the opencode pane shows. One GenServer per active issue; it
  subscribes to the agent's PubSub topic on startup and appends every
  event to `<logs-root>/log/<repo>.<issue>.log`.

  Multiple agent sessions on the same issue reuse the running writer —
  `attach/1` is idempotent. The writer stays alive until the BEAM exits;
  there's no automatic detach when the issue completes (the file is
  capped by disk, not by a watchdog), and the closed-then-reopened case
  is handled by the underlying `File.open([:append])`.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub}
  alias Aiur.Config.Paths

  @supervisor Aiur.IssueLog.Supervisor

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:identifier],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # Cap on how many recent events we keep in memory for `history/2`.
  @history_limit 100

  @doc """
  Ensure a writer is running for `identifier`. Returns `:ok` on success;
  if a writer is already running for this identifier the call is a
  no-op.
  """
  @spec attach(AgentEvents.agent_identifier()) :: :ok
  def attach(identifier) when is_binary(identifier) do
    case start_writer(identifier) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("IssueLog.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Return up to `limit` recent transcript/alert events captured for this
  issue, oldest first. Returns `[]` if no writer is running yet for the
  given identifier — callers should still treat that as "no history
  available" rather than as an error.
  """
  @spec history(AgentEvents.agent_identifier(), pos_integer()) :: [map()]
  def history(identifier, limit \\ @history_limit) when is_binary(identifier) do
    case Registry.lookup(Aiur.IssueLog.Registry, identifier) do
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
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-limit)

      _ ->
        []
    end
  end

  @doc """
  Parse `[event:emit]` / `[event:emit_alert]` / `[event:self]` / `[event:consumed]`
  lines from the per-issue log. Returns a list of partial event maps with
  `id`, `topic`, `kind`, `summary`, `ts` fields. Used by `Aiur.AgentRunner`
  to build the bootstrap digest on agent (re)start — events with
  `id > last_seen_event_id` represent activity the agent missed while
  inactive.

  Options:
    * `:since_id` — only return events with `id > since_id` (default 0)
    * `:kinds` — list of kinds to include (default `[:emit, :emit_alert]`)
    * `:limit` — max number of returned events (default `@history_limit`)
  """
  @spec event_history(AgentEvents.agent_identifier(), keyword()) :: [map()]
  def event_history(identifier, opts \\ []) when is_binary(identifier) do
    since_id = Keyword.get(opts, :since_id, 0)
    kinds = Keyword.get(opts, :kinds, [:emit, :emit_alert])
    limit = Keyword.get(opts, :limit, @history_limit)
    kind_set = MapSet.new(Enum.map(kinds, &Atom.to_string/1))
    path = log_path(identifier)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_event_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn ev ->
          MapSet.member?(kind_set, ev.kind) and is_integer(ev.id) and ev.id > since_id
        end)
        |> Enum.take(-limit)

      _ ->
        []
    end
  end

  defp parse_event_line(line) do
    case Regex.run(~r/\A([0-9T:\-\.Z]+) \[event:([a-z_]+)\] id=(\d+) ([^:\s]+)(?:: (.*))?\z/, line) do
      [_, ts, kind, id_str, topic, summary] ->
        %{kind: kind, id: String.to_integer(id_str), topic: topic, ts: ts, summary: summary || ""}

      [_, ts, kind, id_str, topic] ->
        %{kind: kind, id: String.to_integer(id_str), topic: topic, ts: ts, summary: ""}

      _ ->
        nil
    end
  end

  defp parse_line(line) do
    case Regex.run(~r/\A([0-9T:\-\.Z]+) \[([a-z]+)\] (.*)\z/, line) do
      [_, _ts, tag, body] ->
        case role_from_tag(tag) do
          nil -> nil
          role -> %{role: role, body: body, turn_id: nil}
        end

      _ ->
        nil
    end
  end

  defp role_from_tag("agent"), do: :assistant
  defp role_from_tag("user"), do: :user
  defp role_from_tag("cmd"), do: :command
  defp role_from_tag("system"), do: :system
  defp role_from_tag("alert"), do: :alert
  defp role_from_tag(_), do: nil

  @doc """
  Returns the resolved file path for an issue's log. Useful for tests
  and for users who want to `tail -F` a specific issue.
  """
  @spec log_path(AgentEvents.agent_identifier()) :: String.t()
  def log_path(identifier) when is_binary(identifier) do
    Path.join(log_root_dir(), "#{repo_name()}.#{sanitize(identifier)}.log")
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, identifier, name: via(identifier))
  end

  @impl true
  def init(identifier) do
    path = log_path(identifier)
    :ok = File.mkdir_p(Path.dirname(path))

    case File.open(path, [:append, :utf8]) do
      {:ok, file} ->
        :ok = AgentPubSub.subscribe_agent(identifier)
        Logger.debug("IssueLog attached identifier=#{identifier} path=#{path}")
        {:ok, %{identifier: identifier, file: file, path: path, history: :queue.new(), history_size: 0}}

      {:error, reason} ->
        Logger.warning("IssueLog open failed identifier=#{identifier} path=#{path} reason=#{inspect(reason)}")

        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{file: file}) when not is_nil(file) do
    _ = File.close(file)
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

  @impl true
  def handle_info({:transcript_event, %{role: _role, body: _body} = event}, state) do
    write_line(state.file, format_transcript(event[:role], event[:body], event))

    # Also surface the line in the system-wide `aiur.log` using the
    # same `[tag]` shape the pane shows. `Logger.debug` entries
    # (broadcast traces, codex notifications) only appear when
    # `--debug` is on; everything else in aiur.log is one of these
    # human-readable rows, mirroring what the operator sees in the pane.
    Logger.info(format_log_line(event[:role], event[:body], state.identifier))

    {:noreply, push_history(state, {:transcript_event, event})}
  end

  def handle_info({:alert, %{name: _name, message: _message} = event}, state) do
    write_line(state.file, format_alert(event[:name], event[:message], event))
    # No Logger.info here — `Alerts.emit_system/2` already logs each
    # alert with `[alert] (#identifier) name: message`, so mirroring it
    # would double every alert row in aiur.log.
    {:noreply, push_history(state, {:alert, event})}
  end

  def handle_info({:aiur_event, kind, event}, state)
      when kind in [:emit, :emit_alert, :consumed, :self] do
    write_line(state.file, format_event_marker(kind, event))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Writes an `[event:<kind>]` marker row to the per-issue log file.
  Called from `Aiur.Events.Publisher.publish/3` (for `:emit`),
  `Aiur.Events.SubscriptionStore` post-enqueue (`:consumed`), and the
  agent's own emit path (`:self`) so the operator can `tail -F` the log
  and see every event for this issue in one place.

  Async cast — never blocks the publisher.
  """
  @spec record_event(String.t(), atom(), map()) :: :ok
  def record_event(identifier, kind, event)
      when is_binary(identifier) and kind in [:emit, :emit_alert, :consumed, :self] and
             is_map(event) do
    case Registry.lookup(Aiur.IssueLog.Registry, identifier) do
      [{pid, _}] -> send(pid, {:aiur_event, kind, event})
      [] -> :ok
    end

    :ok
  end

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

  # ---------- helpers ------------------------------------------------------

  defp start_writer(identifier) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, identifier: identifier}
    )
  end

  defp via(identifier), do: {:via, Registry, {Aiur.IssueLog.Registry, identifier}}

  defp write_line(file, line) do
    IO.write(file, line)
  rescue
    _ -> :ok
  end

  defp format_transcript(role, body, event) do
    ts = timestamp(event)
    body_text = body |> to_string() |> String.replace("\r\n", "\n")
    "#{ts} [#{tag_for_role(role)}] #{body_text}\n"
  end

  defp format_alert(name, message, event) do
    ts = timestamp(event)
    "#{ts} [alert] #{name}: #{message}\n"
  end

  defp format_event_marker(kind, event) do
    ts = timestamp(event)
    id = Map.get(event, :id) || Map.get(event, "id") || ""
    topic = Map.get(event, :topic) || Map.get(event, "topic") || ""
    msg = Map.get(event, "message") || Map.get(event, :message) || ""

    "#{ts} [event:#{kind}] id=#{id} #{topic}" <>
      if(msg != "", do: ": " <> summarize(to_string(msg)), else: "") <> "\n"
  end

  defp format_log_line(role, body, identifier) do
    "[#{tag_for_role(role)}] (##{identifier}) #{summarize(body)}"
  end

  defp tag_for_role(role)
       when role in [:assistant, :user, :system, :command, :alert, :reasoning, :tool],
       do: AgentEvents.tag_name(role)

  defp tag_for_role(other), do: to_string(other)

  defp summarize(nil), do: ""

  defp summarize(text) when is_binary(text) do
    single_line = text |> String.replace(~r/\r?\n/, " ") |> String.trim()

    if byte_size(single_line) > 200 do
      binary_part(single_line, 0, 200) <> "…"
    else
      single_line
    end
  end

  defp summarize(other), do: inspect(other)

  defp timestamp(event) do
    case Map.get(event, :timestamp) do
      %DateTime{} = ts -> DateTime.to_iso8601(ts)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp log_root_dir, do: Paths.log_root_dir()
  defp repo_name, do: Paths.repo_name()
  defp sanitize(name), do: Paths.sanitize(name)
end
