defmodule Aiur.UsageCompaction.Coordinator do
  @moduledoc false

  # The one supervised owner of the destructive storage seam. On a periodic tick
  # (and on demand for tests/ops) it asks the retention policy which raw prefix
  # is eligible, commits durable dimension-preserving aggregate coverage for it
  # as a compacted block, and only then retires the raw source — driving the
  # manifest state machine so every transition is crash-recoverable.
  #
  # The destructive cycle, in order:
  #
  #   1. scan the eligible raw range and fold it into a block (same DASH-024 codec)
  #   2. manifest -> prepared          (intent; block not yet durable)
  #   3. write the block durably        (atomic rename + fsync + checksum)
  #   4. manifest -> aggregate_committed (durable coverage exists; raw intact)
  #   5. manifest -> source_retired      (commit to deletion; the point of no return)
  #   6. retire the raw via the ledger   (idempotent)
  #   7. manifest -> finalized           (block joins the cover; watermark advances)
  #
  # A crash before step 5 rolls back on boot (raw intact, nothing lost); a crash
  # at or after step 5 rolls forward (raw gone, re-run the idempotent retire and
  # finalize). A corrupt manifest is quarantined and destructive progress halts
  # until it is reconciled, preserving the last validated queryable state.

  use GenServer

  require Logger

  alias Aiur.{Config, Fs, UsageLedger}
  alias Aiur.UsageCompaction.{Block, Manifest, Paths, Policy}

  @default_interval_ms 5 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one compaction cycle synchronously and returns its summary. For tests/ops."
  @spec compact(GenServer.server()) :: map()
  def compact(server \\ __MODULE__), do: GenServer.call(server, :compact)

  @doc "Bounded retention policy, coverage, and health facts."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    persistence = persistence(opts)
    policy = Keyword.get(opts, :policy, Policy.new(Keyword.get(opts, :policy_opts, [])))

    state =
      case state_dir(opts) do
        {:ok, root} -> boot(root, policy, persistence, opts)
        {:error, reason} -> unavailable(policy, persistence, opts, reason)
      end

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    next = run_cycle(state)
    {:reply, cycle_summary(next), next}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_payload(state), state}

  @impl true
  def handle_info(:tick, state) do
    next = run_cycle(state)
    {:noreply, schedule(next)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- boot + reconcile ---------------------------------------------------

  defp boot(root, policy, persistence, opts) do
    case Paths.prepare(root, persistence.sync_fun) do
      {:ok, paths} ->
        base = new_state(paths, policy, persistence, opts)
        reconcile(base)

      {:error, reason} ->
        unavailable(policy, persistence, opts, reason)
    end
  end

  defp new_state(paths, policy, persistence, opts) do
    %{
      paths: paths,
      policy: policy,
      manifest: Manifest.new(Policy.describe(policy)),
      health: :ok,
      persistence: persistence,
      ledger_scan_fun: Keyword.get(opts, :ledger_scan_fun, &UsageLedger.scan/1),
      ledger_generation_fun: Keyword.get(opts, :ledger_generation_fun, &UsageLedger.generation/0),
      ledger_retire_fun: Keyword.get(opts, :ledger_retire_fun, &UsageLedger.retire/1),
      raw_bytes_fun: Keyword.get(opts, :raw_bytes_fun, fn -> 0 end),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      last_cycle: :none
    }
  end

  defp reconcile(state) do
    case Manifest.load(state.paths.manifest_path) do
      :missing ->
        %{state | manifest: Manifest.put_policy(Manifest.new(), Policy.describe(state.policy))}

      {:ok, manifest} ->
        reconcile_pending(%{state | manifest: Manifest.put_policy(manifest, Policy.describe(state.policy))})

      {:corrupt, reason} ->
        _ = quarantine(state, state.paths.manifest_path, reason)
        %{state | health: {:quarantined, reason}}
    end
  end

  # A crash left an in-flight destructive phase; resolve it before any new work.
  defp reconcile_pending(state) do
    case Manifest.pending(state.manifest) do
      nil ->
        state

      %{phase: phase} = pending when phase in [:prepared, :aggregate_committed] ->
        # Raw is still intact for this range, so abandoning it loses nothing.
        _ = File.rm(Paths.block_path(state.paths.root, pending.ref))
        persist_manifest(state, Manifest.rollback(state.manifest))

      %{phase: :source_retired} = pending ->
        # Raw is gone or going; only re-running the idempotent retire and
        # finalizing yields a valid state.
        roll_forward(state, pending)
    end
  end

  defp roll_forward(state, pending) do
    case safe(fn -> state.ledger_retire_fun.(pending.last_position) end) do
      {:ok, {:ok, _retirement}} ->
        case Manifest.finalize(state.manifest) do
          {:ok, finalized} -> persist_manifest(state, finalized)
          {:error, reason} -> halt(state, reason)
        end

      _retire_failed ->
        halt(state, :retire_incomplete)
    end
  end

  # --- destructive cycle --------------------------------------------------

  defp run_cycle(%{health: health} = state) when health != :ok, do: %{state | last_cycle: {:skipped, health}}

  defp run_cycle(state) do
    facts = %{
      latest_position: safe_int(state.ledger_generation_fun),
      retired_through: state.manifest.retired_through,
      raw_bytes: safe_int(state.raw_bytes_fun)
    }

    case Policy.eligible_range(state.policy, facts) do
      :noop -> %{state | last_cycle: :noop}
      {:retire, first, last} -> compact_range(state, first, last)
    end
  end

  # State is threaded explicitly (not via `with`) so a failure at any step sees
  # exactly how far the durable manifest advanced and rolls back or forward
  # accordingly.
  defp compact_range(state, first, last) do
    ref = Paths.block_ref(first, last)

    case build_block(state, first, last) do
      {:ok, block} -> open_phase(state, first, last, ref, block)
      {:error, reason} -> %{state | last_cycle: {:aborted, reason}}
    end
  end

  defp build_block(state, first, last) do
    case scan_range(state, first, last) do
      {:ok, records} -> Block.build(records)
      {:error, reason} -> {:error, reason}
    end
  end

  # Declare intent, then make the block durable and record the coverage — all
  # before any raw is touched, so any failure here is a clean rollback.
  defp open_phase(state, first, last, ref, block) do
    with {:ok, prepared} <- Manifest.prepare(state.manifest, first, last, ref, block.source_generation),
         state = %{state | manifest: prepared},
         :ok <- persist_manifest_write(state),
         :ok <- write_block(state, ref, block),
         {:ok, committed} <- Manifest.advance(state.manifest, :aggregate_committed),
         state = %{state | manifest: committed},
         :ok <- persist_manifest_write(state),
         {:ok, retiring} <- Manifest.advance(state.manifest, :source_retired),
         state = %{state | manifest: retiring},
         :ok <- persist_manifest_write(state) do
      retire_and_finalize(state, first, last, ref)
    else
      {:error, reason} -> roll_back(state, ref, reason)
    end
  end

  # Raw is still fully intact up to the `source_retired` write, so abandoning the
  # in-flight range and deleting the (possibly-written) block loses nothing.
  defp roll_back(state, ref, reason) do
    _ = File.rm(Paths.block_path(state.paths.root, ref))
    rolled = persist_manifest(state, Manifest.rollback(state.manifest))
    %{rolled | last_cycle: {:aborted, reason}}
  end

  # Past the point of no return: retire the raw (idempotent) and finalize. A
  # failure here halts loudly; the boot reconciler rolls the durable
  # `source_retired` manifest forward on the next start.
  defp retire_and_finalize(state, first, last, _ref) do
    with :ok <- retire_source(state, last),
         {:ok, finalized} <- Manifest.finalize(state.manifest) do
      state = persist_manifest(state, finalized)
      %{state | last_cycle: {:compacted, first, last}}
    else
      {:error, reason} -> halt(%{state | last_cycle: {:aborted, reason}}, reason)
    end
  end

  defp scan_range(state, first, last) do
    limit = last - first + 1

    case safe(fn -> state.ledger_scan_fun.(after: first - 1, limit: limit) end) do
      {:ok, {:ok, records}} ->
        selected = records |> Enum.filter(&(&1.position >= first and &1.position <= last)) |> Enum.sort_by(& &1.position)
        if length(selected) == limit, do: {:ok, selected}, else: {:error, :incomplete_scan}

      _other ->
        {:error, :source_unavailable}
    end
  end

  defp write_block(state, ref, block) do
    case Block.write(Paths.block_path(state.paths.root, ref), block) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retire_source(state, last) do
    case safe(fn -> state.ledger_retire_fun.(last) end) do
      {:ok, {:ok, _retirement}} -> :ok
      _other -> {:error, :retire_failed}
    end
  end

  # --- persistence + health ----------------------------------------------

  defp persist_manifest(state, manifest) do
    case Manifest.write(state.paths.manifest_path, manifest) do
      :ok -> %{state | manifest: manifest}
      {:error, reason} -> halt(%{state | manifest: manifest}, reason)
    end
  end

  defp persist_manifest_write(state) do
    Manifest.write(state.paths.manifest_path, state.manifest)
  end

  defp halt(state, reason) do
    Logger.warning("aiur_usage_compaction phase=halt reason=#{inspect(reason)}")
    %{state | health: {:degraded, reason}}
  end

  defp quarantine(state, path, _reason) do
    with {:ok, contents} <- File.read(path),
         :ok <- File.mkdir_p(state.paths.quarantine_dir) do
      digest = :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
      destination = Path.join(state.paths.quarantine_dir, "#{Path.basename(path)}.sha256-#{digest}.quarantine")

      with :ok <- Fs.atomic_write(destination, contents, fsync: true, mode: 0o600) do
        File.rm(path)
      end
    end
  end

  # --- reporting ----------------------------------------------------------

  defp snapshot_payload(state) do
    blocks = Manifest.blocks(state.manifest)

    %{
      health: state.health,
      retention_policy: Policy.describe(state.policy),
      retired_through: state.manifest.retired_through,
      block_count: length(blocks),
      coverage: coverage(blocks),
      generation: length(blocks),
      last_cycle: state.last_cycle
    }
  end

  defp cycle_summary(state), do: %{status: state.last_cycle, health: state.health, retired_through: state.manifest.retired_through}

  defp coverage([]), do: %{first_position: nil, last_position: nil}

  defp coverage(blocks) do
    %{
      first_position: blocks |> List.first() |> Map.get(:first_position),
      last_position: blocks |> List.last() |> Map.get(:last_position)
    }
  end

  # --- helpers ------------------------------------------------------------

  defp persistence(opts) do
    %{sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0)}
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> Config.Paths.usage_compaction_state_dir()
    end
  end

  defp unavailable(policy, persistence, opts, reason) do
    %{
      paths: nil,
      policy: policy,
      manifest: Manifest.new(Policy.describe(policy)),
      health: {:unavailable, safe_reason(reason)},
      persistence: persistence,
      ledger_scan_fun: Keyword.get(opts, :ledger_scan_fun, &UsageLedger.scan/1),
      ledger_generation_fun: Keyword.get(opts, :ledger_generation_fun, &UsageLedger.generation/0),
      ledger_retire_fun: Keyword.get(opts, :ledger_retire_fun, &UsageLedger.retire/1),
      raw_bytes_fun: Keyword.get(opts, :raw_bytes_fun, fn -> 0 end),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      last_cycle: :none
    }
  end

  defp schedule(%{interval_ms: interval} = state) when is_integer(interval) and interval > 0 do
    if state.paths != nil and match?(:ok, state.health), do: Process.send_after(self(), :tick, interval)
    state
  end

  defp schedule(state), do: state

  defp safe_int(fun) do
    case safe(fn -> fun.() end) do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :compaction_unavailable
end
