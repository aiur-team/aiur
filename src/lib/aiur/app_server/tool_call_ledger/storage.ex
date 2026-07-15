defmodule Aiur.AppServer.ToolCallLedger.Storage do
  @moduledoc false

  alias Aiur.{Config, DecisionLog}

  @filename "tool_call_ledger.dets"

  @type t :: :memory | {:dets, atom()}

  @spec open(keyword(), boolean()) :: {:ok, t()} | {:error, term()}
  def open(_opts, false), do: {:ok, :memory}

  def open(opts, true) do
    with {:ok, path} <- storage_path(opts),
         {:ok, table_name} <- storage_name(opts),
         :ok <- DecisionLog.ensure_directory(Path.dirname(path)),
         :ok <- prepare_file(path),
         {:ok, ^table_name} <- open_hardened_table(table_name, path) do
      {:ok, {:dets, table_name}}
    end
  end

  @spec load(t()) :: {:ok, map()} | {:error, term()}
  def load(:memory), do: {:ok, %{}}

  def load({:dets, table_name}) do
    {:ok, :dets.foldl(fn {key, entry}, acc -> Map.put(acc, key, entry) end, %{}, table_name)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec put(t(), term(), term()) :: :ok | {:error, term()}
  def put(:memory, _key, _entry), do: :ok

  def put({:dets, table_name}, key, entry) do
    with :ok <- :dets.insert(table_name, {key, entry}),
         :ok <- :dets.sync(table_name) do
      :ok
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec close(t()) :: :ok
  def close(:memory), do: :ok

  def close({:dets, table_name}) do
    :dets.close(table_name)
  catch
    :exit, _reason -> :ok
  end

  defp storage_path(opts) do
    case Keyword.get(opts, :storage_path) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _other ->
        with {:ok, state_dir} <- Config.Paths.decision_state_dir() do
          {:ok, Path.join(state_dir, @filename)}
        end
    end
  end

  defp storage_name(opts) do
    case Keyword.get(opts, :storage_name, __MODULE__) do
      name when is_atom(name) -> {:ok, name}
      invalid -> {:error, {:invalid_storage_name, invalid}}
    end
  end

  defp open_table(table_name, path) do
    :dets.open_file(table_name,
      file: String.to_charlist(path),
      type: :set,
      repair: true
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp open_hardened_table(table_name, path) do
    with {:ok, ^table_name} <- open_table(table_name, path) do
      case File.chmod(path, 0o600) do
        :ok -> {:ok, table_name}
        {:error, reason} -> close_after_open_error(table_name, reason)
      end
    end
  end

  defp close_after_open_error(table_name, reason) do
    _ = :dets.close(table_name)
    {:error, reason}
  end

  defp prepare_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      {:ok, %File.Stat{type: :regular}} -> File.chmod(path, 0o600)
      {:ok, %File.Stat{}} -> {:error, {:not_a_file, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
