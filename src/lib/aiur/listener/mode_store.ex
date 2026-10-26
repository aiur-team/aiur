defmodule Aiur.Listener.ModeStore do
  @moduledoc """
  Durable requested listener mode for one ticket run. Writes must be serialized
  by the Orchestrator; this module provides compare-and-set, not a file lock.
  `:dir` overrides the listen-modes directory and `:repo_name` pins its namespace.
  Unknown modes warn once per identifier in each reading process.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @type mode :: :sync | :steer | :async
  @type record :: %{
          required(:requested) => mode(),
          required(:version) => non_neg_integer(),
          required(:actor) => :default | :human | :executor | :system,
          required(:updated_at) => String.t() | nil,
          optional(:idempotency_key) => String.t() | nil
        }
  @default %{requested: :sync, version: 0, actor: :default, updated_at: nil}

  @spec get(String.t(), keyword()) :: record()
  def get(identifier, opts \\ []) do
    case JsonStore.read(path_for(identifier, opts)) do
      {:ok, raw} -> decode(raw, identifier)
      {:error, _reason} -> @default
    end
  end

  @spec put(String.t(), mode(), non_neg_integer(), %{required(:actor) => :human | :executor | :system, optional(:idempotency_key) => String.t() | nil}, keyword()) ::
          {:ok, record()} | {:error, :invalid_mode | {:mode_conflict, record()} | {:write_failed, term()}}
  def put(identifier, mode, expected_version, meta, opts \\ [])

  def put(identifier, mode, expected_version, meta, opts) when mode in [:sync, :steer, :async] do
    current = get(identifier, opts)
    key = Map.get(meta, :idempotency_key)

    cond do
      is_binary(key) and key == Map.get(current, :idempotency_key) and mode == current.requested ->
        {:ok, current}

      expected_version == current.version ->
        persist(identifier, mode, current.version + 1, meta, opts)

      true ->
        {:error, {:mode_conflict, current}}
    end
  end

  def put(_identifier, _mode, _expected_version, _meta, _opts), do: {:error, :invalid_mode}

  @spec clear(String.t(), keyword()) :: :ok | {:error, File.posix()}
  def clear(identifier, opts \\ []) do
    case File.rm(path_for(identifier, opts)) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @spec path_for(String.t(), keyword()) :: Path.t()
  def path_for(identifier, opts \\ []) do
    dir =
      Keyword.get_lazy(opts, :dir, fn ->
        {:ok, root} = Paths.runtime_state_dir()
        Path.join(root, "listen-modes")
      end)

    repo = Keyword.get_lazy(opts, :repo_name, &Paths.repo_name/0)
    Path.join(dir, "#{repo}.#{Paths.sanitize(to_string(identifier))}.listen-mode.json")
  end

  defp persist(identifier, mode, version, meta, opts) do
    record = %{requested: mode, version: version, actor: Map.fetch!(meta, :actor), idempotency_key: Map.get(meta, :idempotency_key), updated_at: DateTime.to_iso8601(DateTime.utc_now())}
    JsonStore.write!(path_for(identifier, opts), Map.put(record, :schema_version, 1))
    {:ok, record}
  rescue
    error -> {:error, {:write_failed, error}}
  end

  defp decode(%{"schema_version" => 1, "requested" => mode, "version" => version, "actor" => actor, "updated_at" => updated_at} = raw, identifier)
       when is_binary(mode) and is_integer(version) and version > 0 and
              actor in ["human", "executor", "system"] and is_binary(updated_at) do
    %{requested: decode_mode(mode, identifier), version: version, actor: decode_actor(actor), idempotency_key: Map.get(raw, "idempotency_key"), updated_at: updated_at}
  end

  defp decode(_raw, _identifier), do: @default

  defp decode_mode("sync", _identifier), do: :sync
  defp decode_mode("steer", _identifier), do: :steer
  defp decode_mode("async", _identifier), do: :async

  defp decode_mode(_unknown, identifier) do
    unless Process.get({__MODULE__, :warned, identifier}, false) do
      Logger.warning("ModeStore(#{identifier}) unknown requested mode; using sync")
      Process.put({__MODULE__, :warned, identifier}, true)
    end

    :sync
  end

  defp decode_actor("human"), do: :human
  defp decode_actor("executor"), do: :executor
  defp decode_actor("system"), do: :system
end
