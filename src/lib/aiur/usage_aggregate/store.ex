defmodule Aiur.UsageAggregate.Store do
  @moduledoc false

  # Daemon-private, single supervised worker that projects DASH-009 ordered
  # accepted deltas into the crash-safe aggregate and serves the bounded query.
  #
  # It consumes the ledger only through the public seam: it subscribes first,
  # then scans from its persisted source position and folds forward, so a
  # duplicate refresh or a crash/replay re-scans the same positions without
  # inflating totals. It never appends envelopes, derives deltas, or owns
  # idempotency/counter state — the ledger remains the sole source of truth.

  use GenServer

  require Logger

  alias Aiur.UsageAggregate
  alias Aiur.UsageAggregate.{Checkpoint, Projection, Query, Recovery}

  @max_scan 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec query(map(), GenServer.server()) :: map()
  def query(scope, server \\ __MODULE__) when is_map(scope), do: GenServer.call(server, {:query, scope})

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec health(GenServer.server()) :: term()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @spec freshness(GenServer.server()) :: map()
  def freshness(server \\ __MODULE__), do: GenServer.call(server, :freshness)

  @impl true
  def init(opts) do
    persistence = Recovery.options(opts)

    base =
      case Recovery.state_dir(opts) do
        {:ok, root} -> Recovery.boot(root, persistence)
        {:error, reason} -> Recovery.unavailable(reason)
      end

    {:ok, bootstrap(base, persistence, opts)}
  end

  @impl true
  def handle_call({:query, scope}, _from, state), do: {:reply, Query.summary(state, scope), state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_payload(state), state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:generation, _from, state), do: {:reply, state.projection.generation, state}
  def handle_call(:freshness, _from, state), do: {:reply, state.freshness, state}

  @impl true
  def handle_info({:usage_ledger_delta, _acknowledgement}, state), do: {:noreply, catch_up(state, :notification)}
  def handle_info(_message, state), do: {:noreply, state}

  # --- bootstrap ----------------------------------------------------------

  defp bootstrap(base, persistence, opts) do
    state = new_state(base, persistence, opts)

    if base.paths == nil do
      finalize(%{state | freshness: empty_freshness(base.health)}, :announce)
    else
      _ = safe(fn -> state.ledger_subscribe_fun.(self()) end)
      state |> effective_base(base) |> catch_up(:announce)
    end
  end

  defp new_state(base, persistence, opts) do
    %{
      paths: base.paths,
      projection: base.projection,
      base_available?: base.paths != nil,
      unavailable_health: unavailable_health(base.health),
      health: base.health,
      freshness: empty_freshness(base.health),
      source_coverage: %{},
      recovery: :clean,
      writable?: base.writable?,
      checkpoint_health: :ok,
      persistence: persistence,
      ledger_scan_fun: Keyword.get(opts, :ledger_scan_fun, &Aiur.UsageLedger.scan/1),
      ledger_subscribe_fun: Keyword.get(opts, :ledger_subscribe_fun, &Aiur.UsageLedger.subscribe/1),
      ledger_generation_fun: Keyword.get(opts, :ledger_generation_fun, &Aiur.UsageLedger.generation/0),
      ledger_coverage_fun: Keyword.get(opts, :ledger_coverage_fun, &Aiur.UsageLedger.coverage/0),
      checkpoint_write_fun: Keyword.get(opts, :checkpoint_write_fun, &Checkpoint.write/2),
      publish_fun: Keyword.get(opts, :publish_fun, &UsageAggregate.broadcast/1),
      max_scan: Keyword.get(opts, :max_scan, @max_scan)
    }
  end

  # Decide whether the restored checkpoint can seed the projection or the raw
  # DASH-009 authority must rebuild it from position zero.
  defp effective_base(state, base) do
    ledger_latest = safe_latest(state)

    cond do
      base.rebuild? ->
        %{state | projection: Projection.new(), recovery: rebuild_reason(base.checkpoint_status)}

      is_integer(ledger_latest) and base.projection.source_position > ledger_latest ->
        _ = write_marker(state, :source_regressed)
        %{state | projection: Projection.new(), recovery: :rebuilt_source_regressed}

      true ->
        %{state | projection: base.projection, recovery: :clean}
    end
  end

  defp unavailable_health({:unavailable, _reason} = health), do: health
  defp unavailable_health(_health), do: {:unavailable, :recovery_unavailable}

  defp rebuild_reason(:missing), do: :rebuilt_missing
  defp rebuild_reason({:corrupt, _reason}), do: :rebuilt_corrupt
  defp rebuild_reason(_status), do: :rebuilt_missing

  # --- projection refresh -------------------------------------------------

  defp catch_up(state, mode) do
    ledger_latest = safe_latest(state)
    source_coverage = safe_coverage(state)

    {projection, source_health} =
      case drain(state, state.projection) do
        {:ok, projection} -> {projection, :reachable}
        {:error, _reason} -> {state.projection, :unreachable}
      end

    {checkpoint_health, writable?} = persist(state, projection)

    state
    |> Map.merge(%{
      projection: projection,
      source_coverage: source_coverage,
      checkpoint_health: checkpoint_health,
      writable?: writable?,
      health: derive_health(state, checkpoint_health, source_health),
      freshness: derive_freshness(projection, ledger_latest, source_health, state.recovery)
    })
    |> finalize(mode)
  end

  defp drain(state, projection) do
    case scan(state, projection.source_position) do
      {:ok, []} ->
        {:ok, projection}

      {:ok, records} ->
        next = Projection.apply_records(projection, records)
        if next.source_position > projection.source_position, do: drain(state, next), else: {:ok, next}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan(state, from_position) do
    state.ledger_scan_fun.(after: from_position, limit: state.max_scan)
  rescue
    _error -> {:error, :source_unavailable}
  catch
    _kind, _reason -> {:error, :source_unavailable}
  end

  defp persist(state, projection) do
    cond do
      not state.writable? or is_nil(state.paths) ->
        {state.checkpoint_health, state.writable?}

      projection.source_position <= durable_position(state) ->
        {:ok, state.writable?}

      true ->
        write_checkpoint(state, projection)
    end
  end

  # The durable position is the checkpoint the last successful write persisted.
  # A failed write leaves the in-memory projection ahead of it; the next refresh
  # retries, and a restart replays from the durable checkpoint idempotently.
  defp durable_position(%{checkpoint_health: :ok} = state), do: state.projection.source_position
  defp durable_position(_state), do: -1

  defp write_checkpoint(state, projection) do
    case state.checkpoint_write_fun.(state.paths.checkpoint_path, projection) do
      :ok ->
        _ = clear_marker(state)
        {:ok, true}

      {:error, reason} ->
        Logger.warning("aiur_usage_aggregate phase=checkpoint_failed reason=#{inspect(reason)}")
        {{:failed, reason}, state.writable?}
    end
  end

  defp derive_health(state, checkpoint_health, source_health) do
    cond do
      not state.base_available? -> state.unavailable_health
      match?({:failed, _reason}, checkpoint_health) -> {:degraded, :checkpoint_write_failed}
      source_health == :unreachable -> {:degraded, :source_unavailable}
      true -> :healthy
    end
  end

  defp derive_freshness(projection, ledger_latest, source_health, recovery) do
    %{
      status: freshness_status(projection, ledger_latest, source_health),
      projected_position: projection.source_position,
      ledger_position: ledger_latest,
      recovery: recovery
    }
  end

  defp freshness_status(_projection, _ledger_latest, :unreachable), do: :stale
  defp freshness_status(%{source_position: 0}, latest, _health) when latest in [nil, 0], do: :empty
  defp freshness_status(%{source_position: position}, position, _health), do: :fresh
  defp freshness_status(_projection, _ledger_latest, _health), do: :stale

  # --- publication --------------------------------------------------------

  defp finalize(state, :announce), do: publish(state)

  defp finalize(state, :notification) do
    if changed?(state), do: publish(state), else: state
  end

  defp changed?(state), do: Map.get(state, :published) != publication_key(state)

  defp publish(state) do
    payload = snapshot_payload(state)
    _ = safe(fn -> state.publish_fun.(payload) end)
    Map.put(state, :published, publication_key(state))
  end

  defp publication_key(state) do
    {state.projection.generation, state.projection.source_position, state.health, state.freshness.status}
  end

  # --- payloads -----------------------------------------------------------

  defp snapshot_payload(state) do
    %{
      generation: state.projection.generation,
      source_position: state.projection.source_position,
      source_generation: state.projection.source_generation,
      cell_count: Projection.cell_count(state.projection),
      health: state.health,
      freshness: state.freshness,
      source_coverage: state.source_coverage,
      recovery: state.recovery
    }
  end

  defp empty_freshness(health) do
    status = if match?({:unavailable, _reason}, health), do: :unavailable, else: :empty
    %{status: status, projected_position: 0, ledger_position: nil, recovery: :clean}
  end

  # --- ledger + marker helpers -------------------------------------------

  defp safe_latest(state) do
    case safe(fn -> state.ledger_generation_fun.() end) do
      {:ok, latest} when is_integer(latest) -> latest
      _other -> nil
    end
  end

  defp safe_coverage(state) do
    case safe(fn -> state.ledger_coverage_fun.() end) do
      {:ok, coverage} when is_map(coverage) -> coverage
      _other -> %{}
    end
  end

  defp write_marker(%{paths: nil}, _reason), do: :ok

  defp write_marker(state, reason) do
    state.persistence.degraded_marker_fun.(state.paths.degraded_path, reason, state.persistence.sync_fun)
  rescue
    _error -> :ok
  end

  defp clear_marker(%{paths: nil}), do: :ok
  defp clear_marker(state), do: File.rm(state.paths.degraded_path)

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
