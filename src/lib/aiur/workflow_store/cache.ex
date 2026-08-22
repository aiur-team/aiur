defmodule Aiur.WorkflowStore.Cache do
  @moduledoc """
  Lock-free read side of `Aiur.WorkflowStore`.

  The config is one small file that changes at human cadence, but it is read on
  every hot path in the system — `Aiur.Config.settings/0` alone is reached from
  dispatch, status rendering, backend override resolution and the dashboard.
  Serving those reads with a `GenServer.call` made the store a global mutex:
  #1731 caught `Aiur.Orchestrator` blocked in `gen:do_call/4` waiting on this
  store while the store itself re-read and re-parsed the config, with 10,456
  messages queued behind it.

  The store now publishes into this ETS table on load and on every change, and
  readers take the value directly. Reads never enter the store's mailbox, so no
  caller can be head-of-line blocked by another caller — or by the store's own
  reload work.

  The table is owned by the `WorkflowStore` process, so a store restart drops
  every entry atomically and readers fall back to reading the file. It is
  `:public` because the parsed-settings memo below is filled in by whichever
  reader first needs it, not by the store.
  """

  @table :aiur_workflow_store_cache
  @current_key :current
  @settings_key :settings
  @env_names_key :env_names

  @type generation :: pos_integer()

  @doc "Creates the table. Called from the owning `WorkflowStore` process."
  @spec init!() :: :ok
  def init! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: false])
        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Publishes the current workflow. Drops the derived-value keys so a reader can
  never pair a new workflow with values derived from an older one. Both are
  also stamped with a collision-free publication reference, so a torn write
  between the insert and the deletes is a miss rather than a stale hit. A late
  reader may republish a value under its old reference, but it cannot match a
  later publication even if generation metadata is reused.

  The entry carries the `path` the workflow was loaded from. A reader fetches
  by its own current path (see `fetch/1`) and only accepts an entry whose path
  matches — so a reload that re-pointed the store at a *different* config
  cannot be observed by a reader whose path still points at its own file.
  """
  @spec put(term(), generation(), Path.t()) :: :ok
  def put(workflow, generation, path) when is_integer(generation) and is_binary(path) do
    safe(fn ->
      :ets.insert(@table, {@current_key, path, workflow, generation, make_ref()})
      :ets.delete(@table, @settings_key)
      :ets.delete(@table, @env_names_key)
    end)
  end

  @doc """
  Fetches the published workflow whose path matches `path`.

  Returns `{:stale, cached_path}` when the cache holds an entry for a *different*
  path. Callers use that to refuse the entry rather than serving a config that
  belongs to another path — the fence that keeps a `write_workflow_file!/2`
  + `force_reload` from being clobbered by a concurrent reload from elsewhere.
  """
  @spec fetch(Path.t()) :: {:ok, term(), generation(), reference()} | {:stale, Path.t()} | :error
  def fetch(path) when is_binary(path) do
    case safe_lookup(@current_key) do
      [{@current_key, ^path, workflow, generation, publication}] -> {:ok, workflow, generation, publication}
      [{@current_key, cached_path, _workflow, _generation, _publication}] -> {:stale, cached_path}
      _ -> :error
    end
  end

  @doc """
  Memoized `Aiur.Config.Schema` parse.

  `key` is opaque to this module — `Aiur.Config` builds it from the workflow
  generation, a collision-free workflow publication reference, and an
  environment epoch, because parsing resolves `$ENV` references. The reference
  prevents a late reader from republishing old settings under reused generation
  metadata without copying the full config term through this hot lookup.
  Exactly one memo is kept: a lookup whose key does not match is a miss, and the
  next `put_settings/2` overwrites it. Any reader may compute the value; two
  readers for the same publication produce the same one and the later insert
  wins.
  """
  @spec fetch_settings(term()) :: {:ok, term()} | :error
  def fetch_settings(key) do
    case safe_lookup(@settings_key) do
      [{@settings_key, ^key, settings}] -> {:ok, settings}
      _ -> :error
    end
  end

  @spec put_settings(term(), term()) :: :ok
  def put_settings(key, settings) do
    safe(fn -> :ets.insert(@table, {@settings_key, key, settings}) end)
  end

  @doc """
  The environment variable names `Aiur.Config.settings/0` must sample to decide
  whether its memo is still valid. Derived from the config content, so it is
  fixed for one workflow publication. The key carries that publication's
  collision-free reference and generation so late readers cannot cross a reused
  generation boundary. That is the whole point of caching it: sampling a
  handful of named variables costs a fraction of a microsecond, while hashing
  the entire environment cost 154us per read on a 226-variable host, roughly
  300x the ETS lookup it guards.
  """
  @spec fetch_env_names(term()) :: {:ok, [String.t()]} | :error
  def fetch_env_names(key) do
    case safe_lookup(@env_names_key) do
      [{@env_names_key, ^key, names}] -> {:ok, names}
      _ -> :error
    end
  end

  @spec put_env_names(term(), [String.t()]) :: :ok
  def put_env_names(key, names) do
    safe(fn -> :ets.insert(@table, {@env_names_key, key, names}) end)
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  # The owning process can die between `whereis` and the write; that is a
  # cache miss for the next reader, never a crash for this one.
  defp safe(fun) do
    _ = fun.()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
