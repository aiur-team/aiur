defmodule Aiur.ProgressRetention.Checkpoint do
  @moduledoc """
  File-backed checkpoint for `Aiur.ProgressRetention`: write, encode, load,
  quarantine, checksum and decode. Touches only the file system; the GenServer
  keeps its name, table and state.
  """

  require Logger

  alias Aiur.{Fs, TrackerIdentity}

  @version 1
  @record_keys ~w(checksum entries version)
  @max_checkpoint_bytes 4_000_000

  @spec write(Path.t(), map(), boolean()) :: :ok | {:error, term()}
  def write(path, retained, sync?) do
    with {:ok, contents} <- encode_checkpoint(retained),
         :ok <- ensure_regular_file(path) do
      persist_checkpoint(path, contents, sync?)
    else
      {:error, _reason} = error -> error
    end
  end

  defp persist_checkpoint(path, contents, sync?) do
    case Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
      :ok -> sync_filesystem_when_first_write(sync?)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_filesystem_when_first_write(true), do: Fs.sync_filesystem()
  defp sync_filesystem_when_first_write(false), do: :ok

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

  @spec load(Path.t()) :: {map(), :healthy | {:degraded, term()}}
  def load(path) do
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
      {:ok, contents} -> decoded_checkpoint(path, contents)
      {:error, reason} -> {%{}, {:degraded, {:checkpoint_unreadable, reason}}}
    end
  end

  defp decoded_checkpoint(path, contents) do
    case Jason.decode(contents) do
      {:ok, record} -> retained_from_record(path, record)
      {:error, reason} -> quarantine_corrupt(path, reason)
    end
  end

  defp retained_from_record(path, record) do
    case from_record(record) do
      {:ok, retained} -> {retained, :healthy}
      {:error, reason} -> quarantine_corrupt(path, reason)
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
end
