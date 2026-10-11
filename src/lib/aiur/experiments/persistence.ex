defmodule Aiur.Experiments.Persistence do
  @moduledoc false

  alias Aiur.Experiments.{Journal, Paths, Reader, Schema}

  @spec write_json(Path.t(), map()) :: :ok | {:error, term()}
  def write_json(path, value), do: Aiur.Fs.atomic_write(path, Jason.encode!(value, pretty: true) <> "\n", fsync: true, mode: 0o600)

  @spec index() :: :ok | {:error, term()}
  def index do
    with {:ok, rows} <- Reader.summaries(), do: write_json(Path.join(Paths.root(), "index.json"), %{schema_version: Schema.current(), experiments: rows})
  end

  @spec writable(String.t()) :: :ok | {:error, term()}
  def writable(id) do
    with :ok <- spec_writable(id),
         :ok <- Journal.writable(Paths.file(id, "journal.ndjson")),
         :ok <- Journal.writable(Paths.file(id, "annotations.ndjson")) do
      pending_writable(id)
    end
  end

  defp spec_writable(id) do
    case Reader.spec(id) do
      {:ok, spec, _read_only?} ->
        case Schema.migrate(spec) do
          {:ok, _spec} -> :ok
          error -> error
        end

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
  end

  defp pending_writable(id) do
    case Reader.json(Paths.file(id, "pending.json")) do
      {:ok, value} ->
        case Schema.migrate(value) do
          {:ok, _value} -> :ok
          error -> error
        end

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
  end

  @spec commit(String.t(), map(), map(), function()) :: :ok | {:error, term()}
  def commit(id, spec, entry, append) do
    with :ok <- writable(id),
         :ok <- prepare(id),
         :ok <- write_json(Paths.file(id, "pending.json"), %{schema_version: Schema.current(), spec: spec, entry: entry}),
         :ok <- Aiur.Fs.sync_filesystem() do
      finish(id, spec, entry, append)
    end
  end

  defp prepare(id) do
    with :ok <- Aiur.Journal.ensure_directory(Paths.experiment(id)),
         :ok <- Aiur.Journal.ensure_directory(Paths.file(id, "report")),
         :ok <- Aiur.Journal.prepare(Paths.experiment(id), Paths.file(id, "journal.ndjson")) do
      Aiur.Journal.prepare(Paths.experiment(id), Paths.file(id, "annotations.ndjson"))
    end
  end

  defp finish(id, spec, entry, append) do
    with :ok <- write_json(Paths.file(id, "spec.json"), spec),
         :ok <- append_once(id, entry, append),
         :ok <- index(),
         :ok <- File.rm(Paths.file(id, "pending.json")) do
      broadcast(id)
    end
  end

  defp append_once(id, entry, append) do
    path = Paths.file(id, "journal.ndjson")

    with {:ok, entries} <- Journal.read(path) do
      if Enum.any?(entries, &(&1["event_id"] == entry["event_id"])) do
        confirm_appended(path, entry["event_id"])
      else
        append.(path, entry)
      end
    end
  end

  defp confirm_appended(path, event_id) do
    case Aiur.Journal.reconcile_ambiguous(path, event_id) do
      :accepted -> :ok
      {:ambiguous, reason} -> {:error, reason}
      :failed -> {:error, :journal_entry_missing}
    end
  end

  @spec recover() :: :ok | {:error, term()}
  def recover do
    with {:ok, ids} <- Paths.ids() do
      Enum.reduce_while(ids, :ok, &recover_next/2)
    end
  end

  defp recover_next(id, :ok) do
    case recover_one(id) do
      :ok -> {:cont, :ok}
      {:error, {:newer_version, _version}} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @spec recover_one(String.t()) :: :ok | {:error, term()}
  def recover_one(id) do
    case Reader.json(Paths.file(id, "pending.json")) do
      {:error, :not_found} ->
        :ok

      {:ok, transaction} ->
        with :ok <- writable(id),
             {:ok, transaction} <- Schema.migrate(transaction),
             %{"spec" => spec, "entry" => entry} <- transaction do
          finish(id, spec, entry, &Journal.append/2)
        else
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_transaction}
        end

      error ->
        error
    end
  end

  @spec broadcast(String.t() | :all) :: :ok
  def broadcast(id), do: Phoenix.PubSub.broadcast(Aiur.PubSub, "experiments", {:experiments_changed, id})
end
