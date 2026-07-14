defmodule Aiur.CurrentRunMembership.Store.FileOps do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Event.Codec
  alias Aiur.Fs

  @spec write_checkpoint(String.t(), map()) :: :ok | {:error, term()}
  def write_checkpoint(path, record) do
    with :ok <- Codec.validate_checkpoint_record_size(record),
         {:ok, contents} <- Jason.encode(record) do
      atomic_write(path, contents)
    else
      {:error, _reason} = error -> error
    end
  end

  @spec clear_journal(String.t()) :: :ok | {:error, term()}
  def clear_journal(path), do: atomic_write(path, "")

  @spec atomic_write(String.t(), String.t()) :: :ok | {:error, term()}
  def atomic_write(path, contents) when is_binary(contents) do
    with :ok <- regular_or_missing?(path) do
      Fs.atomic_write(path, contents, fsync: true, mode: 0o600)
    end
  end

  @spec regular_or_missing?(String.t()) :: :ok | {:error, term()}
  def regular_or_missing?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_regular_file(String.t()) :: :ok | {:error, :atomic_write_not_visible}
  def ensure_regular_file(path) do
    if match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)), do: :ok, else: {:error, :atomic_write_not_visible}
  end

  @spec sync_recovery_entry((-> term())) :: :ok | {:error, :checkpoint_entry_sync_failed, term()}
  def sync_recovery_entry(sync_fun) do
    case sync_fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, :checkpoint_entry_sync_failed, reason}
    end
  rescue
    error -> {:error, :checkpoint_entry_sync_failed, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, :checkpoint_entry_sync_failed, {kind, reason}}
  end

  @spec quarantine(String.t()) :: :ok | {:error, term()}
  def quarantine(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> File.rename(path, path <> ".corrupt-" <> Integer.to_string(System.unique_integer([:positive])))
      {:error, reason} -> {:error, reason}
    end
  end
end
