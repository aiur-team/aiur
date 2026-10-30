defmodule Aiur.Executor.HookSettingsBackup do
  @moduledoc false

  alias Aiur.{Executor.HookToken, Fs}

  @legacy_suffix ".aiur-bak-"

  @spec backup_dir() :: Path.t()
  def backup_dir, do: Path.join(Path.dirname(HookToken.path()), "hook-settings")

  @spec migrate(Path.t()) :: :ok | {:error, term()}
  def migrate(repo_root) do
    with :ok <- ensure_dir() do
      migrate_files(legacy_paths(repo_root))
    end
  end

  @spec create(Path.t(), binary()) :: :ok | {:error, term()}
  def create(_settings_path, nil), do: :ok

  def create(settings_path, original) when is_binary(original) do
    with :ok <- ensure_dir() do
      name = Path.basename(settings_path) <> @legacy_suffix <> Integer.to_string(System.system_time(:nanosecond))
      Fs.atomic_write(Path.join(backup_dir(), name), original, mode: 0o600, fsync: true)
    end
  end

  @spec restore_bytes(map()) :: {:ok, binary() | nil} | {:error, term()}
  def restore_bytes(settings) when is_map(settings) do
    backup_paths() |> Enum.reduce_while({:ok, nil}, &matching_backup(&1, &2, settings))
  end

  defp ensure_dir do
    dir = backup_dir()

    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  defp backup_paths do
    Path.wildcard(Path.join(backup_dir(), "settings.local.json" <> @legacy_suffix <> "*")) |> Enum.sort()
  end

  defp matching_backup(path, {:ok, nil}, settings) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> compare_backup(path, settings)
      {:ok, _stat} -> {:halt, {:error, :invalid_backup_file}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp matching_backup(_path, result, _settings), do: {:halt, result}

  defp compare_backup(path, settings) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, ^settings} -> {:halt, {:ok, bytes}}
          {:ok, _other} -> {:cont, {:ok, nil}}
          {:error, _reason} -> {:cont, {:ok, nil}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp legacy_paths(repo_root) do
    Path.wildcard(Path.join([repo_root, ".claude", "settings.local.json" <> @legacy_suffix <> "*"]))
    |> Enum.sort()
  end

  defp migrate_files(paths) do
    Enum.reduce_while(paths, :ok, fn source, :ok ->
      case migrate_file(source) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp migrate_file(source) do
    with {:ok, %{type: :regular}} <- File.lstat(source),
         {:ok, bytes} <- File.read(source),
         destination = Path.join(backup_dir(), Path.basename(source)),
         :ok <- copy_and_verify(destination, bytes),
         :ok <- File.rm(source) do
      :ok
    else
      {:ok, _stat} -> {:error, :invalid_legacy_backup}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_and_verify(destination, bytes) do
    with :ok <- write_or_match(destination, bytes),
         {:ok, ^bytes} <- File.read(destination) do
      :ok
    else
      {:ok, _other} -> {:error, :backup_verification_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_or_match(destination, bytes) do
    case File.lstat(destination) do
      {:ok, %{type: :regular}} -> match_existing(destination, bytes)
      {:ok, _stat} -> {:error, :backup_destination_not_regular}
      {:error, :enoent} -> Fs.atomic_write(destination, bytes, mode: 0o600, fsync: true)
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_existing(destination, bytes) do
    with {:ok, ^bytes} <- File.read(destination),
         :ok <- File.chmod(destination, 0o600) do
      :ok
    else
      {:ok, _other} -> {:error, :backup_destination_conflict}
      {:error, reason} -> {:error, reason}
    end
  end
end
