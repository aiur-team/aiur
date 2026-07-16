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
  alias Aiur.Config.Paths
  alias Aiur.GitHub.Config, as: GitHubConfig

  @supervisor Aiur.IssueLog.Supervisor

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
        writer_key(identity)
      )
    else
      :ok
    end
  end

  def attach(identifier) when is_binary(identifier) do
    attach_writer(identifier, log_path(identifier), event_log_path(identifier), writer_key(identifier))
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
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-limit)

      _ ->
        []
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
    case read_event_history(event_log_path(identifier), opts) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  def event_history(%TrackerIdentity{} = identity, opts) do
    if TrackerIdentity.joinable?(identity) do
      read_event_history(event_log_path(identity), opts)
    else
      {:error, :invalid_identity}
    end
  end

  defp read_event_history(path, opts) do
    since_id = Keyword.get(opts, :since_id, 0)
    kinds = Keyword.get(opts, :kinds, [:emit, :emit_alert])
    limit = Keyword.get(opts, :limit, @history_limit)
    kind_set = MapSet.new(Enum.map(kinds, &Atom.to_string/1))

    case File.read(path) do
      {:ok, content} ->
        events =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_event_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn ev ->
            MapSet.member?(kind_set, ev.kind) and is_integer(ev.id) and ev.id > since_id
          end)
          |> Enum.take(-limit)

        {:ok, events}

      {:error, :enoent} ->
        {:error, :missing_source}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  defp parse_event_line(line) do
    # Matches the optional `src=…` / `trust=…` flag segments between
    # `id=…` and the topic. Flags are surfaced as fields on the parsed
    # event so bootstrap replays carry the same `author_trusted?` +
    # `source` signal that the render-side filter and `<external-content>`
    # wrapper depend on (a missing flag is treated as untrusted /
    # non-github respectively).
    case Regex.run(
           ~r/\A([0-9T:\-\.Z]+) \[event:([a-z_]+)\] id=(\d+)((?: \w+=[^\s]+)*) ([^:\s]+)(?:: (.*))?\z/,
           line
         ) do
      [_, ts, kind, id_str, flag_segment, topic, summary] ->
        build_parsed_event(ts, kind, id_str, flag_segment, topic, summary)

      [_, ts, kind, id_str, flag_segment, topic] ->
        build_parsed_event(ts, kind, id_str, flag_segment, topic, "")

      _ ->
        nil
    end
  end

  defp build_parsed_event(ts, kind, id_str, flag_segment, topic, summary) do
    flags = parse_flags(flag_segment)

    %{
      kind: kind,
      id: String.to_integer(id_str),
      topic: topic,
      ts: ts,
      summary: summary,
      source: flags |> Map.get("src") |> maybe_atomize_source(),
      author_trusted?: flags |> Map.get("trust") |> maybe_atomize_bool()
    }
  end

  defp parse_flags(flag_segment) when is_binary(flag_segment) do
    flag_segment
    |> String.split(" ", trim: true)
    |> Enum.flat_map(fn token ->
      case String.split(token, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_flags(_), do: %{}

  defp maybe_atomize_source(nil), do: nil
  defp maybe_atomize_source("github"), do: :github
  defp maybe_atomize_source(other) when is_binary(other), do: other
  defp maybe_atomize_source(_), do: nil

  defp maybe_atomize_bool(nil), do: nil
  defp maybe_atomize_bool("true"), do: true
  defp maybe_atomize_bool("false"), do: false
  defp maybe_atomize_bool(_), do: nil

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
  @spec log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  def log_path(identifier) when is_binary(identifier) do
    issue_log_path(configured_repository_scope(), identifier, ".log")
  end

  def log_path(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      {:github, owner, repository, _provider_id} ->
        issue_log_path(repository_scope(owner, repository), identity.identifier, ".log")

      nil ->
        raise ArgumentError, "IssueLog path requires a joinable tracker identity"
    end
  end

  @doc false
  @spec event_log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  def event_log_path(identifier) when is_binary(identifier) do
    issue_log_path(configured_repository_scope(), identifier, ".events.log")
  end

  def event_log_path(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      {:github, owner, repository, _provider_id} ->
        issue_log_path(repository_scope(owner, repository), identity.identifier, ".events.log")

      nil ->
        raise ArgumentError, "IssueLog path requires a joinable tracker identity"
    end
  end

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
    :ok = File.mkdir_p(Path.dirname(path))

    case File.open(path, [:append, :utf8]) do
      {:ok, file} ->
        case File.open(event_path, [:append, :utf8]) do
          {:ok, event_file} ->
            :ok = AgentPubSub.subscribe_agent(identifier)
            Logger.debug("IssueLog attached identifier=#{identifier} path=#{path}")

            {:ok,
             %{
               identifier: identifier,
               file: file,
               event_file: event_file,
               path: path,
               event_path: event_path,
               history: :queue.new(),
               history_size: 0
             }}

          {:error, reason} ->
            _ = File.close(file)
            Logger.warning("IssueLog event open failed identifier=#{identifier} path=#{event_path} reason=#{inspect(reason)}")
            {:stop, reason}
        end

      {:error, reason} ->
        Logger.warning("IssueLog open failed identifier=#{identifier} path=#{path} reason=#{inspect(reason)}")

        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{file: file, event_file: event_file}) when not is_nil(file) do
    _ = File.close(file)
    _ = File.close(event_file)
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
        case writer_for_path(identifier, event_log_path(identity), writer_key(identity)) do
          [{pid, _}] -> send(pid, {:aiur_event, kind, event})
          [] -> :ok
        end

      :error ->
        :ok
    end

    :ok
  end

  defp attach_writer(identifier, path, event_path, key) do
    case ensure_writer(identifier, path, event_path, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("IssueLog.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  defp event_identity(%{ticket_observation: %TicketObservation{} = observation}, identifier) do
    identity = observation.tracker_identity

    if observation.status == :joinable and TrackerIdentity.joinable?(identity) and identity.identifier == identifier,
      do: {:ok, identity},
      else: :error
  end

  defp event_identity(_event, _identifier), do: :error

  defp ensure_writer(identifier, path, event_path, key) do
    case Registry.lookup(Aiur.IssueLog.Registry, key) do
      [] ->
        start_writer(identifier, path, event_path, key)

      [{pid, _}] ->
        if writer_path(pid) == path do
          :ok
        else
          replace_writer(identifier, pid, path, event_path, key)
        end
    end
  end

  defp replace_writer(identifier, pid, path, event_path, key) do
    case DynamicSupervisor.terminate_child(@supervisor, pid) do
      :ok -> start_writer(identifier, path, event_path, key)
      {:error, :not_found} -> start_writer(identifier, path, event_path, key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_writer(identifier, path, event_path, key) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, identifier: identifier, path: path, event_path: event_path, writer_key: key}
    )
    |> normalize_start_result()
  end

  defp normalize_start_result({:ok, _pid}), do: :ok
  defp normalize_start_result({:error, {:already_started, _pid}}), do: :ok
  defp normalize_start_result({:error, reason}), do: {:error, reason}

  defp writer_for_path(_identifier, path, key) do
    case Registry.lookup(Aiur.IssueLog.Registry, key) do
      [{pid, _}] = writer -> if writer_path(pid) == path, do: writer, else: []
      _ -> []
    end
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

  defp writer_path(pid) do
    GenServer.call(pid, :path, 1_000)
  catch
    :exit, _ -> nil
  end

  defp writer_key(identifier) when is_binary(identifier),
    do: {:issue_log, configured_repository_scope(), identifier}

  defp writer_key(%TrackerIdentity{} = identity) do
    {:github, owner, repository, _provider_id} = TrackerIdentity.github_key(identity)
    {:issue_log, repository_scope(owner, repository), identity.identifier}
  end

  defp via(key), do: {:via, Registry, {Aiur.IssueLog.Registry, key}}

  defp write_and_continue(state, line, history_item) do
    # A writer's target is fixed when it starts. Re-resolving the mutable
    # workflow repository here could make an existing writer append to a
    # different repository's same-number ticket log after a config reload.
    write_line(state.file, line)
    state = if history_item, do: push_history(state, history_item), else: state
    {:noreply, state}
  end

  defp write_event_and_continue(state, line) do
    write_line(state.file, line)
    write_line(state.event_file, line)
    {:noreply, state}
  end

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
    "#{timestamp(event)} [event:#{kind}] id=#{event_field(event, :id, "")}" <>
      flag_segment(event) <>
      " #{event_field(event, :topic, "")}" <>
      message_suffix(event) <>
      "\n"
  end

  defp event_field(event, key, default) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key)) || default
  end

  # `src=`/`trust=` are appended in a fixed order before the `topic`
  # so `Aiur.IssueLog.event_history/2` can reconstruct the security-
  # sensitive flags on bootstrap. Without them, U2 replays would
  # bypass the U7 CODEOWNERS filter and `<external-content>` wrapper.
  defp flag_segment(event) do
    flags =
      []
      |> append_flag("src", event_field(event, :source, nil))
      |> append_flag("trust", event_field(event, :author_trusted?, nil))
      |> Enum.join(" ")

    if flags == "", do: "", else: " " <> flags
  end

  defp message_suffix(event) do
    msg = event_field(event, :message, "")
    if msg == "", do: "", else: ": " <> summarize(to_string(msg))
  end

  defp append_flag(acc, _name, nil), do: acc
  defp append_flag(acc, name, value), do: acc ++ ["#{name}=#{value}"]

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

  defp configured_repository_scope do
    case GitHubConfig.configured_repo() do
      {:ok, {owner, repository}} -> repository_scope(owner, repository)
      {:error, _reason} -> repo_name()
    end
  end

  defp repository_scope(owner, repository) do
    encoded = Base.url_encode64("#{String.downcase(owner)}/#{String.downcase(repository)}", padding: false)
    "github-" <> encoded
  end

  defp issue_log_path(scope, identifier, suffix) do
    Path.join(log_root_dir(), "#{scope}.#{sanitize(identifier)}#{suffix}")
  end

  defp repo_name, do: Paths.repo_name()
  defp sanitize(name), do: Paths.sanitize(name)
end
