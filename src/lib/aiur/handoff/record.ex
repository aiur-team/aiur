defmodule Aiur.Handoff.Record do
  @moduledoc "Durable, versioned daemon handoff records and their adoption outcomes."

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @schema 1
  @default_timeout_ms 1_800_000
  @type result :: {:ok, map()} | :none | {:error, term()}

  @doc "The handoff file under the durable runtime-state root (injectable with :dir)."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    root = Keyword.get_lazy(opts, :dir, fn -> Paths.runtime_state_dir() |> elem(1) end)
    Path.join([root, "handoff", "current.json"])
  end

  @doc "Atomically writes a schema-validated record. Keys are normalized through JSON."
  @spec write(map(), keyword()) :: :ok | {:error, term()}
  def write(record, opts \\ []) do
    with {:ok, json} <- Jason.encode(record),
         {:ok, normalized} <- Jason.decode(json),
         {:ok, valid} <- validate(normalized, opts) do
      JsonStore.write!(path(opts), valid)
    end
  rescue
    error in [File.Error, Jason.EncodeError, MatchError] -> {:error, error}
  end

  @doc "Reads a compatible, fresh handoff; absent records return :none."
  @spec read(keyword()) :: result()
  def read(opts \\ []) do
    with {:ok, record} <- read_raw(opts), do: validate(record, opts)
  end

  @doc "Reads the unvalidated record so unsupported-schema agents can still be stopped."
  @spec read_raw(keyword()) :: result()
  def read_raw(opts \\ []) do
    case JsonStore.read(path(opts)) do
      {:ok, nil} -> :none
      {:ok, record} when is_map(record) -> {:ok, record}
      {:error, %Jason.DecodeError{}} -> {:error, :schema}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :schema}
    end
  end

  @doc "Validates the version and envelope; older-than-orphan-timeout records are stale."
  @spec validate(term(), keyword()) :: {:ok, map()} | {:error, :schema | :stale}
  def validate(record, opts \\ []) do
    with true <- valid_envelope?(record),
         {:ok, written_at, _} <- DateTime.from_iso8601(record["written_at"]) do
      age = DateTime.diff(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0), written_at, :millisecond)
      if age > orphan_timeout(opts), do: {:error, :stale}, else: {:ok, record}
    else
      _ -> {:error, :schema}
    end
  end

  @doc "Consumes once by atomic rename, then records the per-agent adoption outcome."
  @spec consume(term(), keyword()) :: :ok | {:error, term()}
  def consume(outcome, opts \\ []) do
    file = path(opts)
    :global.trans({{__MODULE__, file}, self()}, fn -> consume_file(file, outcome) end)
  end

  defp consume_file(file, outcome) do
    with {:ok, record} when is_map(record) <- JsonStore.read(file),
         :ok <- File.rename(file, file <> ".consumed") do
      JsonStore.write!(file <> ".consumed", Map.merge(record, %{"outcome" => outcome, "completed_at" => DateTime.to_iso8601(DateTime.utc_now())}))
    else
      {:ok, nil} -> {:error, :already_consumed}
      {:error, :enoent} -> {:error, :already_consumed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :schema}
    end
  rescue
    error in [File.Error, Jason.EncodeError, MatchError] -> {:error, error}
  end

  defp orphan_timeout(opts) do
    Keyword.get_lazy(opts, :orphan_timeout_ms, fn ->
      case Aiur.Config.settings() do
        {:ok, %{agent: %{relay_orphan_timeout_seconds: seconds}}} -> seconds * 1_000
        _ -> @default_timeout_ms
      end
    end)
  end

  defp valid_envelope?(%{
         "handoff_schema" => @schema,
         "handoff_id" => id,
         "written_at" => written_at,
         "from_version" => version,
         "generation" => generation,
         "config_fingerprint" => fingerprint,
         "agents" => agents
       }) do
    is_binary(id) and id != "" and is_binary(written_at) and is_binary(version) and
      is_integer(generation) and generation >= 0 and is_binary(fingerprint) and is_list(agents) and Enum.all?(agents, &is_map/1)
  end

  defp valid_envelope?(_), do: false
end
