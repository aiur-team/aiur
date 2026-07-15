defmodule Aiur.CurrentRunMembership.Store.Recovery do
  @moduledoc false

  alias Aiur.{Config, DecisionLog, Fs}
  alias Aiur.CurrentRunMembership.{Event, Event.Codec, Projection}
  alias Aiur.CurrentRunMembership.Store.{Checkpoint, FileOps, Marker, Paths, Runtime, TerminalVerification}

  @checkpoint_interval 32

  @spec options(keyword()) :: map()
  def options(opts) do
    %{
      append_fun: Keyword.get(opts, :append_fun, &DecisionLog.append/2),
      checkpoint_fun: Keyword.get(opts, :checkpoint_fun, &FileOps.write_checkpoint/2),
      clear_journal_fun: Keyword.get(opts, :clear_journal_fun, &FileOps.clear_journal/1),
      checkpoint_interval: checkpoint_interval(Keyword.get(opts, :checkpoint_interval, @checkpoint_interval)),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      degraded_marker_fun: Keyword.get(opts, :degraded_marker_fun, &Marker.write/4),
      terminal_verification_marker_fun: Keyword.get(opts, :terminal_verification_marker_fun, &TerminalVerification.write/4),
      quarantine_fun: Keyword.get(opts, :quarantine_fun, &FileOps.quarantine/1),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      cleanup_fun: Keyword.get(opts, :cleanup_fun, &Paths.cleanup_obsolete_runs/2)
    }
  end

  @spec state_dir(keyword()) :: {:ok, String.t()} | {:error, term()}
  def state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Config.Paths.current_run_membership_state_dir()
    end
  end

  @spec boot(String.t(), term(), map()) :: map()
  def boot(root, run_id, persistence) do
    with :ok <- Paths.valid_run_id(run_id),
         {:ok, paths} <- Paths.prepare(root, run_id, persistence.sync_fun) do
      load(paths, run_id, persistence)
    else
      {:error, reason} -> unavailable_state(run_id, persistence, {:prepare_failed, reason})
    end
  end

  @spec unavailable_state(term(), map(), term()) :: map()
  def unavailable_state(run_id, persistence, reason) do
    safe_run_id = safe_run_id(run_id)

    %{
      run_id: safe_run_id,
      projection: Projection.new(safe_run_id),
      append_fun: persistence.append_fun,
      checkpoint_fun: persistence.checkpoint_fun,
      clear_journal_fun: persistence.clear_journal_fun,
      checkpoint_interval: persistence.checkpoint_interval,
      journal_event_count: 0,
      sync_fun: persistence.sync_fun,
      degraded_marker_fun: persistence.degraded_marker_fun,
      terminal_verification_marker_fun: persistence.terminal_verification_marker_fun,
      quarantine_fun: persistence.quarantine_fun,
      cleanup_fun: persistence.cleanup_fun,
      clock: persistence.clock,
      recovered_at: persistence.clock.(),
      reconciliation: %{status: :unavailable, reconciled_at: nil},
      terminal_verification_marker_dirty?: false,
      terminal_verification_pending?: false,
      terminal_verification_pending_keys: MapSet.new(),
      terminal_verification_path: nil,
      writable?: false,
      health: Runtime.public_health({:unavailable, reason})
    }
  end

  defp load(paths, run_id, persistence) do
    checkpoint = Checkpoint.load(paths.checkpoint_path, run_id)
    marker = Marker.load(paths.degraded_path, run_id)
    terminal_verification = TerminalVerification.load(paths.terminal_verification_path, run_id)
    {projection, checkpoint_health, writable?} = checkpoint_projection(checkpoint, run_id)

    {projection, journal_health, journal_writable?, journal_event_count} =
      replay_journal(paths.journal_path, run_id, projection)

    health = boot_health(marker, checkpoint_health, journal_health, terminal_verification)
    pending_keys = terminal_verification_pending_keys(terminal_verification)

    state = %{
      run_id: run_id,
      projection: projection,
      root: paths.root,
      runs_dir: paths.runs_dir,
      run_leaf: paths.run_leaf,
      journal_path: paths.journal_path,
      checkpoint_path: paths.checkpoint_path,
      degraded_path: paths.degraded_path,
      terminal_verification_path: paths.terminal_verification_path,
      append_fun: persistence.append_fun,
      checkpoint_fun: persistence.checkpoint_fun,
      clear_journal_fun: persistence.clear_journal_fun,
      checkpoint_interval: persistence.checkpoint_interval,
      journal_event_count: journal_event_count,
      sync_fun: persistence.sync_fun,
      degraded_marker_fun: persistence.degraded_marker_fun,
      terminal_verification_marker_fun: persistence.terminal_verification_marker_fun,
      quarantine_fun: persistence.quarantine_fun,
      cleanup_fun: persistence.cleanup_fun,
      clock: persistence.clock,
      recovered_at: persistence.clock.(),
      reconciliation: Runtime.initial_reconciliation(projection),
      terminal_verification_marker_dirty?: false,
      terminal_verification_pending?: terminal_verification_pending?(terminal_verification),
      terminal_verification_pending_keys: pending_keys,
      writable?:
        writable? and journal_writable? and marker == :absent and
          match?({:ok, _pending_keys, _pending?}, terminal_verification),
      health: Runtime.public_health(health)
    }

    state = maybe_quarantine_recovery_artifacts(state, checkpoint, journal_health)

    if state.health == :healthy do
      case state.cleanup_fun.(state.runs_dir, state.run_leaf) do
        :ok ->
          state

        {:error, reason} ->
          %{state | health: Runtime.public_health({:degraded, {:cleanup_failed, reason}})}
      end
    else
      state
    end
  end

  defp checkpoint_projection(:missing, run_id), do: {Projection.new(run_id), :healthy, true}
  defp checkpoint_projection({:ok, projection}, _run_id), do: {projection, :healthy, true}
  defp checkpoint_projection({:corrupt, reason}, run_id), do: {Projection.new(run_id), {:degraded, {:checkpoint_corrupt, reason}}, false}

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

    case DecisionLog.replay(path, validator,
           max_file_bytes: Codec.max_journal_bytes(),
           max_record_bytes: Codec.max_recovery_record_bytes()
         ) do
      {:ok, events, nil} ->
        {replay_events(projection, events), :healthy, true, length(events)}

      {:ok, events, {:corrupt, line, reason}} ->
        {replay_events(projection, events), {:degraded, {:journal_corrupt, line, reason}}, false, length(events)}

      {:error, reason} ->
        {projection, {:unavailable, {:journal_unreadable, reason}}, false, 0}
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

  defp terminal_verification_pending_keys({:ok, pending_keys, _pending?}), do: pending_keys
  defp terminal_verification_pending_keys({:error, _reason}), do: MapSet.new()

  defp terminal_verification_pending?({:ok, _pending_keys, pending?}), do: pending?
  defp terminal_verification_pending?({:error, _reason}), do: false

  defp boot_health(_marker, _checkpoint_health, _journal_health, {:error, reason}),
    do: {:unavailable, reason}

  defp boot_health(:absent, :healthy, :healthy, _terminal_verification), do: :healthy
  defp boot_health({:degraded, reason}, _checkpoint_health, _journal_health, _terminal_verification), do: {:degraded, reason}
  defp boot_health({:unavailable, reason}, _checkpoint_health, _journal_health, _terminal_verification), do: {:unavailable, reason}
  defp boot_health(:absent, {:degraded, reason}, _journal_health, _terminal_verification), do: {:degraded, reason}
  defp boot_health(:absent, :healthy, {:unavailable, reason}, _terminal_verification), do: {:unavailable, reason}
  defp boot_health(:absent, :healthy, {:degraded, reason}, _terminal_verification), do: {:degraded, reason}

  defp maybe_quarantine_recovery_artifacts(state, {:corrupt, reason}, _journal_health) do
    degrade_and_quarantine(state, state.checkpoint_path, {:checkpoint_corrupt, reason})
  end

  defp maybe_quarantine_recovery_artifacts(
         state,
         _checkpoint,
         {:degraded, {:journal_corrupt, _line, _reason}} = health
       ) do
    case checkpoint_validated_journal_prefix(state) do
      :ok ->
        degrade_and_quarantine(state, state.journal_path, elem(health, 1))

      {:error, reason} ->
        %{
          state
          | health: Runtime.public_health({:unavailable, {:journal_prefix_checkpoint_failed, reason}}),
            writable?: false
        }
    end
  end

  defp maybe_quarantine_recovery_artifacts(state, _checkpoint, _journal_health), do: state

  defp checkpoint_validated_journal_prefix(state) do
    checkpoint = Checkpoint.record(state.projection)

    with :ok <- Codec.validate_checkpoint_record_size(checkpoint),
         :ok <- state.checkpoint_fun.(state.checkpoint_path, checkpoint),
         :ok <- FileOps.ensure_regular_file(state.checkpoint_path),
         :ok <- FileOps.sync_recovery_entry(state.sync_fun) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, stage, reason} -> {:error, {stage, reason}}
    end
  end

  defp degrade_and_quarantine(state, path, reason) do
    case state.degraded_marker_fun.(state.degraded_path, state.run_id, reason, state.sync_fun) do
      :ok ->
        case state.quarantine_fun.(path) do
          :ok ->
            %{state | health: Runtime.public_health({:degraded, reason}), writable?: false}

          {:error, quarantine_reason} ->
            %{
              state
              | health: Runtime.public_health({:unavailable, {:quarantine_failed, quarantine_reason}}),
                writable?: false
            }
        end

      {:error, marker_reason} ->
        %{
          state
          | health: Runtime.public_health({:unavailable, {:degraded_marker_failed, marker_reason}}),
            writable?: false
        }
    end
  end

  defp checkpoint_interval(interval) when is_integer(interval) and interval > 0, do: interval
  defp checkpoint_interval(_interval), do: @checkpoint_interval
  defp safe_run_id(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: run_id
  defp safe_run_id(_run_id), do: "unavailable"
end
