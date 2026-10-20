defmodule Aiur.GitHub.ResourceStore.Checkpoint do
  @moduledoc false

  require Logger

  alias Aiur.Fs

  @revision_table __MODULE__.Revision
  @key_revision_table __MODULE__.KeyRevision
  @entry_cache __MODULE__.EncodedEntries
  @event [:aiur, :github, :resource_store, :checkpoint]

  @spec init() :: atom()
  def init do
    :ets.new(@revision_table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@revision_table, {:revision, 0})
    :ets.new(@key_revision_table, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@entry_cache, [:named_table, :public, :set, write_concurrency: true])
  end

  @spec mark_dirty() :: pos_integer() | :ok
  def mark_dirty do
    :ets.update_counter(@revision_table, :revision, 1, {:revision, 0})
  rescue
    ArgumentError -> :ok
  end

  @spec mark_entry_dirty(term()) :: :ok
  def mark_entry_dirty(key) do
    :ets.delete(@entry_cache, key)
    :ets.insert(@key_revision_table, {key, make_ref()})
    mark_dirty()
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec mark_entries_dirty([term()]) :: :ok
  def mark_entries_dirty(keys) do
    Enum.each(keys, &mark_entry_dirty/1)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec remove_entries([term()]) :: :ok
  def remove_entries(keys) do
    Enum.each(keys, fn key ->
      :ets.delete(@entry_cache, key)
      :ets.delete(@key_revision_table, key)
    end)

    mark_dirty()
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec cached_entry(:ets.table(), term(), term(), (term() -> iodata())) :: iodata() | nil
  def cached_entry(table, key, entry, encode) do
    revision = key_revision(key)

    case :ets.lookup(@entry_cache, key) do
      [{^key, {^revision, cached_encoded}}] ->
        cached_encoded

      _other ->
        case :ets.lookup(table, key) do
          [{^key, current_entry}] ->
            encoded_entry = encode.(current_entry)
            true = :ets.insert(@entry_cache, {key, {revision, encoded_entry}})
            encoded_entry

          _deleted_during_render ->
            nil
        end
    end
  rescue
    ArgumentError -> encode.(entry)
  end

  defp key_revision(key) do
    case :ets.lookup(@key_revision_table, key) do
      [{^key, revision}] -> revision
      _other -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @spec run(map(), (:ets.table() -> {:ok, iodata()} | {:error, term()}), keyword()) ::
          {:ok, map()} | {{:error, term()}, map()}
  def run(%{path: nil} = state, _render, _opts), do: {:ok, state}

  def run(%{table: table, path: path} = state, render, opts) do
    revision = revision()

    if not Keyword.get(opts, :force, false) and revision == state.last_written_revision do
      :telemetry.execute(@event, %{entries: :ets.info(table, :size)}, %{result: :unchanged})
      {:ok, state}
    else
      write_checkpoint(state, revision, table, path, render)
    end
  end

  defp write_checkpoint(state, revision, table, path, render) do
    with {:ok, encoded} <- render.(table),
         :ok <- write(path, encoded) do
      :telemetry.execute(@event, %{entries: :ets.info(table, :size)}, %{result: :written})
      {:ok, %{state | last_written_revision: revision}}
    else
      {:error, reason} = error ->
        Logger.warning("GitHub.ResourceStore checkpoint failed; reason=#{inspect(reason)}")
        {error, state}
    end
  end

  defp revision do
    case :ets.lookup(@revision_table, :revision) do
      [{:revision, revision}] -> revision
      _other -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp write(path, encoded) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      Fs.atomic_write(path, encoded, fsync: true, mode: 0o600)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
