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

  @type path_error :: {:runtime_state_dir_unavailable, atom()}
  @type mode :: :sync | :steer | :async | :mute
  @type record :: %{
          required(:requested) => mode(),
          required(:version) => non_neg_integer(),
          required(:actor) => :default | :human | :executor | :system,
          required(:updated_at) => String.t() | nil,
          optional(:last_read_sequence) => non_neg_integer(),
          optional(:idempotency_key) => String.t() | nil
        }
  @default %{requested: :sync, version: 0, actor: :default, updated_at: nil}

  @spec get(String.t(), keyword()) :: record()
  def get(identifier, opts \\ []) do
    with path when is_binary(path) <- path_for(identifier, opts),
         {:ok, raw} <- JsonStore.read(path) do
      decode(raw, identifier)
    else
      {:error, _reason} -> @default
    end
  end

  @spec put(String.t(), mode(), non_neg_integer(), %{required(:actor) => :human | :executor | :system, optional(:idempotency_key) => String.t() | nil}, keyword()) ::
          {:ok, record()} | {:error, :invalid_mode | {:mode_conflict, record()} | {:write_failed, term()} | path_error()}
  def put(identifier, mode, expected_version, meta, opts \\ [])

  def put(identifier, mode, expected_version, meta, opts) when mode in [:sync, :steer, :async, :mute] do
    with path when is_binary(path) <- path_for(identifier, opts) do
      compare_and_set(identifier, mode, expected_version, meta, opts, path)
    end
  end

  def put(_identifier, _mode, _expected_version, _meta, _opts), do: {:error, :invalid_mode}

  defp compare_and_set(identifier, mode, expected_version, meta, opts, path) do
    current = get(identifier, opts)
    key = Map.get(meta, :idempotency_key)

    cond do
      is_binary(key) and key == Map.get(current, :idempotency_key) and mode == current.requested ->
        {:ok, current}

      expected_version == current.version ->
        persist(path, mode, current.version + 1, meta, Map.take(current, [:last_read_sequence]))

      true ->
        {:error, {:mode_conflict, current}}
    end
  end

  @doc "Record the queue-epoch read position without changing mode or its CAS version. Caller serializes writes."
  @spec record_read(String.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def record_read(identifier, sequence, opts \\ []) do
    with path when is_binary(path) <- path_for(identifier, opts) do
      record = get(identifier, opts) |> Map.put(:last_read_sequence, sequence) |> Map.put(:schema_version, 1)
      JsonStore.write!(path, record)
      :ok
    end
  rescue
    error -> {:error, {:write_failed, error}}
  end

  @spec clear(String.t(), keyword()) :: :ok | {:error, File.posix() | path_error()}
  def clear(identifier, opts \\ []) do
    with path when is_binary(path) <- path_for(identifier, opts) do
      case File.rm(path) do
        {:error, :enoent} -> :ok
        result -> result
      end
    end
  end

  @spec path_for(String.t(), keyword()) :: Path.t() | {:error, path_error()}
  def path_for(identifier, opts \\ []) do
    with {:ok, dir} <- directory(opts) do
      repo = Keyword.get_lazy(opts, :repo_name, &Paths.repo_name/0)
      Path.join(dir, "#{repo}.#{Paths.sanitize(to_string(identifier))}.listen-mode.json")
    end
  end

  defp directory(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} -> {:ok, dir}
      :error -> default_dir()
    end
  end

  defp default_dir do
    case Paths.runtime_state_dir() do
      {:ok, root} -> {:ok, Path.join(root, "listen-modes")}
      {:error, reason} -> {:error, {:runtime_state_dir_unavailable, reason}}
    end
  end

  defp persist(path, mode, version, meta, extra) do
    record = %{requested: mode, version: version, actor: Map.fetch!(meta, :actor), idempotency_key: Map.get(meta, :idempotency_key), updated_at: DateTime.to_iso8601(DateTime.utc_now())}
    record = Map.merge(record, extra)
    JsonStore.write!(path, Map.put(record, :schema_version, 1))
    {:ok, record}
  rescue
    error -> {:error, {:write_failed, error}}
  end

  defp decode(%{"schema_version" => 1, "requested" => mode, "version" => version, "actor" => actor, "updated_at" => updated_at} = raw, identifier)
       when is_binary(mode) and is_integer(version) and version >= 0 and
              actor in ["default", "human", "executor", "system"] and (is_binary(updated_at) or is_nil(updated_at)) do
    record = %{requested: decode_mode(mode, identifier), version: version, actor: decode_actor(actor), idempotency_key: Map.get(raw, "idempotency_key"), updated_at: updated_at}

    case raw["last_read_sequence"] do
      n when is_integer(n) and n >= 0 -> Map.put(record, :last_read_sequence, n)
      _ -> record
    end
  end

  defp decode(_raw, _identifier), do: @default

  defp decode_mode("sync", _identifier), do: :sync
  defp decode_mode("steer", _identifier), do: :steer
  defp decode_mode("async", _identifier), do: :async
  defp decode_mode("mute", _identifier), do: :mute

  defp decode_mode(_unknown, identifier) do
    unless Process.get({__MODULE__, :warned, identifier}, false) do
      Logger.warning("ModeStore(#{identifier}) unknown requested mode; using sync")
      Process.put({__MODULE__, :warned, identifier}, true)
    end

    :sync
  end

  defp decode_actor("default"), do: :default
  defp decode_actor("human"), do: :human
  defp decode_actor("executor"), do: :executor
  defp decode_actor("system"), do: :system
end
