defmodule Aiur.CurrentRunMembership.Store do
  @moduledoc """
  Daemon-private durable store for the current-run membership projection.

  Version 1 stores a checksummed checkpoint and an append-only checksummed
  journal beneath one run-qualified, owner-only directory. A projection-only
  restart replays those records for the same `run_id`; a different `run_id`
  always starts an empty generation and can never replay a prior run.

  The checkpoint is a compaction cache, not an alternative lifecycle source.
  An observation is appended and synced before its checkpoint is written, and
  a first checkpoint directory entry is synced before the journal may be
  cleared or a change is published. A malformed checkpoint or journal is
  quarantined and leaves the store degraded or unavailable rather than
  silently reporting a healthy empty set.

  Rolling back to code that does not understand this schema must leave the
  recovery state untouched. Rebuilding is deliberately generation-local:
  operator recovery can discard only the active run's recovery directory and
  then reconcile fresh tracker/StatusReport observations; the store retains no
  cross-run history to migrate.
  """

  use GenServer

  require Logger

  alias Aiur.{Boot, Config, DecisionLog, Fs, TrackerIdentity}
  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunMembership.{Event, Projection}

  @checkpoint_version 1
  @journal_filename "membership.ndjson"
  @checkpoint_filename "membership.checkpoint.json"
  @degraded_filename "membership.degraded.json"
  @max_snapshot_limit 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec observe(TrackerIdentity.t(), Event.lifecycle(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(identity, lifecycle, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    source = Keyword.get(opts, :source, :status_report)
    GenServer.call(server, {:observe, identity, lifecycle, observed_at, source}, 60_000)
  end

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = Keyword.get(opts, :limit, @max_snapshot_limit)
    GenServer.call(server, {:snapshot, limit})
  end

  @spec lookup(TrackerIdentity.t(), GenServer.server()) :: {:ok, Projection.member()} | {:error, :not_found}
  def lookup(identity, server \\ __MODULE__), do: GenServer.call(server, {:lookup, identity})

  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @spec health(GenServer.server()) :: term()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @spec freshness(GenServer.server()) :: map()
  def freshness(server \\ __MODULE__), do: GenServer.call(server, :freshness)

  @impl true
  def init(opts) do
    run_id = Keyword.get(opts, :run_id, Boot.run_id())
    persistence = persistence_options(opts)

    state =
      case state_dir(opts) do
        {:ok, root} -> boot(root, run_id, persistence)
        {:error, reason} -> unavailable_state(run_id, persistence, {:path_unresolved, reason})
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:observe, _identity, _lifecycle, _observed_at, _source}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:membership_unavailable, state.health}}, state}
  end

  def handle_call({:observe, identity, lifecycle, observed_at, source}, _from, state) do
    with {:ok, event} <- Event.new(state.run_id, identity, lifecycle, observed_at, source: source) do
      case Projection.apply(state.projection, event) do
        {:accepted, projection} -> persist(event, projection, state)
        {:ignored, reason, _projection} -> {:reply, {:ok, %{status: reason, generation: state.projection.generation}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot, limit}, _from, state) do
    limit = snapshot_limit(limit)
    members = Projection.members(state.projection)
    visible_members = Enum.take(members, limit)

    snapshot = %{
      run_id: state.run_id,
      generation: state.projection.generation,
      health: state.health,
      health_message: health_message(state.health),
      freshness: state_freshness(state),
      members: visible_members,
      truncated?: length(members) > length(visible_members)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:lookup, identity}, _from, state) do
    case Projection.member(state.projection, identity) do
      nil -> {:reply, {:error, :not_found}, state}
      member -> {:reply, {:ok, member}, state}
    end
  end

  def handle_call(:generation, _from, state), do: {:reply, state.projection.generation, state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:freshness, _from, state), do: {:reply, state_freshness(state), state}

  defp persistence_options(opts) do
    %{
      append_fun: Keyword.get(opts, :append_fun, &DecisionLog.append/2),
      checkpoint_fun: Keyword.get(opts, :checkpoint_fun, &write_checkpoint/2),
      clear_journal_fun: Keyword.get(opts, :clear_journal_fun, &clear_journal/1),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      cleanup_fun: Keyword.get(opts, :cleanup_fun, &cleanup_obsolete_runs/2)
    }
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Config.Paths.current_run_membership_state_dir()
    end
  end

  defp boot(root, run_id, persistence) do
    with :ok <- valid_run_id(run_id),
         {:ok, paths} <- prepare_paths(root, run_id, persistence.sync_fun) do
      load(paths, run_id, persistence)
    else
      {:error, reason} -> unavailable_state(run_id, persistence, {:prepare_failed, reason})
    end
  end

  defp prepare_paths(root, run_id, sync_fun) do
    runs_dir = Path.join(root, "runs")
    run_dir = Path.join(runs_dir, run_leaf(run_id))
    journal_path = Path.join(run_dir, @journal_filename)

    with :ok <- DecisionLog.ensure_directory(root),
         :ok <- DecisionLog.ensure_directory(runs_dir),
         :ok <- DecisionLog.prepare(run_dir, journal_path, sync_fun) do
      {:ok,
       %{
         root: root,
         runs_dir: runs_dir,
         run_dir: run_dir,
         run_leaf: run_leaf(run_id),
         journal_path: journal_path,
         checkpoint_path: Path.join(run_dir, @checkpoint_filename),
         degraded_path: Path.join(run_dir, @degraded_filename)
       }}
    end
  end

  defp load(paths, run_id, persistence) do
    checkpoint = load_checkpoint(paths.checkpoint_path, run_id)
    marker = load_degraded_marker(paths.degraded_path, run_id)
    {projection, checkpoint_health, writable?} = checkpoint_projection(checkpoint, run_id)
    {projection, journal_health, journal_writable?} = replay_journal(paths.journal_path, run_id, projection)

    health = boot_health(marker, checkpoint_health, journal_health)
    writable? = writable? and journal_writable? and marker == :absent

    state = %{
      run_id: run_id,
      projection: projection,
      root: paths.root,
      runs_dir: paths.runs_dir,
      run_leaf: paths.run_leaf,
      journal_path: paths.journal_path,
      checkpoint_path: paths.checkpoint_path,
      degraded_path: paths.degraded_path,
      append_fun: persistence.append_fun,
      checkpoint_fun: persistence.checkpoint_fun,
      clear_journal_fun: persistence.clear_journal_fun,
      sync_fun: persistence.sync_fun,
      cleanup_fun: persistence.cleanup_fun,
      clock: persistence.clock,
      recovered_at: persistence.clock.(),
      writable?: writable?,
      health: health
    }

    state = maybe_quarantine_recovery_artifacts(state, checkpoint, journal_health)

    if state.health == :healthy do
      case state.cleanup_fun.(state.runs_dir, state.run_leaf) do
        :ok -> state
        {:error, reason} -> %{state | health: {:degraded, {:cleanup_failed, reason}}}
      end
    else
      state
    end
  end

  defp checkpoint_projection(:missing, run_id), do: {Projection.new(run_id), :healthy, true}

  defp checkpoint_projection({:ok, projection}, _run_id), do: {projection, :healthy, true}

  defp checkpoint_projection({:corrupt, reason}, run_id) do
    {Projection.new(run_id), {:degraded, {:checkpoint_corrupt, reason}}, false}
  end

  defp replay_journal(path, run_id, projection) do
    validator = fn record ->
      with {:ok, event} <- Event.from_record(record),
           true <- event.run_id == run_id do
        {:ok, event}
      else
        false -> {:error, :wrong_run}
        {:error, reason} -> {:error, reason}
      end
    end

    case DecisionLog.replay(path, validator) do
      {:ok, events, nil} ->
        {replay_events(projection, events), :healthy, true}

      {:ok, events, {:corrupt, line, reason}} ->
        {replay_events(projection, events), {:degraded, {:journal_corrupt, line, reason}}, false}

      {:error, reason} ->
        {projection, {:unavailable, {:journal_unreadable, reason}}, false}
    end
  end

  defp replay_events(projection, events) do
    Enum.reduce(events, projection, fn event, projection ->
      case Projection.apply(projection, event) do
        {:accepted, projection} -> projection
        {:ignored, _reason, projection} -> projection
      end
    end)
  end

  defp boot_health(:absent, :healthy, :healthy), do: :healthy
  defp boot_health({:degraded, reason}, _checkpoint_health, _journal_health), do: {:degraded, reason}
  defp boot_health({:unavailable, reason}, _checkpoint_health, _journal_health), do: {:unavailable, reason}
  defp boot_health(:absent, {:degraded, reason}, _journal_health), do: {:degraded, reason}
  defp boot_health(:absent, :healthy, {:unavailable, reason}), do: {:unavailable, reason}
  defp boot_health(:absent, :healthy, {:degraded, reason}), do: {:degraded, reason}

  defp maybe_quarantine_recovery_artifacts(state, {:corrupt, reason}, _journal_health) do
    degrade_and_quarantine(state, state.checkpoint_path, {:checkpoint_corrupt, reason})
  end

  defp maybe_quarantine_recovery_artifacts(state, _checkpoint, {:degraded, {:journal_corrupt, _line, _reason}} = health) do
    degrade_and_quarantine(state, state.journal_path, elem(health, 1))
  end

  defp maybe_quarantine_recovery_artifacts(state, _checkpoint, _journal_health), do: state

  defp degrade_and_quarantine(state, path, reason) do
    case quarantine(path) do
      :ok ->
        case write_degraded_marker(state.degraded_path, state.run_id, reason, state.sync_fun) do
          :ok -> %{state | health: {:degraded, reason}, writable?: false}
          {:error, marker_reason} -> %{state | health: {:unavailable, {:degraded_marker_failed, marker_reason}}, writable?: false}
        end

      {:error, quarantine_reason} ->
        %{state | health: {:unavailable, {:quarantine_failed, quarantine_reason}}, writable?: false}
    end
  end

  defp persist(event, projection, state) do
    case state.append_fun.(state.journal_path, Event.to_record(event)) do
      :ok -> persist_checkpoint(event, projection, state)
      {:error, reason} -> persist_failed(state, {:append_failed, reason})
    end
  end

  defp persist_checkpoint(event, projection, state) do
    checkpoint_existed? = regular_file?(state.checkpoint_path)

    with :ok <- state.checkpoint_fun.(state.checkpoint_path, checkpoint_record(projection)),
         :ok <- ensure_regular_file(state.checkpoint_path),
         :ok <- sync_first_recovery_entry(checkpoint_existed?, state.sync_fun) do
      candidate = %{state | projection: projection, health: persisted_health(state.health)}
      finish_checkpoint(event, candidate)
    else
      {:error, :checkpoint_entry_sync_failed, reason} ->
        persist_failed(%{state | writable?: false}, {:checkpoint_entry_sync_failed, reason})

      {:error, reason} ->
        persist_failed(%{state | writable?: false}, {:checkpoint_failed, reason})
    end
  end

  defp finish_checkpoint(event, state) do
    case state.clear_journal_fun.(state.journal_path) do
      :ok ->
        notify(state, event)
        {:reply, {:ok, %{status: :accepted, generation: state.projection.generation}}, state}

      {:error, reason} ->
        state = %{state | health: {:degraded, {:journal_compaction_failed, reason}}}
        notify(state, event)
        {:reply, {:ok, %{status: :accepted, generation: state.projection.generation}}, state}
    end
  end

  defp persist_failed(state, reason) do
    health = {:degraded, reason}
    state = %{state | health: health}
    notify(state, nil)
    {:reply, {:error, {:membership_persistence_failed, reason}}, state}
  end

  defp load_checkpoint(path, run_id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, contents} <- File.read(path),
             {:ok, record} <- Jason.decode(contents),
             {:ok, projection} <- checkpoint_from_record(record, run_id) do
          {:ok, projection}
        else
          {:error, reason} -> {:corrupt, reason}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:corrupt, :symlink_rejected}

      {:ok, _stat} ->
        {:corrupt, :not_a_regular_file}

      {:error, reason} ->
        {:corrupt, {:unreadable, reason}}
    end
  end

  defp checkpoint_record(projection) do
    checkpoint = Projection.checkpoint(projection)

    checkpoint
    |> Map.put("version", @checkpoint_version)
    |> Map.put("checksum", checkpoint_checksum(checkpoint))
  end

  defp checkpoint_from_record(record, run_id) when is_map(record) do
    expected_keys = MapSet.new(["version", "run_id", "generation", "members", "checksum"])

    with true <- MapSet.equal?(MapSet.new(Map.keys(record)), expected_keys),
         @checkpoint_version <- Map.get(record, "version"),
         ^run_id <- Map.get(record, "run_id"),
         generation when is_integer(generation) and generation >= 0 <- Map.get(record, "generation"),
         members when is_list(members) <- Map.get(record, "members"),
         checksum when is_binary(checksum) <- Map.get(record, "checksum"),
         true <- checksum == checkpoint_checksum(Map.drop(record, ["version", "checksum"]) |> Map.put("version", @checkpoint_version)),
         {:ok, projection} <- Projection.restore_checkpoint(run_id, generation, members) do
      {:ok, projection}
    else
      false -> {:error, :checksum_mismatch}
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp checkpoint_from_record(_record, _run_id), do: {:error, :invalid_checkpoint}

  defp checkpoint_checksum(%{"run_id" => run_id, "generation" => generation, "members" => members}) do
    {@checkpoint_version, run_id, generation, members}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_checkpoint(path, record) do
    with :ok <- regular_or_missing?(path),
         :ok <- Fs.atomic_write(path, Jason.encode!(record), fsync: true, mode: 0o600) do
      :ok
    end
  end

  defp clear_journal(path) do
    with :ok <- regular_or_missing?(path),
         :ok <- Fs.atomic_write(path, "", fsync: true, mode: 0o600) do
      :ok
    end
  end

  defp regular_or_missing?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp ensure_regular_file(path) do
    if regular_file?(path), do: :ok, else: {:error, :atomic_write_not_visible}
  end

  defp sync_first_recovery_entry(true, _sync_fun), do: :ok

  defp sync_first_recovery_entry(false, sync_fun) do
    case sync_fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, :checkpoint_entry_sync_failed, reason}
    end
  rescue
    error -> {:error, :checkpoint_entry_sync_failed, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, :checkpoint_entry_sync_failed, {kind, reason}}
  end

  defp load_degraded_marker(path, run_id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :absent

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, contents} <- File.read(path),
             {:ok, %{"version" => 1, "run_id" => ^run_id, "reason" => reason}} <- Jason.decode(contents),
             true <- is_binary(reason) do
          {:degraded, reason}
        else
          _ -> {:unavailable, "membership recovery marker is invalid"}
        end

      _ ->
        {:unavailable, "membership recovery marker is unreadable"}
    end
  end

  defp write_degraded_marker(path, run_id, reason, sync_fun) do
    marker_existed? = regular_file?(path)
    record = %{"version" => 1, "run_id" => run_id, "reason" => degraded_marker_reason(reason)}

    with :ok <- regular_or_missing?(path),
         :ok <- Fs.atomic_write(path, Jason.encode!(record), fsync: true, mode: 0o600),
         :ok <- ensure_regular_file(path),
         :ok <- sync_first_recovery_entry(marker_existed?, sync_fun) do
      :ok
    end
  end

  defp degraded_marker_reason({:checkpoint_corrupt, _reason}), do: "checkpoint is corrupt"
  defp degraded_marker_reason({:journal_corrupt, _line, _reason}), do: "journal is corrupt"
  defp degraded_marker_reason({:append_failed, _reason}), do: "journal append failed"
  defp degraded_marker_reason({:checkpoint_failed, _reason}), do: "checkpoint write failed"
  defp degraded_marker_reason({:checkpoint_entry_sync_failed, _reason}), do: "checkpoint directory sync failed"
  defp degraded_marker_reason({:journal_compaction_failed, _reason}), do: "journal compaction failed"
  defp degraded_marker_reason({:cleanup_failed, _reason}), do: "obsolete generation cleanup failed"
  defp degraded_marker_reason(_reason), do: "membership recovery is degraded"

  defp quarantine(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> File.rename(path, path <> ".corrupt-" <> Integer.to_string(System.unique_integer([:positive])))
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_obsolete_runs(runs_dir, active_leaf) do
    with {:ok, entries} <- File.ls(runs_dir) do
      entries
      |> Enum.reject(&(&1 == active_leaf))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        path = Path.join(runs_dir, entry)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} when byte_size(entry) == 64 ->
            case File.rm_rf(path) do
              {:ok, _removed} -> {:cont, :ok}
              {:error, reason, _path} -> {:halt, {:error, reason}}
            end

          {:ok, _stat} ->
            {:halt, {:error, :unexpected_generation_entry}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp run_leaf(run_id) do
    run_id
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_run_id(run_id) when is_binary(run_id) and byte_size(run_id) in 1..512 do
    if run_id == String.trim(run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp valid_run_id(_run_id), do: {:error, :invalid_run_id}

  defp unavailable_state(run_id, persistence, reason) do
    safe_run_id = safe_run_id(run_id)

    %{
      run_id: safe_run_id,
      projection: Projection.new(safe_run_id),
      append_fun: persistence.append_fun,
      checkpoint_fun: persistence.checkpoint_fun,
      clear_journal_fun: persistence.clear_journal_fun,
      sync_fun: persistence.sync_fun,
      cleanup_fun: persistence.cleanup_fun,
      clock: persistence.clock,
      recovered_at: persistence.clock.(),
      writable?: false,
      health: {:unavailable, reason}
    }
  end

  defp snapshot_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_snapshot_limit)
  defp snapshot_limit(_limit), do: @max_snapshot_limit

  defp safe_run_id(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: run_id
  defp safe_run_id(_run_id), do: "unavailable"

  defp persisted_health({:degraded, {:cleanup_failed, _reason}} = health), do: health
  defp persisted_health(_health), do: :healthy

  defp state_freshness(state) do
    last_observed_at =
      state.projection
      |> Projection.members()
      |> Enum.map(& &1.last_observed_at)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

    %{last_observed_at: last_observed_at, recovered_at: state.recovered_at}
  end

  defp health_message(:healthy), do: "current-run membership is healthy"
  defp health_message({:degraded, {:checkpoint_corrupt, _reason}}), do: "current-run membership is degraded: checkpoint is corrupt"

  defp health_message({:degraded, {:journal_corrupt, _line, _reason}}),
    do: "current-run membership is degraded: journal is corrupt"

  defp health_message({:degraded, {:append_failed, _reason}}), do: "current-run membership is degraded: journal append failed"

  defp health_message({:degraded, {:checkpoint_failed, _reason}}),
    do: "current-run membership is degraded: checkpoint write failed"

  defp health_message({:degraded, {:checkpoint_entry_sync_failed, _reason}}),
    do: "current-run membership is degraded: checkpoint directory sync failed"

  defp health_message({:degraded, {:journal_compaction_failed, _reason}}),
    do: "current-run membership is degraded: journal compaction failed"

  defp health_message({:degraded, {:cleanup_failed, _reason}}),
    do: "current-run membership is degraded: obsolete generation cleanup failed"

  defp health_message({:degraded, reason}) when is_binary(reason),
    do: "current-run membership is degraded: #{reason}"

  defp health_message({:degraded, _reason}), do: "current-run membership is degraded"

  defp health_message({:unavailable, {:path_unresolved, _reason}}),
    do: "current-run membership is unavailable: state path cannot be resolved"

  defp health_message({:unavailable, {:prepare_failed, :invalid_run_id}}),
    do: "current-run membership is unavailable: run identity is invalid"

  defp health_message({:unavailable, {:prepare_failed, _reason}}),
    do: "current-run membership is unavailable: recovery storage cannot be prepared"

  defp health_message({:unavailable, {:journal_unreadable, _reason}}),
    do: "current-run membership is unavailable: journal cannot be read"

  defp health_message({:unavailable, {:degraded_marker_failed, _reason}}),
    do: "current-run membership is unavailable: degraded recovery state cannot be recorded"

  defp health_message({:unavailable, {:quarantine_failed, _reason}}),
    do: "current-run membership is unavailable: corrupt recovery data cannot be quarantined"

  defp health_message({:unavailable, reason}) when is_binary(reason), do: "current-run membership is unavailable: #{reason}"
  defp health_message({:unavailable, _reason}), do: "current-run membership is unavailable"

  defp notify(state, event) do
    CurrentRunMembership.broadcast_changed(state.run_id, state.projection.generation, event, state.health)
  rescue
    error -> Logger.warning("aiur_current_run_membership phase=notify_failed error=#{Exception.message(error)}")
  end
end
