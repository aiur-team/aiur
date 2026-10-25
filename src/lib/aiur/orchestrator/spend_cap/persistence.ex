defmodule Aiur.Orchestrator.SpendCap.Persistence do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.SpendCap.Record

  @max_bytes 1_048_576
  @filename "ticket-spend-caps.json"

  @spec load(keyword(), String.t()) :: {:ok, Path.t(), map(), function()} | {:error, atom(), Path.t() | nil, function()}
  def load(opts, repository) when is_binary(repository) do
    writer = Keyword.get(opts, :writer, &Aiur.Fs.atomic_write/3)
    do_load(opts, repository, writer)
  end

  defp do_load(opts, repository, writer) do
    with {:ok, dir} <- directory(opts),
         :ok <- File.mkdir_p(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir) do
      path = Path.join(dir, @filename)

      case read(path, repository) do
        {:ok, records} -> {:ok, path, records, writer}
        {:error, reason} -> {:error, reason, path, writer}
      end
    else
      _other -> {:error, :spend_cap_state_unavailable, nil, writer}
    end
  rescue
    _error -> {:error, :spend_cap_state_unavailable, nil, writer}
  catch
    _, _ -> {:error, :spend_cap_state_unavailable, nil, writer}
  end

  @spec write(Path.t(), String.t(), map(), function(), function()) :: :ok | {:error, :spend_cap_write_failed}
  def write(path, repository, records, writer, sync_fun)
      when is_binary(path) and is_binary(repository) and is_map(records) and is_function(sync_fun, 0) do
    encoded = records |> Map.values() |> Enum.sort_by(& &1.identity.identifier) |> Enum.map(&Record.encode/1)

    with {:ok, %{type: :directory}} <- File.lstat(Path.dirname(path)),
         {:ok, disposition} <- safe_destination(path),
         {:ok, json} <- Jason.encode(%{version: 1, repository: repository, records: encoded}),
         true <- byte_size(json) <= @max_bytes,
         :ok <- writer.(path, json, mode: 0o600, fsync: true),
         :ok <- maybe_sync(disposition, sync_fun) do
      :ok
    else
      _other -> {:error, :spend_cap_write_failed}
    end
  rescue
    _error -> {:error, :spend_cap_write_failed}
  end

  def write(_path, _repository, _records, _writer, _sync_fun), do: {:error, :spend_cap_write_failed}

  defp directory(opts) do
    case Keyword.fetch(opts, :state_dir) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      {:ok, _invalid} -> {:error, :spend_cap_state_unavailable}
      :error -> with {:ok, root} <- Paths.decision_state_dir(), do: {:ok, Path.join(root, "spend-caps")}
    end
  end

  defp read(path, repository) do
    case File.lstat(path) do
      {:error, :enoent} -> if(Path.wildcard(path <> ".corrupt-*") == [], do: {:ok, %{}}, else: {:error, :spend_cap_state_corrupt})
      {:ok, %{type: :regular, size: size}} when size <= @max_bytes -> decode(path, repository)
      _other -> {:error, :spend_cap_state_unsafe}
    end
  end

  defp decode(path, repository) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         {:ok, records} <- decode_data(data, repository) do
      {:ok, records}
    else
      {:error, :version_unsupported} = error -> error
      {:error, :repository_mismatch} = error -> error
      _other -> corrupt(path)
    end
  end

  defp decode_data(%{"version" => version}, _repository) when is_integer(version) and version > 1, do: {:error, :version_unsupported}
  defp decode_data(%{"version" => 1, "repository" => other}, repository) when other != repository, do: {:error, :repository_mismatch}

  defp decode_data(%{"version" => 1, "repository" => repository, "records" => records}, repository) when is_list(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn encoded, decoded -> decode_record(encoded, repository, decoded) end)
  end

  defp decode_data(_data, _repository), do: {:error, :invalid_record}

  defp decode_record(encoded, repository, {:ok, decoded}) do
    case Record.decode(encoded) do
      {:ok, record} -> insert_record(record, repository, decoded)
      :error -> {:halt, {:error, :invalid_record}}
    end
  end

  defp insert_record(record, repository, decoded) do
    key = Record.key(record)
    identity_repository = "#{record.identity.owner}/#{record.identity.repository}"

    if key && identity_repository == repository && not Map.has_key?(decoded, key),
      do: {:cont, {:ok, Map.put(decoded, key, record)}},
      else: {:halt, {:error, :invalid_record}}
  end

  defp corrupt(path) do
    case Aiur.Fs.quarantine(path) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("spend-cap state quarantine failed path=#{path} reason=#{inspect(reason)}")
    end

    {:error, :spend_cap_state_corrupt}
  end

  defp safe_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, :new}
      {:ok, %{type: :regular, size: size}} when size <= @max_bytes -> {:ok, :existing}
      _other -> {:error, :spend_cap_state_unsafe}
    end
  end

  defp maybe_sync(:new, sync_fun), do: sync_fun.()
  defp maybe_sync(:existing, _sync_fun), do: :ok
end
