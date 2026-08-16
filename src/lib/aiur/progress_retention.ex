defmodule Aiur.ProgressRetention do
  @moduledoc """
  Durable last-known progress readings per ticket.

  `Aiur.TicketActivity.Projection` retains the latest progress reading in
  memory, but that projection dies with its process: after a projection or
  daemon restart every ticket that already reported re-entered `unknown` until
  the next agent emission, which on a quiet fleet can be a long time (#1963).
  This store is the durable "has reported progress" memory — a file-backed
  checkpoint that survives restarts and is re-seeded into the projection at
  boot, so `unknown` means only "this ticket has never reported".

  ## Semantics

  A reading is retained until superseded by a newer one: latest-`order`-wins,
  using the same `{observed_at, event_id}` ordering the projection uses, so
  out-of-order casts (a late observation re-applied after a restart) never roll
  a reading back. The store keeps the projection's raw progress value
  (`percent`, `source`, `provenance`, `occurred_at`, `observed_at`, `event_id`,
  `order`), which lets every consumer recompute freshness honestly from
  `observed_at`.

  The store never decides `:fresh` versus `:stale` — that is the projection's
  job. It is also deliberately not a journal: the checkpoint is a cache of
  last-known values that is safe to lose and cheap to rebuild, so persistence
  is best-effort (debounced write, synchronous `flush/1`, final `terminate`
  write) and a failure degrades health without taking the fleet view down.

  ## Concurrency

  Writes are serialized through this GenServer. Reads (`all/1`) hit a
  `:read_concurrency` ETS mirror instead of the mailbox, so
  `Aiur.Orchestrator.StatusReport` can consult retained progress on every
  snapshot without queueing behind the store.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, Fs, TrackerIdentity}

  @checkpoint_filename "checkpoint.json"
  @version 1
  @record_keys ~w(checksum entries version)
  @max_checkpoint_bytes 4_000_000
  @debounce_ms 2_000

  @type retained_entry :: %{identity: TrackerIdentity.t(), progress: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Retains the latest progress reading for `identity`.

  Latest-`order`-wins: a value whose progress `order` is older than or equal to
  the current reading for the same identity is a no-op. `progress` is the
  projection's raw progress value (`percent`, `source`, `provenance`,
  `occurred_at`, `observed_at`, `event_id`, `order`). Best-effort and
  fire-and-forget: the caller (a projection process) never blocks on the
  durable write.
  """
  @spec retain(TrackerIdentity.t(), map(), keyword()) :: :ok
  def retain(%TrackerIdentity{} = identity, %{percent: percent} = progress, opts \\ [])
      when is_integer(percent) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:retain, identity, progress})
    :ok
  end

  @doc """
  All retained readings, keyed by `TrackerIdentity.github_key/1`.

  Served from the store's ETS mirror so it is lock-free and never queues behind
  the store's mailbox. Returns `%{}` when the store is not running (tests,
  pre-boot), so callers never handle a missing store specially.
  """
  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    if match?(name when is_atom(name) and not is_nil(name), server) and Process.whereis(server) do
      read_mirror(mirror_table(server))
    else
      retained_via_call(server)
    end
  end

  @doc """
  Synchronously persists any unflushed readings to disk.

  Returns `:ok` even when there is nothing to persist or no durable
  destination; returns `{:error, reason}` only when a real write failed.
  """
  @spec flush(keyword()) :: :ok | {:error, term()}
  def flush(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :flush)
  end

  @doc false
  @spec health(GenServer.server()) :: term()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = mirror_table(name)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(table, {:all, %{}})

    case resolve_state_dir(Keyword.get(opts, :state_dir)) do
      {:ok, dir} ->
        :ok = File.mkdir_p(dir)
        path = Path.join(dir, @checkpoint_filename)
        {retained, health} = load_checkpoint(path)
        :ets.insert(table, {:all, retained})

        {:ok,
         %{
           table: table,
           retained: retained,
           health: health,
           dirty?: false,
           flush_timer: nil,
           path: path,
           synced?: false
         }}

      {:error, reason} ->
        {:ok,
         %{
           table: table,
           retained: %{},
           health: {:degraded, {:state_dir_unavailable, reason}},
           dirty?: false,
           flush_timer: nil,
           path: nil,
           synced?: false
         }}
    end
  end

  @impl true
  def handle_cast({:retain, identity, progress}, state) do
    {:noreply, handle_retain(state, identity, progress)}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.retained, state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  def handle_call(:flush, _from, state) do
    case do_flush(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}
    {:noreply, flush_result_state(do_flush(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case do_flush(state) do
      {:ok, _state} ->
        :ok

      {:error, reason, _state} ->
        Logger.warning("aiur_progress_retention terminate_flush_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp handle_retain(state, identity, progress) do
    key = TrackerIdentity.github_key(identity)

    if is_nil(key) or not is_map(progress) do
      state
    else
      case Map.get(state.retained, key) do
        %{progress: %{order: existing_order}} when is_tuple(existing_order) ->
          if newer_order?(progress, existing_order), do: put_retained(state, key, identity, progress), else: state

        _ ->
          put_retained(state, key, identity, progress)
      end
    end
  end

  defp put_retained(state, key, identity, progress) do
    retained = Map.put(state.retained, key, %{identity: identity, progress: progress})
    :ets.insert(state.table, {:all, retained})
    state = %{state | retained: retained, dirty?: true}
    schedule_flush(state)
  end

  defp newer_order?(%{order: order}, existing_order) when is_tuple(order), do: order > existing_order
  defp newer_order?(_progress, _existing_order), do: true

  defp schedule_flush(%{flush_timer: nil} = state) do
    %{state | flush_timer: Process.send_after(self(), :flush, @debounce_ms)}
  end

  defp schedule_flush(state), do: state

  defp flush_result_state({:ok, state}), do: state
  defp flush_result_state({:error, _reason, state}), do: state

  defp do_flush(%{dirty?: false} = state), do: {:ok, state}
  defp do_flush(%{path: nil} = state), do: {:ok, %{state | dirty?: false}}

  defp do_flush(state) do
    case write_checkpoint(state.path, state.retained, not state.synced?) do
      :ok ->
        {:ok, %{state | dirty?: false, synced?: true}}

      {:error, reason} ->
        {:error, reason, %{state | health: {:degraded, {:flush_failed, reason}}}}
    end
  end

  defp write_checkpoint(path, retained, sync?) do
    with {:ok, contents} <- encode_checkpoint(retained),
         :ok <- ensure_regular_file(path) do
      case Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
        :ok -> if sync?, do: Fs.sync_filesystem(), else: :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp encode_checkpoint(retained) do
    case Jason.encode(checkpoint_record(retained)) do
      {:ok, contents} when byte_size(contents) <= @max_checkpoint_bytes -> {:ok, contents}
      {:ok, _too_large} -> {:error, :record_too_large}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp checkpoint_record(retained) do
    entries =
      retained
      |> Map.values()
      |> Enum.map(fn %{identity: identity, progress: progress} ->
        %{"identity" => identity_record(identity), "progress" => progress_record(progress)}
      end)
      |> Enum.sort_by(fn %{"identity" => identity} -> Map.fetch!(identity, "provider_id") end)

    %{"version" => @version, "entries" => entries, "checksum" => checksum(entries)}
  end

  defp identity_record(%TrackerIdentity{} = identity) do
    %{
      "version" => identity.version,
      "status" => Atom.to_string(identity.status),
      "kind" => encode_atom(identity.kind),
      "owner" => identity.owner,
      "repository" => identity.repository,
      "provider_id" => identity.provider_id,
      "database_id" => identity.database_id,
      "identifier" => identity.identifier,
      "reason" => encode_atom(identity.reason)
    }
  end

  defp progress_record(progress) do
    %{
      "percent" => progress.percent,
      "source" => encode_atom(progress.source),
      "provenance" => progress.provenance,
      "occurred_at" => encode_datetime(progress.occurred_at),
      "observed_at" => encode_datetime(progress.observed_at),
      "event_id" => progress.event_id,
      "order" => encode_order(progress.order)
    }
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp encode_order({micro, event_id}) when is_integer(micro) and is_integer(event_id), do: [micro, event_id]
  defp encode_order(_order), do: nil

  defp load_checkpoint(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {%{}, :healthy}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_checkpoint_bytes ->
        load_regular_checkpoint(path)

      {:ok, %File.Stat{type: :regular}} ->
        {%{}, {:degraded, {:checkpoint_corrupt, :record_too_large}}}

      {:ok, %File.Stat{type: :symlink}} ->
        {%{}, {:degraded, {:checkpoint_corrupt, :symlink_rejected}}}

      {:ok, _stat} ->
        {%{}, {:degraded, {:checkpoint_corrupt, :not_a_regular_file}}}

      {:error, reason} ->
        {%{}, {:degraded, {:checkpoint_unreadable, reason}}}
    end
  end

  defp load_regular_checkpoint(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, record} ->
            case from_record(record) do
              {:ok, retained} -> {retained, :healthy}
              {:error, reason} -> quarantine_corrupt(path, reason)
            end

          {:error, reason} ->
            quarantine_corrupt(path, reason)
        end

      {:error, reason} ->
        {%{}, {:degraded, {:checkpoint_unreadable, reason}}}
    end
  end

  defp quarantine_corrupt(path, reason) do
    _ = Fs.quarantine(path)
    Logger.warning("aiur_progress_retention checkpoint_corrupt path=#{path} reason=#{inspect(reason)}")
    {%{}, {:degraded, {:checkpoint_corrupt, reason}}}
  end

  defp from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         checksum when is_binary(checksum) <- Map.get(record, "checksum"),
         true <- checksum == checksum(Map.get(record, "entries")),
         {:ok, retained} <- decode_entries(Map.get(record, "entries")) do
      {:ok, retained}
    else
      false -> {:error, :checksum_mismatch}
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp from_record(_record), do: {:error, :invalid_checkpoint}

  # The checksum is computed over the JSON-round-tripped entries (string keys,
  # ISO-8601 timestamps), not the in-memory Elixir term (atom keys, DateTime
  # structs): only the canonical form is byte-identical on both the write and
  # the read side, so a freshly-written checkpoint validates when reloaded.
  defp checksum(entries) do
    canonical = entries |> Jason.encode!() |> Jason.decode!()

    {@version, canonical}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp decode_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn record, {:ok, acc} ->
      case decode_entry(record) do
        {:ok, key, entry} -> {:cont, {:ok, Map.put(acc, key, entry)}}
        {:error, _reason} -> {:halt, {:error, :invalid_entry}}
      end
    end)
  end

  defp decode_entries(_entries), do: {:error, :invalid_entries}

  defp decode_entry(record) when is_map(record) do
    with {:ok, identity} <- decode_identity(Map.get(record, "identity")),
         {:ok, progress} <- decode_progress(Map.get(record, "progress")),
         key when is_tuple(key) <- TrackerIdentity.github_key(identity) do
      {:ok, key, %{identity: identity, progress: progress}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  defp decode_entry(_record), do: {:error, :invalid_entry}

  defp decode_identity(record) when is_map(record) do
    with "joinable" <- Map.get(record, "status"),
         "github" <- Map.get(record, "kind"),
         nil <- Map.get(record, "reason"),
         1 <- Map.get(record, "version"),
         owner when is_binary(owner) and owner != "" <- Map.get(record, "owner"),
         repository when is_binary(repository) and repository != "" <- Map.get(record, "repository"),
         provider_id when is_binary(provider_id) and provider_id != "" <- Map.get(record, "provider_id"),
         identifier when is_binary(identifier) and identifier != "" <- Map.get(record, "identifier"),
         {:ok, database_id} <- decode_database_id(Map.get(record, "database_id")) do
      identity = %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: owner,
        repository: repository,
        provider_id: provider_id,
        database_id: database_id,
        identifier: identifier,
        reason: nil
      }

      if TrackerIdentity.joinable?(identity), do: {:ok, identity}, else: {:error, :invalid_identity}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp decode_identity(_record), do: {:error, :invalid_identity}

  defp decode_progress(record) when is_map(record) do
    with percent when is_integer(percent) and percent in 0..100 <- Map.get(record, "percent"),
         {:ok, source} <- decode_source(Map.get(record, "source")),
         provenance when is_map(provenance) <- Map.get(record, "provenance"),
         {:ok, occurred_at} <- decode_datetime(Map.get(record, "occurred_at")),
         {:ok, observed_at} <- decode_required_datetime(Map.get(record, "observed_at")),
         {:ok, event_id} <- decode_event_id(Map.get(record, "event_id")),
         {:ok, order} <- decode_order(Map.get(record, "order")) do
      {:ok,
       %{
         percent: percent,
         source: source,
         provenance: provenance,
         occurred_at: occurred_at,
         observed_at: observed_at,
         event_id: event_id,
         order: order
       }}
    else
      _ -> {:error, :invalid_progress}
    end
  end

  defp decode_progress(_record), do: {:error, :invalid_progress}

  defp decode_database_id(nil), do: {:ok, nil}
  defp decode_database_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp decode_database_id(_value), do: {:error, :invalid_database_id}

  defp decode_source(source) when source in ["phase", "checkin"], do: {:ok, String.to_existing_atom(source)}
  defp decode_source(_source), do: {:error, :invalid_source}

  defp decode_event_id(nil), do: {:ok, nil}
  defp decode_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp decode_event_id(_value), do: {:error, :invalid_event_id}

  defp decode_datetime(nil), do: {:ok, nil}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, dt}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp decode_datetime(_value), do: {:error, :invalid_datetime}

  defp decode_required_datetime(value) do
    case decode_datetime(value) do
      {:ok, nil} -> {:error, :missing_observed_at}
      {:ok, %DateTime{}} = ok -> ok
      {:error, _reason} = error -> error
    end
  end

  defp decode_order([micro, event_id]) when is_integer(micro) and is_integer(event_id), do: {:ok, {micro, event_id}}
  defp decode_order(_order), do: {:error, :invalid_order}

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_state_dir(dir) when is_binary(dir) and dir != "", do: {:ok, dir}
  defp resolve_state_dir(_dir), do: Config.Paths.progress_retention_state_dir()

  defp mirror_table(name) when is_atom(name) and not is_nil(name),
    do: :"#{inspect(name)}.ProgressRetention.Mirror"

  defp mirror_table(_name),
    do: :"Aiur.ProgressRetention.Mirror.#{System.unique_integer([:positive])}"

  defp read_mirror(table) do
    case :ets.lookup(table, :all) do
      [{:all, retained}] -> retained
      [] -> %{}
    end
  rescue
    _ -> %{}
  end

  defp retained_via_call(server) when is_pid(server) do
    if Process.alive?(server), do: GenServer.call(server, :all), else: %{}
  end

  defp retained_via_call(server) do
    if Process.whereis(server), do: GenServer.call(server, :all), else: %{}
  end
end
