defmodule Aiur.Fs do
  @moduledoc """
  Shared filesystem primitives.

  `atomic_write/3` writes to a uniquely-suffixed sibling temp file and
  renames it into place, so any concurrent reader sees either the previous
  contents or the complete new contents — never a prefix. rename(2) within
  a directory is atomic on POSIX; last-writer-wins for the target path.
  Pass `fsync: true` when the data must be on disk before the rename is
  observable (crash-safe persistence, see `Aiur.JsonStore`). Pass `mode:`
  when the staged file must have explicit permissions before it becomes
  visible at the destination path.

  Does not create parent directories — callers that need that (JsonStore)
  mkdir_p themselves. The staged temp file is removed on any failure.
  """

  @spec atomic_write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def atomic_write(path, contents, opts \\ []) when is_binary(path) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    mode = Keyword.get(opts, :mode)

    result =
      if Keyword.get(opts, :fsync, false) do
        write_with_fsync(tmp, contents, mode)
      else
        write(tmp, contents, mode)
      end

    case result do
      :ok -> rename_or_cleanup(tmp, path)
      {:error, reason} -> cleanup_error(tmp, reason)
    end
  end

  defp rename_or_cleanup(tmp, path) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, reason} -> cleanup_error(tmp, reason)
    end
  end

  defp cleanup_error(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end

  defp write(tmp, contents, mode) do
    with :ok <- File.write(tmp, contents) do
      maybe_chmod(tmp, mode)
    end
  end

  defp write_with_fsync(tmp, contents, mode) do
    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]) do
      try do
        with :ok <- maybe_chmod(tmp, mode),
             :ok <- :file.write(fd, contents) do
          :file.sync(fd)
        end
      after
        :ok = :file.close(fd)
      end
    end
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode) when is_integer(mode), do: File.chmod(path, mode)

  @doc """
  Forces a durable directory entry after a first-ever file/directory
  creation. `atomic_write/3` and `Aiur.DecisionLog.append/2` fsync their
  own file descriptor, but that never syncs the *parent* directory's
  inode — so the very first file created under a fresh directory can
  still lose its directory entry on a crash before any other write
  happens to sync that directory.

  The BEAM cannot open a directory as a file descriptor — `:file.open/2`
  returns `:eisdir` for every mode on every OTP release tested — so
  there is no direct way to fsync one directory's inode the way C code
  does. Shells out to the POSIX `sync(1)` command instead, which flushes
  all pending writes system-wide. This is a global barrier, not scoped
  to one directory, so call it only once right after a first-ever
  creation — never on a hot append path.
  """
  @spec sync_filesystem() :: :ok | {:error, term()}
  def sync_filesystem do
    case System.cmd("sync", [], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:sync_failed, status, output}}
    end
  end

  @doc """
  Quarantines a corrupt file in place by renaming it to a timestamped sibling
  (`path.corrupt-<epoch-ms>`) so its bytes are preserved for forensics while
  the live path is freed for re-initialization. A missing file is already
  absent, so that is not an error. Returns `{:error, reason}` when the rename
  itself fails.

  The suffix is a wall-clock millisecond timestamp rather than
  `System.unique_integer/1` (which resets on daemon restart), so a forensic
  archive written on an earlier boot is never overwritten by a later one.
  """
  @spec quarantine(Path.t()) :: :ok | {:error, term()}
  def quarantine(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        suffix = Integer.to_string(System.os_time(:millisecond))
        File.rename(path, path <> ".corrupt-" <> suffix)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
