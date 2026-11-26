defmodule Aiur.Experiments.SnapshotPersistence do
  @moduledoc false
  alias Aiur.Experiments.{Evidence, Journal, Paths, Persistence, Reader, Schema, Snapshot}

  @spec commit(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def commit(id, name, snapshot, opts) do
    entry = %{
      "schema_version" => Schema.current(),
      "kind" => "frozen",
      "window" => name,
      "revision" => snapshot["revision"],
      "sha256" => snapshot["sha256"],
      "observation_count" => snapshot["observation_count"],
      "reason" => opts[:reason],
      "at" => snapshot["computed_at"],
      "actor" => Keyword.get(opts, :actor, "operator")
    }

    transaction = %{"schema_version" => Schema.current(), "snapshot" => snapshot, "entry" => entry}

    with :ok <- Aiur.Journal.ensure_directory(Paths.file(id, "snapshots")),
         :ok <- Persistence.write_json(Paths.file(id, "snapshot-pending.json"), transaction) do
      finish(id, transaction)
    end
  end

  @spec recover(String.t()) :: :ok | {:error, term()}
  def recover(id) do
    case Reader.json(Paths.file(id, "snapshot-pending.json")) do
      {:error, :not_found} -> :ok
      {:ok, transaction} -> with {:ok, transaction} <- Schema.migrate(transaction), do: finish(id, transaction)
      error -> error
    end
  end

  defp finish(id, %{"snapshot" => snapshot, "entry" => entry}) do
    path = Paths.file(id, "snapshots/#{entry["window"]}.r#{entry["revision"]}.json")

    with :ok <- write_once(path, snapshot),
         {:ok, entries} <- Journal.read(Paths.file(id, "journal.ndjson")),
         :ok <- append(id, entry, entries),
         :ok <- File.rm(Paths.file(id, "snapshot-pending.json")) do
      Persistence.broadcast(id)
    end
  end

  defp write_once(path, snapshot) do
    if File.exists?(path) do
      case Snapshot.read(path) do
        {:ok, ^snapshot} -> :ok
        _ -> {:error, :tampered}
      end
    else
      Aiur.Fs.atomic_write(path, Evidence.encode(snapshot) <> "\n", fsync: true, mode: 0o444)
    end
  end

  defp append(id, entry, entries) do
    if entry in entries, do: :ok, else: Journal.append(Paths.file(id, "journal.ndjson"), entry)
  end
end
