defmodule Aiur.ModelDiscovery.Cache do
  @moduledoc false

  # Persistence of the discovery cache file, plus its `:persistent_term` memo.

  alias Aiur.ModelDiscovery

  @cache_version 1

  @spec entry(Aiur.CodingAgent.backend(), keyword()) :: map()
  def entry(backend, opts) do
    state = Keyword.get_lazy(opts, :state, fn -> read_state(opts) end)

    case get_in(state, ["backends", ModelDiscovery.source_key(backend)]) do
      %{} = entry -> entry
      _other -> %{}
    end
  end

  defp cache_path(opts), do: Keyword.get(opts, :path, ModelDiscovery.path())

  # Label resolution reads the cache on the orchestrator's hot paths, so the
  # decoded document is memoized against the file's mtime and size: it is
  # re-read only when a refresh rewrote it (about daily). An explicit `:path`
  # (tests, tools) always reads fresh.
  defp read_state(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} -> ModelDiscovery.load(path)
      :error -> memoized_load(Keyword.get_lazy(opts, :memo_path, &ModelDiscovery.path/0))
    end
  end

  # Every write lands through a tmp file and a rename, so the inode changes on
  # each rewrite even when mtime (one-second resolution) and size do not —
  # a rewrite that only moves a fixed-width timestamp keeps the same size.
  defp memoized_load(path) when is_binary(path) do
    stamp =
      case File.stat(path) do
        {:ok, %File.Stat{inode: inode, mtime: mtime, size: size}} -> {inode, mtime, size}
        {:error, _reason} -> :absent
      end

    case :persistent_term.get({Aiur.ModelDiscovery, :memo}, nil) do
      {^path, ^stamp, state} ->
        state

      _stale ->
        state = ModelDiscovery.load(path)
        :persistent_term.put({Aiur.ModelDiscovery, :memo}, {path, stamp, state})
        state
    end
  end

  defp memoized_load(_path), do: empty_state()

  @spec write_entry(Aiur.CodingAgent.backend(), [map()], [map()], keyword()) :: {:ok, %{models: [map()], rejected: [map()]}}
  def write_entry(backend, models, refused, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    result = %{models: models, rejected: refused}

    case cache_path(opts) do
      nil ->
        {:ok, result}

      path ->
        stamp = DateTime.to_iso8601(now)
        fields = %{"fetched_at" => stamp, "last_attempt_at" => stamp, "models" => models, "rejected" => refused}
        :global.trans(write_lock(path), fn -> persist(path, backend, fields) end, [node()])
        {:ok, result}
    end
  end

  # A failed attempt only stamps `last_attempt_at`; merging (rather than
  # replacing the entry) keeps the last good model list and its `fetched_at`.
  @spec record_attempt(Aiur.CodingAgent.backend(), keyword()) :: :ok
  def record_attempt(backend, opts) do
    case cache_path(opts) do
      nil ->
        :ok

      path ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        :global.trans(write_lock(path), fn -> persist(path, backend, %{"last_attempt_at" => DateTime.to_iso8601(now)}) end, [node()])
        :ok
    end
  end

  # `persist/3` is a read-modify-write of the whole file, so writers must
  # exclude each other. `:global` admits every holder that shares a requester
  # id, so the requester is the calling process — never the path, which would
  # let two refreshes of different backends in together and drop one result.
  defp write_lock(path), do: {{Aiur.ModelDiscovery, :write, path}, self()}

  defp persist(path, backend, fields) do
    state = ModelDiscovery.load(path)
    backends = Map.get(state, "backends", %{})
    key = ModelDiscovery.source_key(backend)
    entry = backends |> Map.get(key, %{}) |> Map.merge(fields)

    write(path, %{
      "version" => @cache_version,
      "backends" => Map.put(backends, key, entry)
    })
  end

  defp write(path, state) do
    File.mkdir_p(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(tmp, Jason.encode!(state, pretty: true) <> "\n") do
      :ok -> File.rename(tmp, path) |> tap(fn _ -> forget_memo() end)
      {:error, _reason} = error -> error
    end
  end

  # A write in this node drops the memo outright; the stat stamp only has to
  # catch writes from other OS processes. (A freed inode can be handed straight
  # back on ext4, so the stamp alone could repeat across two quick rewrites.)
  defp forget_memo do
    :persistent_term.erase({Aiur.ModelDiscovery, :memo})
    :ok
  end

  @spec empty_state() :: map()
  def empty_state, do: %{"version" => @cache_version, "backends" => %{}}
end
