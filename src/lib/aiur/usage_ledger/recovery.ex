defmodule Aiur.UsageLedger.Recovery do
  @moduledoc false

  alias Aiur.{Config, DecisionLog, Fs}
  alias Aiur.UsageLedger.{Checkpoint, CounterPolicy, Paths, Record, RetiredFloor}

  @default_limits %{
    max_record_bytes: 32_768,
    max_segment_bytes: 16_777_216,
    max_checkpoint_bytes: 1_048_576,
    max_idempotency_entries: 50_000
  }

  @spec options(keyword()) :: map()
  def options(opts) do
    %{
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      quarantine_fun: Keyword.get(opts, :quarantine_fun, &Paths.quarantine/3),
      degraded_marker_fun: Keyword.get(opts, :degraded_marker_fun, &write_marker/3),
      rewrite_segment_fun: Keyword.get(opts, :rewrite_segment_fun, &rewrite_segment/3),
      checkpoint_write_fun: Keyword.get(opts, :recovery_checkpoint_fun, &write_checkpoint/3),
      limits: Map.merge(@default_limits, Map.new(Keyword.get(opts, :limits, [])))
    }
  end

  @spec state_dir(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> Config.Paths.usage_ledger_state_dir()
    end
  end

  @spec boot(String.t(), map()) :: {:ok, map()}
  def boot(root, persistence) when is_binary(root) and is_map(persistence) do
    case Paths.prepare(root, persistence.sync_fun) do
      {:ok, paths} -> load(paths, persistence)
      {:error, reason} -> {:ok, unavailable_state(reason, persistence)}
    end
  end

  @doc false
  @spec unavailable(term(), map()) :: map()
  def unavailable(reason, persistence) when is_map(persistence),
    do: unavailable_state(reason, persistence)

  defp load(paths, persistence) do
    marker_status = marker_status(paths.degraded_path)

    with {:ok, floor} <- retired_floor(paths.retired_path),
         {:ok, tail_status} <- segment_tail_status(paths.segment_path, persistence.limits.max_segment_bytes),
         {:ok, records, segment_health} <- replay(paths.segment_path, persistence.limits, tail_status),
         {:ok, checkpoint, checkpoint_status} <- checkpoint(paths.checkpoint_path, persistence.limits) do
      if floor == 0 do
        recovery = restore(records, checkpoint, checkpoint_status, segment_health)
        state = recovered_state(paths, records, recovery, marker_status, persistence)

        {:ok,
         finalize_recovery(
           state,
           marker_status,
           recovery.checkpoint_health,
           recovery.segment_health,
           persistence
         )}
      else
        retained = Enum.filter(records, &(&1.position > floor))
        {:ok, restore_retired(paths, retained, floor, checkpoint, checkpoint_status, segment_health, marker_status, persistence)}
      end
    else
      {:error, reason} -> {:ok, unavailable_state(reason, persistence)}
    end
  end

  # A corrupt floor is only ever present once retirement has run, and without a
  # trustworthy watermark the retained tail cannot reconstruct the retired
  # prefix — halt rather than guess. A missing floor means nothing was retired.
  defp retired_floor(path) do
    case RetiredFloor.load(path) do
      :missing -> {:ok, 0}
      {:ok, value} -> {:ok, value}
      {:corrupt, _reason} -> {:error, :retired_floor_corrupt}
    end
  end

  # Once a prefix is retired the raw source for it is gone, so the durable
  # checkpoint — not a full replay — is the authoritative counter state. The
  # retained tail must line up exactly on top of the checkpoint head; anything
  # ambiguous halts (a documented rebuild limit), preserving the last validated
  # queryable state rather than resetting totals.
  defp restore_retired(paths, retained, floor, checkpoint, checkpoint_status, segment_health, marker_status, persistence) do
    cond do
      checkpoint_status != :healthy ->
        %{unavailable_state(:checkpoint_required_after_retirement, persistence) | retired_through: floor}

      segment_health != :healthy ->
        %{unavailable_state(:retired_segment_unhealthy, persistence) | retired_through: floor}

      not contiguous_tail?(retained, floor, checkpoint.position) ->
        %{unavailable_state(:retired_segment_inconsistent, persistence) | retired_through: floor}

      true ->
        %{
          paths: paths,
          records: retained,
          policy: checkpoint.policy,
          position: checkpoint.position,
          generation: checkpoint.generation,
          coverage: checkpoint.policy.coverage,
          health: marker_health(:healthy, marker_status),
          writable?: marker_status == :absent,
          limits: persistence.limits,
          retired_through: floor
        }
    end
  end

  defp contiguous_tail?(records, floor, position) do
    expected = if position > floor, do: Enum.to_list((floor + 1)..position), else: []
    Enum.map(records, & &1.position) == expected
  end

  defp replay(path, limits, tail_status) do
    case DecisionLog.replay(path, &Record.decode/1,
           max_file_bytes: limits.max_segment_bytes,
           max_record_bytes: limits.max_record_bytes,
           repair_torn_tail: false
         ) do
      {:ok, records, nil} -> {:ok, records, tail_status}
      {:ok, records, {:corrupt, _line, _reason}} -> {:ok, records, :corrupt}
      {:error, _reason} -> {:error, :segment_unavailable}
    end
  end

  defp checkpoint(path, limits) do
    case Checkpoint.load(path, max_bytes: limits.max_checkpoint_bytes) do
      :missing -> {:ok, nil, :missing}
      {:ok, checkpoint} -> {:ok, checkpoint, :healthy}
      {:corrupt, _reason} -> {:ok, nil, :corrupt}
    end
  end

  defp restore(records, checkpoint, checkpoint_status, segment_health) do
    case replay_records(records) do
      {:ok, policy, position} ->
        %{
          policy: policy,
          position: position,
          checkpoint_health: checkpoint_health(checkpoint, checkpoint_status, records, policy, position),
          segment_health: segment_health
        }

      {:error, _reason, policy, position} ->
        %{
          policy: policy,
          position: position,
          checkpoint_health: checkpoint_health(checkpoint, checkpoint_status, records, policy, position),
          segment_health: :corrupt
        }
    end
  end

  defp replay_records(records) do
    Enum.reduce_while(records, {:ok, CounterPolicy.new(), 0}, fn record, {:ok, policy, position} ->
      expected_position = position + 1

      if record.position == expected_position do
        replay_record(record, policy, position)
      else
        {:halt, {:error, :invalid_positions, policy, position}}
      end
    end)
  end

  defp replay_record(record, policy, position) do
    case CounterPolicy.apply(policy, record.envelope) do
      {:ok, %{state: next, delta: delta}} ->
        if Record.matches_delta?(record, delta),
          do: {:cont, {:ok, next, position + 1}},
          else: {:halt, {:error, :record_delta_mismatch, policy, position}}

      {:duplicate, _state} ->
        {:halt, {:error, :duplicate_canonical_record, policy, position}}

      {:error, reason, _state} ->
        {:halt, {:error, reason, policy, position}}
    end
  end

  defp checkpoint_health(nil, :missing, _records, _policy, _position), do: :missing
  defp checkpoint_health(nil, :corrupt, _records, _policy, _position), do: :corrupt

  defp checkpoint_health(checkpoint, :healthy, records, _policy, position) do
    with true <- checkpoint.position <= position,
         true <- checkpoint.generation == checkpoint.position,
         {:ok, prefix_policy, checkpoint_position} <-
           records |> Enum.take(checkpoint.position) |> replay_records(),
         true <- checkpoint_position == checkpoint.position,
         true <- CounterPolicy.dump(checkpoint.policy) == CounterPolicy.dump(prefix_policy) do
      :healthy
    else
      _ -> :corrupt
    end
  end

  defp recovered_state(paths, records, recovery, marker_status, persistence) do
    health = marker_health(storage_health(recovery.checkpoint_health, recovery.segment_health), marker_status)

    %{
      paths: paths,
      records: Enum.take(records, recovery.position),
      policy: recovery.policy,
      position: recovery.position,
      generation: recovery.position,
      coverage: recovery.policy.coverage,
      health: health,
      writable?:
        recovery.checkpoint_health in [:healthy, :missing] and
          recovery.segment_health == :healthy and marker_status == :absent,
      limits: persistence.limits,
      retired_through: 0
    }
  end

  defp storage_health(:corrupt, segment_health) when segment_health in [:corrupt, :torn],
    do: {:degraded, :storage_corrupt}

  defp storage_health(:corrupt, :healthy), do: {:degraded, :checkpoint_corrupt}
  defp storage_health(_checkpoint_health, :corrupt), do: {:degraded, :segment_corrupt}
  defp storage_health(_checkpoint_health, :torn), do: {:degraded, :segment_torn}
  defp storage_health(_checkpoint_health, :healthy), do: :healthy

  defp marker_health(health, :absent), do: health
  defp marker_health(_health, {:degraded, reason}), do: {:degraded, reason}
  defp marker_health(_health, {:unavailable, reason}), do: {:unavailable, reason}

  defp finalize_recovery(state, {:unavailable, _reason}, _checkpoint_health, _segment_health, _persistence),
    do: %{state | writable?: false}

  defp finalize_recovery(state, marker_status, checkpoint_health, segment_health, persistence) do
    cond do
      checkpoint_health == :corrupt or segment_health in [:corrupt, :torn] ->
        repair_storage(state, marker_status, checkpoint_health, segment_health, persistence)

      checkpoint_health == :missing ->
        rebuild_missing_checkpoint(state, persistence)

      true ->
        state
    end
  end

  defp rebuild_missing_checkpoint(state, persistence) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <-
           stage(
             :checkpoint_rebuild,
             persistence.checkpoint_write_fun,
             [state.paths.checkpoint_path, checkpoint, state.limits.max_checkpoint_bytes]
           ),
         :ok <- stage(:checkpoint_rebuild_sync, persistence.sync_fun, []) do
      state
    else
      {:error, _stage, _reason} ->
        %{state | health: {:unavailable, :checkpoint_rebuild_failed}, writable?: false}
    end
  end

  defp repair_storage(state, marker_status, checkpoint_health, segment_health, persistence) do
    reason = repair_reason(checkpoint_health, segment_health)

    with :ok <- ensure_marker(state.paths.degraded_path, marker_status, reason, persistence),
         :ok <- quarantine_artifacts(state, checkpoint_health, segment_health, persistence),
         :ok <- rewrite_artifacts(state, segment_health, persistence) do
      %{state | health: marker_health({:degraded, reason}, marker_status), writable?: false}
    else
      {:error, :marker, _reason} ->
        %{state | health: {:unavailable, :degraded_marker_failed}, writable?: false}

      {:error, stage, _reason} when stage in [:segment_quarantine, :checkpoint_quarantine] ->
        %{state | health: {:unavailable, :quarantine_failed}, writable?: false}

      {:error, _stage, _reason} ->
        %{state | health: {:unavailable, :repair_failed}, writable?: false}
    end
  end

  defp repair_reason(:corrupt, segment_health) when segment_health in [:corrupt, :torn],
    do: :storage_corrupt

  defp repair_reason(:corrupt, :healthy), do: :checkpoint_corrupt
  defp repair_reason(_checkpoint_health, :corrupt), do: :segment_corrupt
  defp repair_reason(_checkpoint_health, :torn), do: :segment_torn

  defp ensure_marker(_path, {:degraded, _reason}, _repair_reason, _persistence), do: :ok

  defp ensure_marker(path, :absent, repair_reason, persistence) do
    stage(:marker, persistence.degraded_marker_fun, [path, repair_reason, persistence.sync_fun])
  end

  defp quarantine_artifacts(state, checkpoint_health, segment_health, persistence) do
    with :ok <- maybe_quarantine_segment(state, segment_health, persistence) do
      maybe_quarantine_checkpoint(state, checkpoint_health, persistence)
    end
  end

  defp maybe_quarantine_segment(_state, :healthy, _persistence), do: :ok

  defp maybe_quarantine_segment(state, segment_health, persistence)
       when segment_health in [:corrupt, :torn] do
    stage(
      :segment_quarantine,
      persistence.quarantine_fun,
      [state.paths.segment_path, state.paths.quarantine_dir, persistence.sync_fun]
    )
  end

  defp maybe_quarantine_checkpoint(_state, checkpoint_health, _persistence)
       when checkpoint_health in [:healthy, :missing],
       do: :ok

  defp maybe_quarantine_checkpoint(state, :corrupt, persistence) do
    stage(
      :checkpoint_quarantine,
      persistence.quarantine_fun,
      [state.paths.checkpoint_path, state.paths.quarantine_dir, persistence.sync_fun]
    )
  end

  defp rewrite_artifacts(state, segment_health, persistence) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <- maybe_rewrite_segment(state, segment_health, persistence),
         :ok <-
           stage(
             :checkpoint_rewrite,
             persistence.checkpoint_write_fun,
             [state.paths.checkpoint_path, checkpoint, state.limits.max_checkpoint_bytes]
           ) do
      stage(:repair_sync, persistence.sync_fun, [])
    end
  end

  defp maybe_rewrite_segment(_state, :healthy, _persistence), do: :ok

  defp maybe_rewrite_segment(state, segment_health, persistence)
       when segment_health in [:corrupt, :torn] do
    stage(
      :segment_rewrite,
      persistence.rewrite_segment_fun,
      [state.paths.segment_path, state.records, persistence.sync_fun]
    )
  end

  defp stage(stage, fun, arguments) do
    case apply(fun, arguments) do
      :ok -> :ok
      {:error, reason} -> {:error, stage, reason}
      other -> {:error, stage, {:unexpected_result, other}}
    end
  rescue
    error -> {:error, stage, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, stage, {kind, reason}}
  end

  defp marker_status(path) do
    case marker(path) do
      {:ok, status} -> status
      {:error, reason} -> {:unavailable, reason}
    end
  end

  defp marker(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, :absent}
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 1_024 -> read_marker(path)
      {:ok, _stat} -> {:error, :marker_invalid}
      {:error, _reason} -> {:error, :marker_invalid}
    end
  end

  defp read_marker(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "reason" => reason}} <- Jason.decode(contents),
         true <- reason in ["checkpoint_corrupt", "segment_corrupt", "segment_torn", "storage_corrupt"] do
      {:ok, {:degraded, String.to_existing_atom(reason)}}
    else
      _ -> {:error, :marker_invalid}
    end
  end

  defp write_marker(path, reason, sync_fun)
       when reason in [:checkpoint_corrupt, :segment_corrupt, :segment_torn, :storage_corrupt] do
    contents = Jason.encode!(%{"version" => 1, "reason" => Atom.to_string(reason)})

    with :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
      sync_fun.()
    end
  end

  defp write_checkpoint(path, checkpoint, max_bytes),
    do: Checkpoint.write(path, checkpoint, max_bytes: max_bytes)

  defp rewrite_segment(path, records, sync_fun) do
    contents = records |> Enum.map(&(Jason.encode!(Record.encode(&1)) <> "\n")) |> IO.iodata_to_binary()

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600),
         :ok <- sync_fun.() do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp segment_tail_status(path, max_bytes) do
    case tail_status(path, max_bytes) do
      status when status in [:healthy, :torn] -> {:ok, status}
      {:error, _reason} -> {:error, :segment_unavailable}
    end
  end

  defp tail_status(path, max_bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :healthy

      {:ok, %File.Stat{type: :regular, size: 0}} ->
        :healthy

      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        read_tail_status(path)

      {:ok, _stat} ->
        {:error, :unreadable}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp read_tail_status(path) do
    case File.read(path) do
      {:ok, contents} -> if(:binary.last(contents) == ?\n, do: :healthy, else: :torn)
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp unavailable_state(reason, persistence) do
    %{
      paths: nil,
      records: [],
      policy: CounterPolicy.new(),
      position: 0,
      generation: 0,
      coverage: %{lower: nil, upper: nil, status: :empty},
      health: {:unavailable, safe_reason(reason)},
      writable?: false,
      limits: persistence.limits,
      retired_through: 0
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :storage_unavailable
end
