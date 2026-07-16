defmodule Aiur.UsageLedger.Recovery do
  @moduledoc false

  alias Aiur.{Config, DecisionLog, Fs}
  alias Aiur.UsageLedger.{Checkpoint, CounterPolicy, Paths, Record}

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
    with {:ok, paths} <- Paths.prepare(root, persistence.sync_fun),
         {:ok, marker} <- marker(paths.degraded_path),
         {:ok, tail_status} <- preserve_torn_tail(paths, persistence),
         {:ok, records, segment_health} <- replay(paths.segment_path, persistence.limits, tail_status),
         {:ok, checkpoint, checkpoint_status} <- checkpoint(paths.checkpoint_path, persistence.limits),
         {:ok, policy, position, generation, checkpoint_health} <- restore(records, checkpoint, checkpoint_status) do
      state = %{
        paths: paths,
        records: records,
        policy: policy,
        position: position,
        generation: generation,
        coverage: policy.coverage,
        health: marker_health(health(checkpoint_health, segment_health), marker),
        writable?: checkpoint_health == :healthy and segment_health == :healthy and marker == :absent,
        limits: persistence.limits
      }

      state
      |> rebuild_missing_checkpoint(checkpoint, checkpoint_status, segment_health, marker, persistence)
      |> maybe_quarantine(checkpoint_health, segment_health, persistence)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:ok, unavailable_state(reason, persistence)}
    end
  end

  defp replay(path, limits, tail_status) do
    case DecisionLog.replay(path, &Record.decode/1,
           max_file_bytes: limits.max_segment_bytes,
           max_record_bytes: limits.max_record_bytes
         ) do
      {:ok, records, nil} -> {:ok, records, tail_status}
      {:ok, records, {:corrupt, _line, _reason}} -> {:ok, records, :corrupt}
      {:error, _reason} -> {:error, :segment_unavailable}
    end
  end

  defp checkpoint(path, limits) do
    case Checkpoint.load(path, max_bytes: limits.max_checkpoint_bytes) do
      :missing -> {:ok, nil, :healthy}
      {:ok, checkpoint} -> {:ok, checkpoint, :healthy}
      {:corrupt, _reason} -> {:ok, nil, :corrupt}
    end
  end

  defp restore(records, checkpoint, checkpoint_status) do
    with :ok <- consecutive_positions(records), do: restore_checkpoint(records, checkpoint, checkpoint_status)
  end

  defp restore_checkpoint(records, nil, :healthy), do: rebuild(records, :healthy)

  defp restore_checkpoint(records, nil, :corrupt), do: rebuild(records, :corrupt)

  defp restore_checkpoint(records, checkpoint, :healthy) do
    # A checkpoint proves the writer's acknowledged counter state, but raw
    # records remain the replay authority. Validate the prefix semantically
    # before trusting that checkpoint, then seed it to replay only the suffix.
    # This detects a checksum-valid record whose stored delta was forged.
    with true <- checkpoint.position <= length(records),
         true <- checkpoint.generation == checkpoint.position,
         {:ok, prefix_policy} <- replay_suffix(Enum.take(records, checkpoint.position), 0, CounterPolicy.new()),
         true <- CounterPolicy.dump(prefix_policy) == CounterPolicy.dump(checkpoint.policy),
         {:ok, policy} <- replay_suffix(records, checkpoint.position, checkpoint.policy) do
      {:ok, policy, length(records), length(records), :healthy}
    else
      _ -> rebuild(records, :corrupt)
    end
  end

  defp rebuild(records, health) do
    with {:ok, policy} <- replay_suffix(records, 0, CounterPolicy.new()) do
      {:ok, policy, length(records), length(records), health}
    end
  end

  defp replay_suffix(records, position, policy) do
    records
    |> Enum.drop(position)
    |> Enum.reduce_while({:ok, policy}, fn record, {:ok, current} ->
      replay_record(record, current)
    end)
  end

  defp replay_record(record, policy) do
    case CounterPolicy.apply(policy, record.envelope) do
      {:ok, %{state: next, delta: delta}} -> replay_delta(record, next, delta)
      {:duplicate, _state} -> {:halt, {:error, :duplicate_canonical_record}}
      {:error, reason, _state} -> {:halt, {:error, reason}}
    end
  end

  defp replay_delta(record, policy, delta) do
    if Record.matches_delta?(record, delta),
      do: {:cont, {:ok, policy}},
      else: {:halt, {:error, :record_delta_mismatch}}
  end

  defp consecutive_positions(records) do
    if Enum.all?(Enum.with_index(records, 1), fn {record, position} -> record.position == position end),
      do: :ok,
      else: {:error, :invalid_positions}
  end

  defp health(:healthy, :healthy), do: :healthy
  defp health(:corrupt, :healthy), do: {:degraded, :checkpoint_corrupt}
  defp health(:healthy, :corrupt), do: {:degraded, :segment_corrupt}
  defp health(:healthy, :torn), do: {:degraded, :segment_torn}
  defp health(:corrupt, :corrupt), do: {:degraded, :storage_corrupt}
  defp health(:corrupt, :torn), do: {:degraded, :storage_corrupt}

  defp marker_health(health, :absent), do: health
  defp marker_health(_health, {:degraded, reason}), do: {:degraded, reason}

  defp maybe_quarantine(state, checkpoint_health, segment_health, persistence) do
    case {checkpoint_health, segment_health} do
      {:corrupt, _} -> repair_checkpoint(state, persistence)
      {_, :corrupt} -> repair_segment(state, persistence, :segment_corrupt)
      {_, :torn} -> repair_torn_segment(state, persistence)
      _ -> state
    end
  end

  defp rebuild_missing_checkpoint(state, nil, :healthy, :healthy, :absent, persistence) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <- Checkpoint.write(state.paths.checkpoint_path, checkpoint, max_bytes: state.limits.max_checkpoint_bytes),
         :ok <- persistence.sync_fun.() do
      state
    else
      _ -> %{state | health: {:unavailable, :checkpoint_rebuild_failed}, writable?: false}
    end
  end

  defp rebuild_missing_checkpoint(state, _checkpoint, _checkpoint_status, _segment_health, _marker, _persistence), do: state

  defp repair_checkpoint(state, persistence) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <- persistence.quarantine_fun.(state.paths.checkpoint_path, state.paths.quarantine_dir, persistence.sync_fun),
         :ok <- Checkpoint.write(state.paths.checkpoint_path, checkpoint, max_bytes: state.limits.max_checkpoint_bytes),
         :ok <- write_marker(state.paths.degraded_path, :checkpoint_corrupt),
         :ok <- persistence.sync_fun.() do
      %{state | writable?: false}
    else
      _ -> %{state | health: {:unavailable, :quarantine_failed}, writable?: false}
    end
  end

  defp repair_segment(state, persistence, reason) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <- Checkpoint.write(state.paths.checkpoint_path, checkpoint, max_bytes: state.limits.max_checkpoint_bytes),
         :ok <- persistence.sync_fun.(),
         :ok <- persistence.quarantine_fun.(state.paths.segment_path, state.paths.quarantine_dir, persistence.sync_fun),
         :ok <- rewrite_segment(state.paths.segment_path, state.records, persistence.sync_fun),
         :ok <- write_marker(state.paths.degraded_path, reason) do
      %{state | writable?: false}
    else
      _ -> %{state | health: {:unavailable, :quarantine_failed}, writable?: false}
    end
  end

  defp repair_torn_segment(state, persistence) do
    checkpoint = Checkpoint.record(state.position, state.generation, state.policy)

    with :ok <- Checkpoint.write(state.paths.checkpoint_path, checkpoint, max_bytes: state.limits.max_checkpoint_bytes),
         :ok <- write_marker(state.paths.degraded_path, :segment_torn),
         :ok <- persistence.sync_fun.() do
      %{state | writable?: false}
    else
      _ -> %{state | health: {:unavailable, :quarantine_failed}, writable?: false}
    end
  end

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

  defp write_marker(path, reason) when reason in [:checkpoint_corrupt, :segment_corrupt, :segment_torn, :storage_corrupt] do
    Fs.atomic_write(path, Jason.encode!(%{"version" => 1, "reason" => Atom.to_string(reason)}), fsync: true, mode: 0o600)
  end

  defp preserve_torn_tail(paths, persistence) do
    case tail_status(paths.segment_path, persistence.limits.max_segment_bytes) do
      :healthy ->
        {:ok, :healthy}

      :torn ->
        with :ok <- persistence.quarantine_fun.(paths.segment_path, paths.quarantine_dir, persistence.sync_fun) do
          {:ok, :torn}
        end

      {:error, _reason} ->
        {:error, :segment_unavailable}
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
      limits: persistence.limits
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :storage_unavailable
end
