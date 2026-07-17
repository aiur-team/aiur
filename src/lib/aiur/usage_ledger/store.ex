defmodule Aiur.UsageLedger.Store do
  @moduledoc false

  use GenServer

  @behaviour Aiur.UsageLedger

  alias Aiur.{Config, DecisionLog, UsageEnvelope}
  alias Aiur.UsageLedger.{Checkpoint, CounterPolicy, Record, Recovery}

  @max_scan_limit 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Aiur.UsageLedger
  def append(%UsageEnvelope{} = envelope), do: append(__MODULE__, envelope)

  @doc false
  @spec append(GenServer.server(), UsageEnvelope.t()) ::
          {:ok, Aiur.UsageLedger.acknowledgement()}
          | {:duplicate, Aiur.UsageLedger.acknowledgement()}
          | {:error, atom()}
  def append(server, %UsageEnvelope{} = envelope) do
    GenServer.call(server, {:append, envelope}, durability_timeout())
  end

  @doc false
  @spec durability_timeout() :: timeout()
  def durability_timeout, do: Config.usage_ledger_durability_timeout()

  @impl Aiur.UsageLedger
  def scan(options), do: GenServer.call(__MODULE__, {:scan, options})

  @impl Aiur.UsageLedger
  def health, do: GenServer.call(__MODULE__, :health)

  @impl Aiur.UsageLedger
  def generation, do: GenServer.call(__MODULE__, :generation)

  @impl Aiur.UsageLedger
  def coverage, do: GenServer.call(__MODULE__, :coverage)

  @impl Aiur.UsageLedger
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @impl true
  def init(opts) do
    persistence = Recovery.options(opts)

    state =
      case Recovery.state_dir(opts) do
        {:ok, root} ->
          {:ok, state} = Recovery.boot(root, persistence)
          state

        {:error, reason} ->
          {:ok, state} = Recovery.boot("", persistence)
          %{state | health: {:unavailable, reason}, writable?: false}
      end

    {:ok,
     Map.merge(state, %{
       records: :queue.from_list(state.records),
       append_fun: Keyword.get(opts, :append_fun, &DecisionLog.append/2),
       checkpoint_fun: Keyword.get(opts, :checkpoint_fun, &Checkpoint.write_encoded/2),
       checkpoint_encode_fun: Keyword.get(opts, :checkpoint_encode_fun, &Checkpoint.encode/2),
       sync_fun: persistence.sync_fun,
       publish_fun: Keyword.get(opts, :publish_fun, fn _acknowledgement -> :ok end),
       subscribers: %{}
     })}
  end

  @impl true
  def handle_call({:append, _envelope}, _from, %{writable?: false} = state) do
    {:reply, {:error, :ledger_unavailable}, state}
  end

  def handle_call({:append, envelope}, _from, state) do
    case CounterPolicy.apply(state.policy, envelope) do
      {:duplicate, _policy} ->
        {:reply, {:duplicate, duplicate_acknowledgement(state, envelope)}, state}

      {:error, reason, _policy} ->
        {:reply, {:error, reason}, state}

      {:ok, %{state: policy, delta: delta}} ->
        persist(envelope, policy, delta, state)
    end
  end

  def handle_call({:scan, options}, _from, state) do
    after_position = Keyword.get(options, :after, 0)
    limit = options |> Keyword.get(:limit, @max_scan_limit) |> scan_limit()

    records =
      state.records
      |> :queue.to_list()
      |> Enum.filter(&(&1.position > after_position))
      |> Enum.take(limit)
      |> Enum.map(&replay_record/1)

    {:reply, {:ok, records}, state}
  end

  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}
  def handle_call(:coverage, _from, state), do: {:reply, state.coverage, state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      case Map.fetch(state.subscribers, pid) do
        {:ok, _reference} -> state.subscribers
        :error -> Map.put(state.subscribers, pid, Process.monitor(pid))
      end

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^reference -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp persist(envelope, policy, delta, state) do
    position = state.position + 1
    generation = state.generation + 1
    checkpoint = Checkpoint.record(position, generation, policy)

    with {:ok, record} <- Record.new(position, envelope, delta),
         {:ok, encoded_checkpoint} <- encode_checkpoint(checkpoint, state),
         :ok <- capacity(record, encoded_checkpoint, policy, state),
         :ok <- state.append_fun.(state.paths.segment_path, Record.encode(record)),
         :ok <- state.checkpoint_fun.(state.paths.checkpoint_path, encoded_checkpoint),
         :ok <- state.sync_fun.() do
      next_state = %{
        state
        | records: :queue.in(record, state.records),
          policy: policy,
          position: position,
          generation: generation,
          coverage: policy.coverage,
          health: :healthy
      }

      acknowledgement = %{position: position, generation: generation, delta: record.delta}
      publish(next_state, acknowledgement)
      {:reply, {:ok, acknowledgement}, next_state}
    else
      {:error, :capacity_exhausted} ->
        next_state = %{state | health: {:degraded, :capacity_exhausted}}
        {:reply, {:error, :capacity_exhausted}, next_state}

      {:error, _reason} ->
        next_state = %{state | health: {:degraded, :persistence_failed}, writable?: false}
        {:reply, {:error, :persistence_failed}, next_state}
    end
  end

  defp encode_checkpoint(checkpoint, state) do
    case state.checkpoint_encode_fun.(checkpoint, state.limits.max_checkpoint_bytes) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, :record_too_large} -> {:error, :capacity_exhausted}
      {:error, _reason} -> {:error, :checkpoint_encode_failed}
    end
  end

  defp capacity(record, encoded_checkpoint, policy, state) do
    encoded_record = Jason.encode!(Record.encode(record))
    segment_size = file_size(state.paths.segment_path)

    if byte_size(encoded_record) > state.limits.max_record_bytes or
         segment_size + byte_size(encoded_record) + 1 > state.limits.max_segment_bytes or
         byte_size(encoded_checkpoint) > state.limits.max_checkpoint_bytes or
         MapSet.size(policy.idempotency) > state.limits.max_idempotency_entries do
      {:error, :capacity_exhausted}
    else
      :ok
    end
  end

  defp file_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _ -> 0
    end
  end

  defp duplicate_acknowledgement(state, envelope) do
    idempotency_key = CounterPolicy.idempotency_key(envelope)

    case Enum.find(:queue.to_list(state.records), &(CounterPolicy.idempotency_key(&1.envelope) == idempotency_key)) do
      nil -> %{position: state.position, generation: state.generation, delta: nil}
      record -> %{position: record.position, generation: record.position, delta: record.delta}
    end
  end

  defp replay_record(record) do
    %{
      position: record.position,
      generation: record.position,
      envelope: record.envelope,
      delta: record.delta,
      source_version: record.envelope.source_version,
      relationship_revision: record.envelope.relationship_revision,
      coverage_reasons: record.envelope.coverage_reasons
    }
  end

  defp publish(state, acknowledgement) do
    Enum.each(state.subscribers, fn {pid, _reference} -> send(pid, {:usage_ledger_delta, acknowledgement}) end)
    _ = state.publish_fun.(acknowledgement)
    :ok
  rescue
    _error -> :ok
  end

  defp scan_limit(value) when is_integer(value) and value > 0, do: min(value, @max_scan_limit)
  defp scan_limit(_value), do: @max_scan_limit
end
