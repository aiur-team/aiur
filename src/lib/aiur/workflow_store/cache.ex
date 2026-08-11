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
  Publishes the current workflow. Overwrites the parsed-settings memo key so a
  reader can never pair a new workflow with settings parsed from an older one.
  """
  @spec put(term(), generation()) :: :ok
  def put(workflow, generation) when is_integer(generation) do
    safe(fn ->
      :ets.insert(@table, {@current_key, workflow, generation})
      :ets.delete(@table, @settings_key)
    end)
  end

  @spec fetch() :: {:ok, term(), generation()} | :error
  def fetch do
    case safe_lookup(@current_key) do
      [{@current_key, workflow, generation}] -> {:ok, workflow, generation}
      _ -> :error
    end
  end

  @doc """
  Memoized `Aiur.Config.Schema` parse.

  `key` is opaque to this module — `Aiur.Config` builds it from the workflow
  generation plus an environment epoch, because parsing resolves `$ENV`
  references. Exactly one memo is kept: a lookup whose key does not match is a
  miss, and the next `put_settings/2` overwrites it. Any reader may compute the
  value; two readers racing produce the same one and the later insert wins.
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
